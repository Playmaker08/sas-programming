/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 6A — PRODUCTION REPORTING SNAPSHOT + IFRS 9 STAGING
  10_BUILD_IFRS9_STAGING_SNAPSHOT.SAS

  PURPOSE
  -------
  1) Freeze the reporting-date portfolio (31DEC2025 by default)
  2) Score CURRENT 12M PIT PD using the approved frozen PD champion
  3) Reconstruct PD AT ORIGINATION using the SAME frozen model
  4) Apply the approved VALID-only PD calibration layer
  5) Compare current vs origination credit risk
  6) Assign IFRS 9 Stage 1 / 2 / 3 using transparent project policy
  7) Persist an auditable account-level staging snapshot

  IMPORTANT GOVERNANCE
  --------------------
  - This file does NOT refit the PD model.
  - The SICR threshold is a PROJECT POLICY ASSUMPTION, not a regulatory constant.
  - 30 DPD and 90 DPD are implemented as backstops in the project framework.
  - Relative SICR uses RAW frozen-model PDs so the later OOT calibration layer
    does not distort the relative deterioration comparison.
  - Calibrated PD is retained for downstream ECL.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%let REPORT_DATE=&SNAP_END.;

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.monthly_snapshot);
%assert_ds(ds=INT.account_master);
%assert_ds(ds=MODEL.pd_champion_v2);
%assert_ds(ds=OUT.pd_calibration_params);

/*=============================================================================
  1. READ THE APPROVED PD CALIBRATION LAYER
=============================================================================*/
proc sql noprint;
    select count(*) into :N_CAL trimmed
    from OUT.pd_calibration_params;
quit;

%if &N_CAL. ne 1 %then %do;
    %put ERROR: OUT.PD_CALIBRATION_PARAMS must contain exactly one row.;
    %abort cancel;
%end;

data _null_;
    set OUT.pd_calibration_params;
    call symputx('PD_CAL_A',intercept);
    call symputx('PD_CAL_B',slope);
run;

%put NOTE: PD calibration intercept=&PD_CAL_A.;
%put NOTE: PD calibration slope=&PD_CAL_B.;

/*=============================================================================
  2. CURRENT REPORTING-DATE FEATURE TABLE
     Feature formulas MUST match the approved PD development code.
=============================================================================*/
data work.pd_current_features;
    set MODEL.monthly_snapshot;
    where report_date=&REPORT_DATE.;

    score_rev=850-current_score;

    utilization_model=coalesce(current_utilization,0);
    util_log=log(1+utilization_model);

    dpd_clip=min(max(dpd,0),60);
    dpd30=(dpd>=30);

    log_income=log(max(gross_annual_income,1));
    log_balance=log(1+max(current_balance,0));
    mob_sqrt=sqrt(max(months_on_book,0));
    auto_ltv=coalesce(current_ltv,0);
run;

proc sql noprint;
    select count(*) into :N_REPORT trimmed
    from work.pd_current_features;
quit;

%if &N_REPORT.=0 %then %do;
    %put ERROR: No portfolio observations found at REPORT_DATE.;
    %abort cancel;
%end;

/* Score current state using the frozen TRAIN champion. */
proc logistic inmodel=MODEL.pd_champion_v2;
    score data=work.pd_current_features
          out=work.pd_current_scored;
run;

data work.pd_current_scored;
    set work.pd_current_scored;

    pd_current_raw=P_1;

    _p=min(max(pd_current_raw,1e-8),1-1e-8);
    _logit=log(_p/(1-_p));

    pd_current_cal=
        1/(1+exp(-(&PD_CAL_A. + &PD_CAL_B.*_logit)));

    drop P_0 P_1 _p _logit;
run;

/*=============================================================================
  3. TRUE ORIGINATION FEATURE TABLE

  Unlike the classroom first-observed-PD proxy, this project has account-level
  origination data.  We therefore reconstruct the risk state at initial
  recognition and score it with the SAME frozen champion.
=============================================================================*/
data work.pd_orig_features;
    set INT.account_master;

    length employment_status_current $14;

    /* PD-model field mapping at initial recognition. */
    current_score=origination_score;
    employment_status_current=employment_status;
    current_balance=initial_balance;
    current_utilization=initial_utilization;

    if product_type='Auto Loan' then current_ltv=ltv_orig;
    else current_ltv=.;

    dpd=0;
    months_on_book=0;

    score_rev=850-current_score;

    utilization_model=coalesce(current_utilization,0);
    util_log=log(1+utilization_model);

    dpd_clip=0;
    dpd30=0;

    log_income=log(max(gross_annual_income,1));
    log_balance=log(1+max(current_balance,0));
    mob_sqrt=0;
    auto_ltv=coalesce(current_ltv,0);
run;

proc logistic inmodel=MODEL.pd_champion_v2;
    score data=work.pd_orig_features
          out=work.pd_orig_scored;
run;

data work.pd_orig_scored;
    set work.pd_orig_scored;

    pd_orig_raw=P_1;

    _p=min(max(pd_orig_raw,1e-8),1-1e-8);
    _logit=log(_p/(1-_p));

    pd_orig_cal=
        1/(1+exp(-(&PD_CAL_A. + &PD_CAL_B.*_logit)));

    keep
        account_id origination_date origination_score orig_score_tier
        pd_orig_raw pd_orig_cal;
run;

/*=============================================================================
  4. JOIN CURRENT + ORIGINATION RISK
=============================================================================*/
proc sql;
    create table work.stage_pre as
    select
        a.*,
        b.origination_score,
        b.orig_score_tier,
        b.pd_orig_raw,
        b.pd_orig_cal
    from work.pd_current_scored as a
    left join work.pd_orig_scored as b
      on a.account_id=b.account_id
    order by a.account_id;
quit;

/*=============================================================================
  5. IFRS 9 SICR / STAGING POLICY

  Project policy:
      Stage 3:
          default_flag=1 OR DPD >= DEFAULT_DPD

      Stage 2:
          DPD >= SICR_DPD
          OR current raw 12M PD / origination raw 12M PD >= SICR_PD_MULTIPLE

      Stage 1:
          otherwise

  PD ratio uses a tiny numerical denominator floor only to prevent divide-by-zero.
=============================================================================*/
data MODEL.ifrs9_stage_snapshot;
    set work.stage_pre;

    length stage_label $28
           stage_reason $80
           orig_pd_source $24;

    orig_pd_source='Modeled at origination';

    pd_abs_change_raw=pd_current_raw-pd_orig_raw;
    pd_ratio_raw=pd_current_raw/max(pd_orig_raw,1e-6);

    score_drop=origination_score-current_score;

    sicr_dpd_flag=(dpd>=&SICR_DPD. and dpd<&DEFAULT_DPD.);
    sicr_rel_flag=(pd_ratio_raw>=&SICR_PD_MULTIPLE.);
    credit_impaired_flag=(default_flag=1 or dpd>=&DEFAULT_DPD.);

    /* Diagnostic only — NOT a staging override. */
    low_risk_diag=(dpd=0 and current_score>=760 and pd_current_cal<0.01);
    qual_watch_flag=(score_drop>=80 and current_score<660);

    if credit_impaired_flag then do;
        stage=3;
        stage_label='Stage 3 - Credit-impaired';

        if default_flag=1 and dpd>=&DEFAULT_DPD. then
            stage_reason='Default flag + 90 DPD backstop';
        else if default_flag=1 then
            stage_reason='Default flag';
        else
            stage_reason='90 DPD backstop';
    end;

    else if sicr_dpd_flag or sicr_rel_flag then do;
        stage=2;
        stage_label='Stage 2 - SICR';

        if sicr_dpd_flag and sicr_rel_flag then
            stage_reason='30 DPD backstop + PD deterioration';
        else if sicr_dpd_flag then
            stage_reason='30 DPD backstop';
        else
            stage_reason='PD deterioration >= SICR multiple';
    end;

    else do;
        stage=1;
        stage_label='Stage 1 - Performing';
        stage_reason='No SICR trigger';
    end;

    /* Contractual remaining maturity for installment products only.
       Revolving-card behavioral life will be governed in Phase 7. */
    if not missing(maturity_date) then
        contract_rem_mths=max(0,intck('month',report_date,maturity_date,'c'));
    else contract_rem_mths=.;

    gross_exposure=max(current_balance,0);

    format
        pd_current_raw pd_current_cal pd_orig_raw pd_orig_cal
        pd_abs_change_raw percent10.4
        pd_ratio_raw 10.3
        gross_exposure dollar16.2;
run;

/*=============================================================================
  6. HARD DATA-QUALITY ASSERTIONS
=============================================================================*/
proc sql noprint;
    select count(*) into :STAGE_N trimmed
    from MODEL.ifrs9_stage_snapshot;

    select count(*) into :STAGE_DUPS trimmed
    from (
        select account_id, count(*) as n
        from MODEL.ifrs9_stage_snapshot
        group by account_id
        having calculated n>1
    );

    select count(*) into :STAGE_BADPD trimmed
    from MODEL.ifrs9_stage_snapshot
    where missing(pd_current_raw)
       or missing(pd_current_cal)
       or missing(pd_orig_raw)
       or missing(pd_orig_cal)
       or pd_current_cal<0 or pd_current_cal>1
       or pd_orig_cal<0 or pd_orig_cal>1;

    select count(*) into :STAGE_BAD trimmed
    from MODEL.ifrs9_stage_snapshot
    where stage not in (1,2,3);

    select count(*) into :STAGE_MISSING_ORIG trimmed
    from MODEL.ifrs9_stage_snapshot
    where missing(origination_score)
       or missing(pd_orig_raw);
quit;

%if &STAGE_N. ne &N_REPORT. %then %do;
    %put ERROR: Staging row count &STAGE_N does not equal report-date count &N_REPORT.;
    %abort cancel;
%end;

%if &STAGE_DUPS.>0 %then %do;
    %put ERROR: Staging snapshot contains duplicate account IDs.;
    %abort cancel;
%end;

%if &STAGE_BADPD.>0 %then %do;
    %put ERROR: Staging snapshot contains invalid PD values.;
    %abort cancel;
%end;

%if &STAGE_BAD.>0 %then %do;
    %put ERROR: Staging snapshot contains invalid stage values.;
    %abort cancel;
%end;

%if &STAGE_MISSING_ORIG.>0 %then %do;
    %put ERROR: Missing origination risk data for &STAGE_MISSING_ORIG accounts.;
    %abort cancel;
%end;

/*=============================================================================
  7. AUDIT / MANAGEMENT TABLES
=============================================================================*/
proc sql;
    create table OUT.ifrs9_stage_summary as
    select
        stage,
        stage_label,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        mean(pd_current_cal) as avg_current_pd format=percent9.3,
        sum(pd_current_cal*gross_exposure)
            /sum(gross_exposure) as ead_wtd_pd format=percent9.3,
        mean(pd_orig_cal) as avg_orig_pd format=percent9.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2,
        mean(score_drop) as avg_score_drop format=8.1
    from MODEL.ifrs9_stage_snapshot
    group by stage, stage_label
    order by stage;

    create table OUT.ifrs9_stage_product as
    select
        product_type,
        stage,
        stage_label,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        mean(pd_current_cal) as avg_current_pd format=percent9.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2
    from MODEL.ifrs9_stage_snapshot
    group by product_type, stage, stage_label
    order by product_type, stage;

    create table OUT.ifrs9_stage_reason as
    select
        stage,
        stage_reason,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.
    from MODEL.ifrs9_stage_snapshot
    group by stage, stage_reason
    order by stage, stage_reason;

    create table OUT.ifrs9_stage_score_tier as
    select
        current_score_tier,
        stage,
        count(*) as accounts,
        mean(pd_current_cal) as avg_current_pd format=percent9.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2
    from MODEL.ifrs9_stage_snapshot
    group by current_score_tier, stage
    order by current_score_tier, stage;
quit;

/* Persist policy settings for auditability. */
data OUT.ifrs9_staging_policy;
    length policy_item $32 policy_value $24 policy_note $100;

    policy_item='Reporting date';
    policy_value=put(&REPORT_DATE.,date9.);
    policy_note='Project reporting snapshot';
    output;

    policy_item='Relative SICR multiple';
    policy_value=strip(put(&SICR_PD_MULTIPLE.,8.2));
    policy_note='Project policy assumption; raw frozen-model PD comparison';
    output;

    policy_item='SICR DPD backstop';
    policy_value=strip(put(&SICR_DPD.,8.));
    policy_note='Project staging backstop';
    output;

    policy_item='Default DPD backstop';
    policy_value=strip(put(&DEFAULT_DPD.,8.));
    policy_note='Project credit-impaired backstop';
    output;

    policy_item='PD calibration source';
    policy_value='VALID OOT';
    policy_note='Approved Phase-3 calibration layer';
    output;
run;

/*=============================================================================
  8. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 6A — IFRS 9 Staging Policy";
proc print data=OUT.ifrs9_staging_policy noobs; run;

title "Phase 6A — Portfolio Stage Summary";
proc print data=OUT.ifrs9_stage_summary noobs; run;

title "Phase 6A — Stage Distribution by Product";
proc print data=OUT.ifrs9_stage_product noobs; run;

title "Phase 6A — Stage Reasons";
proc print data=OUT.ifrs9_stage_reason noobs; run;

title "Phase 6A — Stage vs Current Score Tier";
proc print data=OUT.ifrs9_stage_score_tier noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 6A STAGING SNAPSHOT COMPLETE.;
%put NOTE: MODEL.IFRS9_STAGE_SNAPSHOT created for &REPORT_DATE.;
%put NOTE: ===============================================================;

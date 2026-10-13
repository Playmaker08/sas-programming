/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 7A — PRODUCTION LGD + EAD/CCF PARAMETERS
  13_BUILD_PRODUCTION_RISK_PARAMETERS.SAS

  PURPOSE
  -------
  Score the 31DEC2025 staged portfolio with the APPROVED frozen LGD and EAD/CCF
  framework so Phase 7B can calculate 12-month / lifetime ECL.

  APPROVED ARCHITECTURE USED
  --------------------------
  LGD
    * Auto: frozen secured LGD regression
    * Credit Card + Personal: frozen two-part recovery model

  EAD / CCF
    * Credit Card 3m : refined parsimonious CCF regression
    * Credit Card 6m : DEV mean CCF
    * Credit Card 12m: DEV mean CCF
    * Auto / Personal 3m, 6m, 12m: DEV product x horizon EAD-ratio champion

  GOVERNANCE
  ----------
  - No model is refit here.
  - 2025 FINALTEST outcomes are NOT used in production scoring.
  - DEV means are reconstructed from MODEL.EAD_MODEL_ABT_R with ROLE_R='DEV'.
  - PLM item stores are restored directly rather than tested with EXIST(),
    because item stores are not ordinary DATA members.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.ifrs9_stage_snapshot);
%assert_ds(ds=INT.account_master);

/*
  IMPORTANT:
  PROC GLM STORE / PROC PLM item stores are NOT ordinary SAS DATA members.
  Therefore %sysfunc(exist()) is not a valid pre-check for:
      MODEL.LGD_AUTO_STORE
      MODEL.LGD_UNSEC_SEVERITY_STORE
      MODEL.CCF_H3_REFINED_STORE

  PROC PLM RESTORE below is the authoritative existence/readability check.
  By contrast, PROC LOGISTIC OUTMODEL creates a normal SAS data set, so the
  hurdle-model OUTMODEL can still be checked with EXIST().
*/
%assert_ds(ds=MODEL.lgd_unsec_hurdle_store);
%assert_ds(ds=MODEL.ead_model_abt_r);

/*=============================================================================
  1. ADD ORIGINATION CONTRACT FEATURES NEEDED BY LGD
=============================================================================*/
proc sql;
    create table work.prod_base as
    select
        s.*,
        a.ltv_orig,
        a.collateral_value_orig
    from MODEL.ifrs9_stage_snapshot as s
    left join INT.account_master as a
      on s.account_id=a.account_id
    order by s.account_id;
quit;

/*=============================================================================
  2. PRODUCTION LGD FEATURE MAPPING
=============================================================================*/
data work.prod_lgd_features;
    set work.prod_base;

    /* Match the exact Phase-4 model feature names/scales. */
    if current_balance>0 and current_collateral_value>0 then
        collateral_coverage=current_collateral_value/current_balance;
    else collateral_coverage=.;

    score_rev_default=(850-current_score)/50;
    log_balance_default=log(max(current_balance,1));
    mob_sqrt_default=sqrt(max(months_on_book,0));
run;

/* Secured Auto LGD. */
proc plm restore=MODEL.lgd_auto_store;
    score data=work.prod_lgd_features(where=(product_type='Auto Loan'))
          out=work.prod_auto_lgd
          predicted=pred_lgd_logit;
run;

data work.prod_auto_lgd;
    set work.prod_auto_lgd;
    pred_lgd_base=1/(1+exp(-pred_lgd_logit));
    pred_lgd_base=min(max(pred_lgd_base,0),1);
run;

/* Unsecured hurdle probability. */
proc logistic inmodel=MODEL.lgd_unsec_hurdle_store;
    score data=work.prod_lgd_features(
              where=(product_type in ('Credit Card','Personal Loan')))
          out=work.prod_unsec_hurdle;
run;

/* Unsecured conditional recovery severity. */
proc plm restore=MODEL.lgd_unsec_severity_store;
    score data=work.prod_unsec_hurdle
          out=work.prod_unsec_lgd
          predicted=pred_rec_logit;
run;

data work.prod_unsec_lgd;
    set work.prod_unsec_lgd;

    p_any_recovery=P_1;
    pred_rec_rate_cond=1/(1+exp(-pred_rec_logit));

    expected_pv_recovery_rate=
        p_any_recovery*pred_rec_rate_cond;

    pred_lgd_base=1-expected_pv_recovery_rate;
    pred_lgd_base=min(max(pred_lgd_base,0),1);

    drop P_0 P_1;
run;

/* Consolidate one row per reporting-date account. */
data work.prod_lgd_scored;
    set work.prod_auto_lgd
        work.prod_unsec_lgd;
run;

proc sort data=work.prod_lgd_scored;
    by account_id;
run;

/*=============================================================================
  3. RECONSTRUCT APPROVED DEV-ONLY EAD / CCF ANCHORS
=============================================================================*/
proc sql;
    create table work.ccf_dev_mean as
    select
        horizon_months,
        mean(ccf_model_target) as dev_mean_ccf
    from MODEL.ead_model_abt_r
    where role_r='DEV'
      and product_type='Credit Card'
      and ccf_eligible=1
    group by horizon_months;

    create table work.term_dev_mean as
    select
        product_type,
        horizon_months,
        mean(ead_ratio_realized) as dev_mean_ead_ratio
    from MODEL.ead_model_abt_r
    where role_r='DEV'
      and product_type in ('Auto Loan','Personal Loan')
      and term_target_ok=1
    group by product_type, horizon_months;
quit;

proc transpose data=work.ccf_dev_mean
               out=work.ccf_anchor_wide(drop=_name_)
               prefix=ccf_h;
    id horizon_months;
    var dev_mean_ccf;
run;

proc sort data=work.term_dev_mean; by product_type; run;

proc transpose data=work.term_dev_mean
               out=work.term_anchor_wide(drop=_name_)
               prefix=ratio_h;
    by product_type;
    id horizon_months;
    var dev_mean_ead_ratio;
run;

/* Persist parameter anchors for governance / later reproducibility. */
data OUT.phase7_ead_anchor_parameters;
    length parameter_family $20 product_type $16;
    set work.ccf_dev_mean(in=a)
        work.term_dev_mean(in=b);

    if a then do;
        parameter_family='CCF_DEV_MEAN';
        product_type='Credit Card';
        value=dev_mean_ccf;
    end;
    else do;
        parameter_family='TERM_EAD_RATIO';
        value=dev_mean_ead_ratio;
    end;

    keep parameter_family product_type horizon_months value;
run;

/*=============================================================================
  4. CURRENT CREDIT-CARD 3M CCF — APPROVED REFINED REGRESSION
=============================================================================*/
data work.card_current_features;
    set work.prod_lgd_scored;
    where product_type='Credit Card';

    score_rev_obs=(850-current_score)/50;
    mob_sqrt_obs=sqrt(max(months_on_book,0));
    dpd_clip_obs=min(max(dpd,0),60);

    util_eps=min(max(current_utilization,1e-4),1-1e-4);
    util_logit_obs=log(util_eps/(1-util_eps));

    unemployed_flag=(employment_status_current='Unemployed');
    student_flag=(employment_status_current='Student');
run;

proc plm restore=MODEL.ccf_h3_refined_store;
    score data=work.card_current_features
          out=work.card_current_scored
          predicted=ccf_h3_raw;
run;

data work.card_current_scored;
    set work.card_current_scored;
    ccf_h3=min(max(ccf_h3_raw,0),1.25);
run;

/* Add stable 6m / 12m card anchors. */
proc sql;
    create table work.card_prod as
    select
        a.*,
        w.ccf_h6,
        w.ccf_h12
    from work.card_current_scored as a,
         work.ccf_anchor_wide as w;
quit;

/*=============================================================================
  5. TERM-LOAN APPROVED PRODUCT x HORIZON EAD-RATIO ANCHORS
=============================================================================*/
proc sql;
    create table work.term_prod as
    select
        a.*,
        w.ratio_h3,
        w.ratio_h6,
        w.ratio_h12
    from work.prod_lgd_scored as a
    left join work.term_anchor_wide as w
      on a.product_type=w.product_type
    where a.product_type in ('Auto Loan','Personal Loan');
quit;

/*=============================================================================
  6. FINAL PRODUCTION PARAMETER TABLE
=============================================================================*/
data MODEL.production_risk_params;
    set work.card_prod
        work.term_prod;

    length ead_method $48 lgd_method $48;

    if product_type='Credit Card' then do;
        ead_method='3m regression; 6m/12m DEV mean CCF';
        lgd_method='Two-part unsecured recovery LGD';

        /* Approved current-state anchors. */
        ead_h3=max(0,current_balance + ccf_h3*available_limit);
        ead_h6=max(0,current_balance + ccf_h6*available_limit);
        ead_h12=max(0,current_balance + ccf_h12*available_limit);
    end;

    else do;
        ead_method='DEV product x horizon EAD-ratio';
        if product_type='Auto Loan' then
            lgd_method='Secured Auto LGD regression';
        else
            lgd_method='Two-part unsecured recovery LGD';

        ead_h3=max(0,current_balance*ratio_h3);
        ead_h6=max(0,current_balance*ratio_h6);
        ead_h12=max(0,current_balance*ratio_h12);
    end;

    format pred_lgd_base percent9.3
           ead_h3 ead_h6 ead_h12 dollar16.2;
run;

proc sort data=MODEL.production_risk_params;
    by account_id;
run;

/*=============================================================================
  7. HARD DQ
=============================================================================*/
proc sql noprint;
    select count(*) into :N_STAGE trimmed
    from MODEL.ifrs9_stage_snapshot;

    select count(*) into :N_PROD trimmed
    from MODEL.production_risk_params;

    select count(*) into :N_DUP trimmed
    from (
        select account_id, count(*) as n
        from MODEL.production_risk_params
        group by account_id
        having calculated n>1
    );

    select count(*) into :N_BAD_LGD trimmed
    from MODEL.production_risk_params
    where missing(pred_lgd_base)
       or pred_lgd_base<0
       or pred_lgd_base>1;

    select count(*) into :N_BAD_EAD trimmed
    from MODEL.production_risk_params
    where missing(ead_h3)
       or missing(ead_h6)
       or missing(ead_h12)
       or min(ead_h3,ead_h6,ead_h12)<0;

    select count(*) into :N_BAD_ANCHOR trimmed
    from MODEL.production_risk_params
    where (product_type='Credit Card'
           and (missing(ccf_h3) or missing(ccf_h6) or missing(ccf_h12)))
       or (product_type in ('Auto Loan','Personal Loan')
           and (missing(ratio_h3) or missing(ratio_h6) or missing(ratio_h12)));
quit;

%macro phase7a_gate;
    %if &N_STAGE. ne &N_PROD. %then %do;
        %put ERROR: Production risk table row count does not match staging snapshot.;
        %abort cancel;
    %end;

    %if &N_DUP.>0 %then %do;
        %put ERROR: Duplicate account IDs found in production risk parameters.;
        %abort cancel;
    %end;

    %if &N_BAD_LGD.>0 %then %do;
        %put ERROR: Invalid production LGD predictions: &N_BAD_LGD.;
        %abort cancel;
    %end;

    %if &N_BAD_EAD.>0 %then %do;
        %put ERROR: Invalid production EAD anchors: &N_BAD_EAD.;
        %abort cancel;
    %end;

    %if &N_BAD_ANCHOR.>0 %then %do;
        %put ERROR: Missing approved EAD/CCF anchors: &N_BAD_ANCHOR.;
        %abort cancel;
    %end;
%mend;

%phase7a_gate;

/*=============================================================================
  8. MANAGEMENT / GOVERNANCE OUTPUTS
=============================================================================*/
proc sql;
    create table OUT.phase7_prod_lgd_summary as
    select
        product_type,
        stage,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        mean(pred_lgd_base) as avg_base_lgd format=percent9.3,
        median(pred_lgd_base) as med_base_lgd format=percent9.3
    from MODEL.production_risk_params
    group by product_type, stage
    order by product_type, stage;

    create table OUT.phase7_prod_ead_summary as
    select
        product_type,
        count(*) as accounts,
        sum(current_balance) as current_exposure format=dollar18.,
        sum(ead_h3) as ead_h3 format=dollar18.,
        sum(ead_h6) as ead_h6 format=dollar18.,
        sum(ead_h12) as ead_h12 format=dollar18.,
        sum(ead_h3)/sum(current_balance) as ratio_h3 format=8.3,
        sum(ead_h6)/sum(current_balance) as ratio_h6 format=8.3,
        sum(ead_h12)/sum(current_balance) as ratio_h12 format=8.3
    from MODEL.production_risk_params
    group by product_type
    order by product_type;

    create table OUT.phase7a_dq as
    select
        count(*) as rows,
        count(distinct account_id) as accounts,
        sum(missing(pred_lgd_base)) as missing_lgd,
        sum(missing(ead_h3) or missing(ead_h6) or missing(ead_h12))
            as missing_ead_anchor
    from MODEL.production_risk_params;
quit;

ods noproctitle;

title "Phase 7A — Production LGD Summary";
proc print data=OUT.phase7_prod_lgd_summary noobs; run;

title "Phase 7A — Production EAD Anchor Summary";
proc print data=OUT.phase7_prod_ead_summary noobs; run;

title "Phase 7A — Approved DEV EAD / CCF Anchor Parameters";
proc print data=OUT.phase7_ead_anchor_parameters noobs; run;

title "Phase 7A — Production Parameter DQ";
proc print data=OUT.phase7a_dq noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 7A PRODUCTION RISK PARAMETERS COMPLETE.;
%put NOTE: ===============================================================;

/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 2 — 12-MONTH PIT PD MODEL
  04_BUILD_PIT_PD_MODEL.SAS

  PURPOSE
  -------
  1) Derive a leakage-safe forward 12-month default target from DEFAULT_EVENTS
  2) Build the PIT PD analytical base table (PD_ABT)
  3) Apply deterministic feature engineering
  4) Split chronologically into TRAIN / VALID / TEST
  5) Fit an interpretable SAS logistic-regression champion model on TRAIN only
  6) Freeze the model and score TRAIN / VALID / TEST without refitting
  7) Produce development sanity checks for Phase 3 validation

  IMPORTANT MODEL-GOVERNANCE PRINCIPLES
  -------------------------------------
  - No future default date is retained in MODEL.PD_ABT.
  - Observations at default are excluded from the modeling population.
  - Every observation must have a fully observable 12-month outcome window.
  - Validation and test periods are out-of-time.
  - No protected-class variables are used.
  - Phase 3 will perform full discrimination, calibration, stability, and
    challenger-model validation.  This file is the champion-development layer.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

/*--------------------------------------------------------------------------
  0. PHASE-2 MODEL WINDOW

  Data ends 31DEC2025, so a 12-month target is fully mature only through
  31DEC2024.

  TRAIN : 31JAN2021 - 31DEC2023
  VALID : 31JAN2024 - 30JUN2024
  TEST  : 31JUL2024 - 31DEC2024
--------------------------------------------------------------------------*/

%let PD_OBS_END='31DEC2024'd;

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.monthly_snapshot);
%assert_ds(ds=INT.default_events);

/*=============================================================================
  1. BUILD FORWARD 12-MONTH TARGET
=============================================================================*/

proc sql;
    create table work.pd_target_build as
    select
        s.*,
        d.default_date
    from MODEL.monthly_snapshot as s
    left join INT.default_events as d
        on s.account_id=d.account_id
    where s.report_date <= &PD_OBS_END.
      and s.default_flag=0
    order by s.account_id, s.report_date;
quit;

data work.pd_targeted;
    set work.pd_target_build;

    outcome_end=intnx('month',report_date,12,'e');
    format outcome_end date9.;

    /* Defensive maturity requirement. */
    if outcome_end > &SNAP_END. then delete;

    target_12m = (
        not missing(default_date)
        and default_date > report_date
        and default_date <= outcome_end
    );

    /* Months to default is retained only for development diagnostics and is
       NOT kept in the final modeling ABT. */
    if not missing(default_date) then
        months_to_default=intck('month',report_date,default_date,'c');
    else months_to_default=.;
run;

/*=============================================================================
  2. DETERMINISTIC FEATURE ENGINEERING

  All transforms are fixed formulas; no sample-estimated imputation statistics
  are learned from VALID or TEST.
=============================================================================*/

data MODEL.pd_abt;
    set work.pd_targeted;

    length role $5;

    /* Risk-direction score: larger = riskier. */
    score_rev = 850-current_score;

    /* Product-aware utilization.  Non-revolving products get zero plus the
       PRODUCT_TYPE class effect in the model. */
    utilization_model=coalesce(current_utilization,0);
    util_log=log(1+utilization_model);

    /* Delinquency at the observation date is legitimate current information. */
    dpd_clip=min(max(dpd,0),60);
    dpd30=(dpd>=30);
    dpd60=(dpd>=60);

    /* Scale/skew transformations. */
    log_income=log(max(gross_annual_income,1));
    log_balance=log(1+max(current_balance,0));
    mob_sqrt=sqrt(max(months_on_book,0));

    /* Auto LTV is relevant only for auto accounts; PRODUCT_TYPE identifies
       structural zero for other products. */
    auto_ltv=coalesce(current_ltv,0);

    /* Time-based role. */
    if report_date <= &TRAIN_END. then role='TRAIN';
    else if report_date <= &VALID_END. then role='VALID';
    else if report_date <= &PD_OBS_END. then role='TEST';
    else delete;

    /* Final model-facing table deliberately excludes DEFAULT_DATE,
       OUTCOME_END, MONTHS_TO_DEFAULT, ACCOUNT_STATUS, and DEFAULT_FLAG. */
    keep
        account_id customer_id report_date role target_12m
        product_type vehicle_type
        gross_annual_income debt_to_income
        employment_status_current
        current_score current_score_tier
        current_balance credit_limit current_utilization current_ltv
        dpd months_on_book
        unemployment_rate fed_funds_rate real_gdp_growth
        score_rev utilization_model util_log dpd_clip dpd30 dpd60
        log_income log_balance mob_sqrt auto_ltv;
run;

/*=============================================================================
  3. HARD PD-ABT DATA QUALITY CHECKS
=============================================================================*/

proc sql noprint;
    select count(*) into :PD_NOBS trimmed from MODEL.pd_abt;

    select count(*) into :PD_DUPS trimmed
    from (
        select account_id, report_date, count(*) as n
        from MODEL.pd_abt
        group by account_id, report_date
        having calculated n>1
    );

    select count(*) into :PD_BAD_TARGET trimmed
    from MODEL.pd_abt
    where target_12m not in (0,1) or missing(target_12m);

    select count(*) into :PD_BAD_SCORE trimmed
    from MODEL.pd_abt
    where missing(current_score)
       or current_score<300
       or current_score>850;

    select count(*) into :PD_BAD_MACRO trimmed
    from MODEL.pd_abt
    where missing(unemployment_rate)
       or missing(fed_funds_rate)
       or missing(real_gdp_growth);
quit;

%if &PD_NOBS.=0 %then %do;
    %put ERROR: MODEL.PD_ABT is empty.;
    %abort cancel;
%end;

%if &PD_DUPS.>0 %then %do;
    %put ERROR: MODEL.PD_ABT has &PD_DUPS duplicate account-month keys.;
    %abort cancel;
%end;

%if &PD_BAD_TARGET.>0 %then %do;
    %put ERROR: MODEL.PD_ABT has &PD_BAD_TARGET invalid target values.;
    %abort cancel;
%end;

%if &PD_BAD_SCORE.>0 %then %do;
    %put ERROR: MODEL.PD_ABT has &PD_BAD_SCORE invalid credit-score rows.;
    %abort cancel;
%end;

%if &PD_BAD_MACRO.>0 %then %do;
    %put ERROR: MODEL.PD_ABT has &PD_BAD_MACRO rows with missing macro inputs.;
    %abort cancel;
%end;

/* Each time split must contain both goods and bads. */
proc sql;
    create table OUT.pd_role_summary as
    select
        role,
        count(*) as observations,
        count(distinct account_id) as accounts,
        sum(target_12m) as defaults_12m,
        mean(target_12m) as observed_default_rate format=percent8.2,
        min(report_date) as min_report_date format=date9.,
        max(report_date) as max_report_date format=date9.
    from MODEL.pd_abt
    group by role;
quit;

proc sql noprint;
    select count(*) into :PD_BAD_ROLES trimmed
    from OUT.pd_role_summary
    where defaults_12m=0
       or defaults_12m=observations;
quit;

%if &PD_BAD_ROLES.>0 %then %do;
    %put ERROR: At least one PD split does not contain both default and non-default outcomes.;
    %abort cancel;
%end;

/*=============================================================================
  4. PHYSICAL TRAIN / VALID / TEST TABLES
=============================================================================*/

data MODEL.pd_train MODEL.pd_valid MODEL.pd_test;
    set MODEL.pd_abt;

    if role='TRAIN' then output MODEL.pd_train;
    else if role='VALID' then output MODEL.pd_valid;
    else if role='TEST' then output MODEL.pd_test;
run;

/*=============================================================================
  5. CHAMPION 12-MONTH PIT PD LOGISTIC REGRESSION — TRAIN ONLY
=============================================================================*/

ods output
    ParameterEstimates=OUT.pd_parameters
    Association=OUT.pd_train_association
    FitStatistics=OUT.pd_fit_statistics;

proc logistic data=MODEL.pd_train
              outmodel=MODEL.pd_champion
              plots(only)=roc;

    class
        product_type(ref='Credit Card')
        employment_status_current(ref='Employed')
        / param=ref;

    model target_12m(event='1') =
        score_rev
        util_log
        dpd_clip
        dpd30
        dpd60
        debt_to_income
        log_income
        mob_sqrt
        log_balance
        auto_ltv
        unemployment_rate
        fed_funds_rate
        real_gdp_growth
        product_type
        employment_status_current
        /
        rsq;
run;

ods output close;

/*=============================================================================
  6. FREEZE MODEL AND SCORE ALL PERIODS — NO REFITTING
=============================================================================*/

proc logistic inmodel=MODEL.pd_champion;
    score data=MODEL.pd_train out=work.pd_train_scored;
    score data=MODEL.pd_valid out=work.pd_valid_scored;
    score data=MODEL.pd_test  out=work.pd_test_scored;
run;

data MODEL.pd_scored;
    length role_scored $5;

    set work.pd_train_scored(in=in_train)
        work.pd_valid_scored(in=in_valid)
        work.pd_test_scored (in=in_test);

    if in_train then role_scored='TRAIN';
    else if in_valid then role_scored='VALID';
    else if in_test then role_scored='TEST';

    pred_pd=P_1;

    /* Defensive probability bound check is done below; no clipping here. */
run;

/*=============================================================================
  7. SCORING DQ + DEVELOPMENT SANITY CHECKS
=============================================================================*/

proc sql noprint;
    select count(*) into :PD_BAD_PRED trimmed
    from MODEL.pd_scored
    where missing(pred_pd)
       or pred_pd<0
       or pred_pd>1;
quit;

%if &PD_BAD_PRED.>0 %then %do;
    %put ERROR: MODEL.PD_SCORED contains &PD_BAD_PRED invalid predicted PD values.;
    %abort cancel;
%end;

proc sql;
    create table OUT.pd_score_summary as
    select
        role_scored as role length=5,
        count(*) as observations,
        sum(target_12m) as defaults_12m,
        mean(target_12m) as observed_default_rate format=percent8.2,
        mean(pred_pd) as mean_predicted_pd format=percent8.2,
        min(pred_pd) as min_predicted_pd format=percent8.4,
        max(pred_pd) as max_predicted_pd format=percent8.2
    from MODEL.pd_scored
    group by role_scored;
quit;

/* Risk-order sanity table: score tier should generally show increasing default
   risk as credit quality deteriorates. */
proc sql;
    create table OUT.pd_score_tier_sanity as
    select
        role_scored as role length=5,
        current_score_tier,
        count(*) as observations,
        mean(target_12m) as observed_default_rate format=percent8.2,
        mean(pred_pd) as mean_predicted_pd format=percent8.2
    from MODEL.pd_scored
    group by role_scored, current_score_tier;
quit;

/* Product-level OOT sanity check. */
proc sql;
    create table OUT.pd_product_sanity as
    select
        role_scored as role length=5,
        product_type,
        count(*) as observations,
        mean(target_12m) as observed_default_rate format=percent8.2,
        mean(pred_pd) as mean_predicted_pd format=percent8.2
    from MODEL.pd_scored
    group by role_scored, product_type;
quit;

/*=============================================================================
  8. RESULTS TO REVIEW BEFORE PHASE 3
=============================================================================*/

ods noproctitle;

title "Phase 2 — PIT PD Modeling Population by Time Split";
proc print data=OUT.pd_role_summary noobs;
run;

title "Phase 2 — Frozen Champion Score Summary";
proc print data=OUT.pd_score_summary noobs;
run;

title "Phase 2 — Observed vs Predicted Risk by Score Tier";
proc print data=OUT.pd_score_tier_sanity noobs;
run;

title "Phase 2 — Observed vs Predicted Risk by Product";
proc print data=OUT.pd_product_sanity noobs;
run;

title "Phase 2 — Champion Logistic Parameter Estimates";
proc print data=OUT.pd_parameters noobs;
run;

title "Phase 2 — Training Association Statistics";
proc print data=OUT.pd_train_association noobs;
run;

title;

%put NOTE: ===============================================================;
%put NOTE: PHASE 2 COMPLETE — PIT PD CHAMPION DEVELOPED.;
%put NOTE: TRAIN only was used for parameter estimation.;
%put NOTE: VALID and TEST were scored with the frozen TRAIN model.;
%put NOTE: Full validation/calibration/stability testing belongs to Phase 3.;
%put NOTE: ===============================================================;

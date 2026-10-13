/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 4 — LGD MODEL DEVELOPMENT
  06_BUILD_LGD_CHAMPION.SAS

  PURPOSE
  -------
  Build a product-aware LGD framework from mature default workouts only.

  DESIGN
  ------
  * TRAIN: defaults through 31DEC2022
  * VALID: defaults in calendar 2023
  * TEST : mature defaults in 01JAN2024–30JUN2024

  * Auto Loan (secured): direct logit-transformed LGD regression.
  * Credit Card + Personal Loan (unsecured): two-part recovery model:
        P(any discounted recovery)
        x E(discounted recovery rate | positive recovery)
    then LGD = 1 - expected discounted recovery rate.

  IMPORTANT
  ---------
  - Only MODEL.LGD_ABT_MATURE is used for estimation/evaluation.
  - No post-default recovery outcome (costs, realized cashflow lag, etc.) is used
    as a predictor.
  - VALID/TEST are never used to estimate champion coefficients.
  - Stored models are retained for later portfolio scoring.
============================================================================= */

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.lgd_abt_mature);
%assert_ds(ds=INT.account_master);

/*=============================================================================
  1. BUILD MODELING ABT + PRE-DEFAULT/AT-DEFAULT FEATURES
=============================================================================*/
proc sql;
    create table MODEL.lgd_model_abt as
    select
        l.*,
        a.origination_date,
        a.term_months,
        a.credit_limit,
        a.collateral_value_orig,
        a.region,

        /* Features available/observable at default and later mappable to
           current portfolio values for ECL scoring. */
        case when l.balance_at_default>0 then
            l.collateral_value_at_default/l.balance_at_default
        else . end as collateral_coverage,

        (850-l.score_at_default)/50 as score_rev_default,
        log(max(l.balance_at_default,1)) as log_balance_default,
        sqrt(max(intck('month',a.origination_date,l.default_date),0)) as mob_sqrt_default,

        /* Discounted recovery rate implied by realized LGD. */
        1-l.realized_lgd_full as pv_recovery_rate,

        case when (1-l.realized_lgd_full)>1e-8 then 1 else 0 end
            as any_pv_recovery

    from MODEL.lgd_abt_mature as l
    left join INT.account_master as a
        on l.account_id=a.account_id
    order by l.default_date, l.account_id;
quit;

data MODEL.lgd_model_abt;
    set MODEL.lgd_model_abt;
    length role $5;

    if default_date <= '31DEC2022'd then role='TRAIN';
    else if '01JAN2023'd <= default_date <= '31DEC2023'd then role='VALID';
    else if '01JAN2024'd <= default_date <= '30JUN2024'd then role='TEST';
    else delete;

    /* Numerical guards only for transformed-response models. */
    lgd_eps=min(max(realized_lgd_full,1e-4),1-1e-4);
    lgd_logit=log(lgd_eps/(1-lgd_eps));

    rec_eps=min(max(pv_recovery_rate,1e-4),1-1e-4);
    rec_logit=log(rec_eps/(1-rec_eps));

    /* Missing auto collateral should remain explicit rather than silently
       forcing a value.  In this synthetic portfolio it should be available. */
run;

/* Hard DQ. */
proc sql noprint;
    select count(*) into :N_LGD_MODEL trimmed from MODEL.lgd_model_abt;
    select count(*) into :N_BAD_TARGET trimmed
    from MODEL.lgd_model_abt
    where missing(realized_lgd_full)
       or realized_lgd_full<0
       or realized_lgd_full>1;
quit;

%if &N_LGD_MODEL.=0 %then %do;
    %put ERROR: LGD modeling ABT is empty.;
    %abort cancel;
%end;

%if &N_BAD_TARGET.>0 %then %do;
    %put ERROR: LGD modeling ABT contains &N_BAD_TARGET invalid LGD targets.;
    %abort cancel;
%end;

/*=============================================================================
  2. TRAIN-ONLY PRODUCT-MEAN BASELINE
=============================================================================*/
proc sql;
    create table work.lgd_train_means as
    select product_type,
           mean(realized_lgd_full) as train_mean_lgd
    from MODEL.lgd_model_abt
    where role='TRAIN'
    group by product_type;

    create table work.lgd_with_baseline as
    select a.*,
           b.train_mean_lgd as pred_lgd_baseline
    from MODEL.lgd_model_abt as a
    left join work.lgd_train_means as b
        on a.product_type=b.product_type;
quit;

/*=============================================================================
  3. SECURED AUTO CHAMPION
     Direct model on logit-transformed realized LGD.
=============================================================================*/
ods output ParameterEstimates=OUT.lgd_auto_parameters;

proc glm data=MODEL.lgd_model_abt(
            where=(role='TRAIN' and product_type='Auto Loan'));
    class vehicle_type;
    model lgd_logit =
        collateral_coverage
        score_rev_default
        log_balance_default
        debt_to_income
        mob_sqrt_default
        unemployment_rate
        fed_funds_rate
        real_gdp_growth
        ltv_orig
        vehicle_type
        / solution;
    store MODEL.lgd_auto_store;
quit;

ods output close;

proc plm restore=MODEL.lgd_auto_store;
    score data=work.lgd_with_baseline(where=(product_type='Auto Loan'))
          out=work.auto_scored
          predicted=pred_lgd_logit;
run;

data work.auto_scored;
    set work.auto_scored;
    pred_lgd_champion=1/(1+exp(-pred_lgd_logit));
    pred_lgd_champion=min(max(pred_lgd_champion,0),1);
run;

/*=============================================================================
  4. UNSECURED TWO-PART CHAMPION

     Stage 1: P(any discounted recovery)
     Stage 2: conditional discounted recovery severity among positive recoveries
     Expected LGD = 1 - P(recovery)*E(recovery rate | recovery)
=============================================================================*/
ods output ParameterEstimates=OUT.lgd_unsec_hurdle_parameters;

proc logistic data=MODEL.lgd_model_abt(
                  where=(role='TRAIN' and product_type in
                         ('Credit Card','Personal Loan')))
              outmodel=MODEL.lgd_unsec_hurdle_store;
    class product_type(ref='Credit Card') / param=ref;
    model any_pv_recovery(event='1') =
        score_rev_default
        log_balance_default
        debt_to_income
        mob_sqrt_default
        unemployment_rate
        fed_funds_rate
        real_gdp_growth
        product_type;
run;

ods output close;

ods output ParameterEstimates=OUT.lgd_unsec_severity_parameters;

proc glm data=MODEL.lgd_model_abt(
            where=(role='TRAIN'
                   and product_type in ('Credit Card','Personal Loan')
                   and any_pv_recovery=1));
    class product_type;
    model rec_logit =
        score_rev_default
        log_balance_default
        debt_to_income
        mob_sqrt_default
        unemployment_rate
        fed_funds_rate
        real_gdp_growth
        product_type
        / solution;
    store MODEL.lgd_unsec_severity_store;
quit;

ods output close;

/* Score recovery probability with frozen TRAIN hurdle model. */
proc logistic inmodel=MODEL.lgd_unsec_hurdle_store;
    score data=work.lgd_with_baseline(
              where=(product_type in ('Credit Card','Personal Loan')))
          out=work.unsec_hurdle_scored;
run;

/* Score conditional recovery severity with frozen TRAIN model. */
proc plm restore=MODEL.lgd_unsec_severity_store;
    score data=work.unsec_hurdle_scored
          out=work.unsec_scored
          predicted=pred_rec_logit;
run;

data work.unsec_scored;
    set work.unsec_scored;

    p_any_recovery=P_1;
    pred_rec_rate_cond=1/(1+exp(-pred_rec_logit));

    expected_pv_recovery_rate=
        p_any_recovery*pred_rec_rate_cond;

    pred_lgd_champion=1-expected_pv_recovery_rate;
    pred_lgd_champion=min(max(pred_lgd_champion,0),1);
run;

/*=============================================================================
  5. CONSOLIDATE CHAMPION SCORES
=============================================================================*/
data MODEL.lgd_scored;
    set work.auto_scored
        work.unsec_scored;

    sqerr_champion=(pred_lgd_champion-realized_lgd_full)**2;
    abserr_champion=abs(pred_lgd_champion-realized_lgd_full);
    err_champion=pred_lgd_champion-realized_lgd_full;

    sqerr_baseline=(pred_lgd_baseline-realized_lgd_full)**2;
    abserr_baseline=abs(pred_lgd_baseline-realized_lgd_full);
    err_baseline=pred_lgd_baseline-realized_lgd_full;
run;

proc sort data=MODEL.lgd_scored;
    by role product_type default_date account_id;
run;

/* Score DQ. */
proc sql noprint;
    select count(*) into :N_BAD_PRED trimmed
    from MODEL.lgd_scored
    where missing(pred_lgd_champion)
       or pred_lgd_champion<0
       or pred_lgd_champion>1;
quit;

%if &N_BAD_PRED.>0 %then %do;
    %put ERROR: MODEL.LGD_SCORED contains &N_BAD_PRED invalid champion predictions.;
    %abort cancel;
%end;

/*=============================================================================
  6. DEVELOPMENT / OOT SUMMARIES
=============================================================================*/
proc sql;
    create table OUT.lgd_population_summary as
    select role,
           product_type,
           count(*) as defaults,
           mean(realized_lgd_full) as observed_lgd format=percent8.2,
           mean(pred_lgd_champion) as predicted_lgd format=percent8.2,
           mean(pred_lgd_baseline) as baseline_lgd format=percent8.2,
           min(default_date) as min_default_date format=date9.,
           max(default_date) as max_default_date format=date9.
    from MODEL.lgd_scored
    group by role, product_type
    order by role, product_type;

    create table OUT.lgd_model_metrics as
    select role,
           product_type,
           count(*) as n,
           sqrt(mean(sqerr_champion)) as rmse_champion format=8.4,
           mean(abserr_champion) as mae_champion format=8.4,
           mean(err_champion) as bias_champion format=8.4,
           sqrt(mean(sqerr_baseline)) as rmse_baseline format=8.4,
           mean(abserr_baseline) as mae_baseline format=8.4,
           mean(err_baseline) as bias_baseline format=8.4
    from MODEL.lgd_scored
    group by role, product_type
    order by role, product_type;
quit;

/* Overall role metrics. */
proc sql;
    create table OUT.lgd_model_metrics_overall as
    select role,
           count(*) as n,
           mean(realized_lgd_full) as observed_lgd format=percent8.2,
           mean(pred_lgd_champion) as predicted_lgd format=percent8.2,
           sqrt(mean(sqerr_champion)) as rmse_champion format=8.4,
           mean(abserr_champion) as mae_champion format=8.4,
           mean(err_champion) as bias_champion format=8.4,
           sqrt(mean(sqerr_baseline)) as rmse_baseline format=8.4,
           mean(abserr_baseline) as mae_baseline format=8.4
    from MODEL.lgd_scored
    group by role
    order by role;
quit;

/*=============================================================================
  7. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 4 — LGD Modeling Population / OOT Split";
proc print data=OUT.lgd_population_summary noobs; run;

title "Phase 4 — Champion vs Product-Mean Baseline by Product";
proc print data=OUT.lgd_model_metrics noobs; run;

title "Phase 4 — Champion vs Baseline Overall";
proc print data=OUT.lgd_model_metrics_overall noobs; run;

title "Phase 4 — Auto LGD Parameter Estimates";
proc print data=OUT.lgd_auto_parameters noobs; run;

title "Phase 4 — Unsecured Recovery Hurdle Parameter Estimates";
proc print data=OUT.lgd_unsec_hurdle_parameters noobs; run;

title "Phase 4 — Unsecured Conditional Recovery Parameter Estimates";
proc print data=OUT.lgd_unsec_severity_parameters noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 4 LGD DEVELOPMENT COMPLETE.;
%put NOTE: Stored scoring models:;
%put NOTE:   MODEL.LGD_AUTO_STORE;
%put NOTE:   MODEL.LGD_UNSEC_HURDLE_STORE;
%put NOTE:   MODEL.LGD_UNSEC_SEVERITY_STORE;
%put NOTE: Validation input: MODEL.LGD_SCORED.;
%put NOTE: ===============================================================;

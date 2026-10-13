/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 2A — PIT PD CHAMPION SPECIFICATION REPAIR
  04A_REFINE_PIT_PD_CHAMPION.SAS

  PURPOSE
  -------
  The Phase-2 candidate contained an exact linear dependency:

      dpd60 = dpd_clip/30 - dpd30

  for the non-default modeling population where DPD states are 0/30/60.
  SAS therefore set DPD60 to zero automatically.  This file removes that
  redundant regressor explicitly and rebuilds the frozen champion.

  IMPORTANT
  ---------
  - No new information is introduced.
  - TRAIN only estimates model parameters.
  - VALID and TEST remain untouched for estimation.
  - Predictions should be essentially unchanged versus the Phase-2 candidate.
============================================================================= */

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.pd_train);
%assert_ds(ds=MODEL.pd_valid);
%assert_ds(ds=MODEL.pd_test);

ods output
    ParameterEstimates=OUT.pd_v2_parameters
    Association=OUT.pd_v2_train_assoc
    FitStatistics=OUT.pd_v2_fit_stats;

proc logistic data=MODEL.pd_train
              outmodel=MODEL.pd_champion_v2
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

/* Freeze the TRAIN model and score all splits. */
proc logistic inmodel=MODEL.pd_champion_v2;
    score data=MODEL.pd_train out=work.pd_v2_train;
    score data=MODEL.pd_valid out=work.pd_v2_valid;
    score data=MODEL.pd_test  out=work.pd_v2_test;
run;

data MODEL.pd_scored_v2;
    length role_scored $5;
    set work.pd_v2_train(in=a)
        work.pd_v2_valid(in=b)
        work.pd_v2_test (in=c);

    if a then role_scored='TRAIN';
    else if b then role_scored='VALID';
    else if c then role_scored='TEST';

    pred_pd_raw=P_1;
run;

/* DQ. */
proc sql noprint;
    select count(*) into :bad_pred trimmed
    from MODEL.pd_scored_v2
    where missing(pred_pd_raw) or pred_pd_raw<0 or pred_pd_raw>1;
quit;

%if &bad_pred.>0 %then %do;
    %put ERROR: MODEL.PD_SCORED_V2 contains &bad_pred invalid PD values.;
    %abort cancel;
%end;

proc sql;
    create table OUT.pd_v2_score_summary as
    select role_scored as role length=5,
           count(*) as observations,
           sum(target_12m) as target_positive_rows,
           mean(target_12m) as observed_default_rate format=percent8.2,
           mean(pred_pd_raw) as mean_predicted_pd format=percent8.2,
           min(pred_pd_raw) as min_predicted_pd format=percent8.4,
           max(pred_pd_raw) as max_predicted_pd format=percent8.2
    from MODEL.pd_scored_v2
    group by role_scored;
quit;

/* Compare to Phase-2 candidate if present. */
%macro compare_v1_v2;
    %if %sysfunc(exist(MODEL.pd_scored)) %then %do;
        proc sql;
            create table OUT.pd_v1_v2_compare as
            select a.role_scored as role length=5,
                   count(*) as matched_rows,
                   mean(abs(a.pred_pd_raw-b.pred_pd)) as mean_abs_diff format=12.10,
                   max(abs(a.pred_pd_raw-b.pred_pd)) as max_abs_diff format=12.10
            from MODEL.pd_scored_v2 as a
            inner join MODEL.pd_scored as b
                on a.account_id=b.account_id
               and a.report_date=b.report_date
            group by a.role_scored;
        quit;

        title "Phase 2A — Candidate V1 vs Repaired V2 Prediction Difference";
        proc print data=OUT.pd_v1_v2_compare noobs; run;
    %end;
%mend;
%compare_v1_v2;

title "Phase 2A — Repaired Champion Score Summary";
proc print data=OUT.pd_v2_score_summary noobs; run;

title "Phase 2A — Repaired Champion Parameter Estimates";
proc print data=OUT.pd_v2_parameters noobs; run;

title;

%put NOTE: ===============================================================;
%put NOTE: PHASE 2A COMPLETE — EXACT DPD COLLINEARITY REMOVED.;
%put NOTE: MODEL.PD_CHAMPION_V2 and MODEL.PD_SCORED_V2 are the validation inputs.;
%put NOTE: ===============================================================;

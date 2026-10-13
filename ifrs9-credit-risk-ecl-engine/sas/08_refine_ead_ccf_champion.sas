/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 5R — EAD / CCF REPAIR AND RECALIBRATION
  08A_REFINE_EAD_CCF_CHAMPION.SAS

  WHY THIS FILE EXISTS
  --------------------
  The first Phase-5 candidate showed material out-of-time instability at the
  6m/12m horizons.  This repair intentionally favors stability and governance:

    * Credit Card 3m: parsimonious direct-CCF regression.
    * Credit Card 6m/12m: development-cohort mean CCF (stable benchmark promoted
      to champion after the complex models failed validation).
    * Auto/Personal 3m/6m/12m: product-by-horizon mean EAD ratio.  The prior
      regression challengers were consistently inferior to this benchmark.

  GOVERNANCE RESET
  ----------------
  The old 2024H1 TEST has already been inspected, so it is no longer treated as
  a pristine holdout for the repaired model.

      DEV       : 01JAN2021 - 30JUN2024
      CALIB     : 01JUL2024 - 31DEC2024   <-- inspect this file's output
      FINALTEST : 01JAN2025 - 31DEC2025   <-- DO NOT evaluate yet

  IMPORTANT
  ---------
  This program DOES NOT print FINALTEST performance.  It only reports sample
  counts for FINALTEST so that 2025 remains genuinely untouched for Phase 5R-B.
============================================================================= */

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.ead_abt);

/*=============================================================================
  1. REBUILD A CLEAN MODELING ABT
=============================================================================*/
data MODEL.ead_model_abt_r;
    set MODEL.ead_abt;
    length role_r $9;

    if default_date >= '01JAN2021'd and default_date <= '30JUN2024'd then role_r='DEV';
    else if default_date >= '01JUL2024'd and default_date <= '31DEC2024'd then role_r='CALIB';
    else if default_date >= '01JAN2025'd and default_date <= '31DEC2025'd then role_r='FINALTEST';
    else delete;

    score_rev_obs=(850-score_at_obs)/50;
    mob_sqrt_obs=sqrt(max(months_on_book,0));
    dpd_clip_obs=min(max(dpd_at_obs,0),60);

    util_eps=min(max(utilization_at_obs,1e-4),1-1e-4);
    util_logit_obs=log(util_eps/(1-util_eps));

    unemployed_flag=(employment_status_current='Unemployed');
    student_flag=(employment_status_current='Student');

    /* Preserve raw CCF; create a governed modeling target only. */
    if product_type='Credit Card' and ccf_eligible=1 then do;
        ccf_model_target=min(max(realized_ccf_raw,0),1.25);
        ccf_target_adjusted=(realized_ccf_raw<0 or realized_ccf_raw>1.25);
    end;

    if product_type in ('Auto Loan','Personal Loan')
       and has_history=1
       and ead_ratio_realized>0 then
        term_target_ok=1;
    else term_target_ok=0;
run;

/*=============================================================================
  2. FINALTEST COUNTS ONLY — NO PERFORMANCE DISCLOSURE
=============================================================================*/
proc sql;
    create table OUT.ead_r_holdout_counts as
    select product_type,
           horizon_months,
           sum(role_r='CALIB') as calib_rows,
           sum(role_r='FINALTEST') as finaltest_rows
    from MODEL.ead_model_abt_r
    where (product_type='Credit Card' and ccf_eligible=1)
       or (product_type in ('Auto Loan','Personal Loan') and term_target_ok=1)
    group by product_type, horizon_months
    order by product_type, horizon_months;
quit;

/*=============================================================================
  3. DEVELOPMENT-ONLY STABLE BASELINES
=============================================================================*/
proc sql;
    create table work.ccf_dev_mean as
    select horizon_months,
           mean(ccf_model_target) as dev_mean_ccf
    from MODEL.ead_model_abt_r
    where role_r='DEV'
      and product_type='Credit Card'
      and ccf_eligible=1
    group by horizon_months;

    create table work.term_dev_mean as
    select product_type,
           horizon_months,
           mean(ead_ratio_realized) as dev_mean_ead_ratio
    from MODEL.ead_model_abt_r
    where role_r='DEV'
      and product_type in ('Auto Loan','Personal Loan')
      and term_target_ok=1
    group by product_type, horizon_months;
quit;

/*=============================================================================
  4. PARSIMONIOUS 3M CREDIT-CARD CCF MODEL

  Key repair:
  We DO NOT include util_logit + log(drawn) + log(undrawn) together.
  Since logit(utilization) ~= log(drawn) - log(undrawn), the old specification
  was rank-deficient / numerically unstable.  We also exclude macro rates here
  to prevent regime extrapolation from dominating a utilization model.
=============================================================================*/
ods output ParameterEstimates=OUT.ccf_h3_refined_parameters;

proc glm data=MODEL.ead_model_abt_r(
            where=(role_r='DEV'
                   and product_type='Credit Card'
                   and horizon_months=3
                   and ccf_eligible=1));
    model ccf_model_target =
        score_rev_obs
        util_logit_obs
        mob_sqrt_obs
        dpd_clip_obs
        unemployed_flag
        student_flag
        / solution;
    store MODEL.ccf_h3_refined_store;
quit;

ods output close;

proc plm restore=MODEL.ccf_h3_refined_store;
    score data=MODEL.ead_model_abt_r(
              where=(product_type='Credit Card'
                     and horizon_months=3
                     and ccf_eligible=1))
          out=work.card_h3_scored
          predicted=pred_ccf_reg_raw;
run;

proc sql;
    create table work.card_h3_scored as
    select a.*, b.dev_mean_ccf
    from work.card_h3_scored as a
    left join work.ccf_dev_mean as b
      on a.horizon_months=b.horizon_months;
quit;

data work.card_h3_scored;
    set work.card_h3_scored;
    pred_ccf_reg=min(max(pred_ccf_reg_raw,0),1.25);
    pred_ccf_mean=dev_mean_ccf;

    actual_ead=ead_at_default;
    pred_ead_reg=max(0, drawn_at_obs + pred_ccf_reg*undrawn_at_obs);
    pred_ead_mean=max(0, drawn_at_obs + pred_ccf_mean*undrawn_at_obs);
run;

/*=============================================================================
  5. CREDIT CARD 6M/12M — STABLE MEAN-CCF CHAMPION
=============================================================================*/
proc sql;
    create table work.card_mean_scored as
    select a.*, b.dev_mean_ccf
    from MODEL.ead_model_abt_r as a
    left join work.ccf_dev_mean as b
      on a.horizon_months=b.horizon_months
    where a.product_type='Credit Card'
      and a.horizon_months in (6,12)
      and a.ccf_eligible=1;
quit;

data work.card_mean_scored;
    set work.card_mean_scored;
    pred_ccf_selected=dev_mean_ccf;
    actual_ead=ead_at_default;
    pred_ead_selected=max(0, drawn_at_obs + pred_ccf_selected*undrawn_at_obs);
run;

/* H3 candidate table keeps BOTH regression and mean so CALIB decides. */
data work.card_h3_compare;
    set work.card_h3_scored;
run;

/*=============================================================================
  6. TERM LOANS — PRODUCT x HORIZON MEAN EAD-RATIO CHAMPION
=============================================================================*/
proc sql;
    create table MODEL.term_ead_scored_r as
    select a.*, b.dev_mean_ead_ratio
    from MODEL.ead_model_abt_r as a
    left join work.term_dev_mean as b
      on a.product_type=b.product_type
     and a.horizon_months=b.horizon_months
    where a.product_type in ('Auto Loan','Personal Loan')
      and a.term_target_ok=1;
quit;

data MODEL.term_ead_scored_r;
    set MODEL.term_ead_scored_r;
    pred_ead_ratio_selected=dev_mean_ead_ratio;
    actual_ead=ead_at_default;
    pred_ead_selected=max(0,pred_ead_ratio_selected*drawn_at_obs);
run;

/*=============================================================================
  7. CALIBRATION-ONLY AUDIT — CREDIT CARD
=============================================================================*/
proc sql;
    create table OUT.ccf_r_h3_calib_compare as
    select 'REGRESSION' as candidate length=12,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(pred_ccf_reg) as predicted_ccf format=8.4,
           sqrt(mean((pred_ccf_reg-ccf_model_target)**2)) as rmse format=8.4,
           mean(abs(pred_ccf_reg-ccf_model_target)) as mae format=8.4,
           mean(pred_ccf_reg-ccf_model_target) as bias format=8.4,
           sum(pred_ead_reg)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_h3_compare
    where role_r='CALIB'

    union all

    select 'DEV_MEAN' as candidate length=12,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(pred_ccf_mean) as predicted_ccf format=8.4,
           sqrt(mean((pred_ccf_mean-ccf_model_target)**2)) as rmse format=8.4,
           mean(abs(pred_ccf_mean-ccf_model_target)) as mae format=8.4,
           mean(pred_ccf_mean-ccf_model_target) as bias format=8.4,
           sum(pred_ead_mean)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_h3_compare
    where role_r='CALIB';

    create table OUT.ccf_r_long_calib as
    select horizon_months,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(pred_ccf_selected) as predicted_ccf format=8.4,
           sqrt(mean((pred_ccf_selected-ccf_model_target)**2)) as rmse format=8.4,
           mean(abs(pred_ccf_selected-ccf_model_target)) as mae format=8.4,
           mean(pred_ccf_selected-ccf_model_target) as bias format=8.4,
           sum(pred_ead_selected)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_mean_scored
    where role_r='CALIB'
    group by horizon_months
    order by horizon_months;
quit;

/*=============================================================================
  8. CALIBRATION-ONLY AUDIT — TERM LOANS
=============================================================================*/
proc sql;
    create table OUT.term_ead_r_calib as
    select product_type,
           horizon_months,
           count(*) as n,
           mean(ead_ratio_realized) as observed_ratio format=8.4,
           mean(pred_ead_ratio_selected) as predicted_ratio format=8.4,
           sqrt(mean((pred_ead_ratio_selected-ead_ratio_realized)**2)) as rmse format=8.4,
           mean(abs(pred_ead_ratio_selected-ead_ratio_realized)) as mae format=8.4,
           mean(pred_ead_ratio_selected-ead_ratio_realized) as bias format=8.4,
           sum(pred_ead_selected)/sum(actual_ead) as ead_bt_ratio format=8.4
    from MODEL.term_ead_scored_r
    where role_r='CALIB'
    group by product_type, horizon_months
    order by product_type, horizon_months;
quit;

/*=============================================================================
  9. PERSIST CREDIT-CARD REPAIR SCORING FOR THE LATER FINAL TEST
=============================================================================*/
data MODEL.ccf_h3_scored_r;
    set work.card_h3_scored;
run;

data MODEL.ccf_long_scored_r;
    set work.card_mean_scored;
run;

/*=============================================================================
  10. RESULTS — FINALTEST PERFORMANCE IS INTENTIONALLY NOT SHOWN
=============================================================================*/
ods noproctitle;

title "Phase 5R — Holdout Row Counts Only (2025 Performance Still Hidden)";
proc print data=OUT.ead_r_holdout_counts noobs; run;

title "Phase 5R — 3M Credit Card CALIB: Parsimonious Regression vs DEV Mean";
proc print data=OUT.ccf_r_h3_calib_compare noobs; run;

title "Phase 5R — Credit Card 6M/12M CALIB: Stable DEV-Mean CCF";
proc print data=OUT.ccf_r_long_calib noobs; run;

title "Phase 5R — Term-Loan CALIB: Product x Horizon DEV-Mean EAD Ratio";
proc print data=OUT.term_ead_r_calib noobs; run;

title "Phase 5R — Refined 3M CCF Parameters";
proc print data=OUT.ccf_h3_refined_parameters noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 5R CALIBRATION BUILD COMPLETE.;
%put NOTE: DO NOT RUN FINALTEST VALIDATION UNTIL THESE CALIB TABLES ARE REVIEWED.;
%put NOTE: ===============================================================;

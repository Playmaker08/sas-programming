/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 3 — PIT PD VALIDATION + OOT CALIBRATION
  05_VALIDATE_CALIBRATE_PIT_PD.SAS

  INPUT
  -----
  MODEL.PD_SCORED_V2

  VALIDATION FRAMEWORK
  --------------------
  1) AUC / Gini (rank-statistic implementation; no model refit)
  2) KS statistic from frozen predicted PD
  3) Brier score
  4) Decile calibration / Lift / Gains
  5) Hosmer-Lemeshow-style grouped calibration statistic
  6) Population Stability Index using FIXED TRAIN cutpoints
  7) Calibration intercept/slope diagnostics
  8) VALID-only logistic recalibration, then untouched TEST evaluation

  GOVERNANCE
  ----------
  - TRAIN developed the base model.
  - VALID estimates the calibration layer only.
  - TEST remains untouched until final evaluation.
  - No test information is used to choose calibration parameters.
============================================================================= */

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;
%assert_ds(ds=MODEL.pd_scored_v2);

/*---------------------------------------------------------------------------
  0. PREP
---------------------------------------------------------------------------*/
data work.pd_val;
    set MODEL.pd_scored_v2;

    /* Numerical guard only for logit transforms; raw PD is not overwritten. */
    pd_eps=min(max(pred_pd_raw,1e-6),1-1e-6);
    logit_pd_raw=log(pd_eps/(1-pd_eps));
    sqerr_raw=(pred_pd_raw-target_12m)**2;
run;

/*---------------------------------------------------------------------------
  1. AUC / GINI — Mann-Whitney rank identity
---------------------------------------------------------------------------*/
proc sort data=work.pd_val out=work.auc_input;
    by role_scored;
run;

proc rank data=work.auc_input out=work.auc_rank ties=mean;
    by role_scored;
    var pred_pd_raw;
    ranks pd_rank;
run;

proc sql;
    create table OUT.pd_auc_gini as
    select role_scored as role length=5,
           sum(target_12m) as n_bad,
           sum(1-target_12m) as n_good,
           sum(case when target_12m=1 then pd_rank else 0 end) as bad_rank_sum,
           (calculated bad_rank_sum
             - calculated n_bad*(calculated n_bad+1)/2)
             /(calculated n_bad*calculated n_good) as auc format=8.4,
           2*calculated auc-1 as gini format=8.4
    from work.auc_rank
    group by role_scored;
quit;

/*---------------------------------------------------------------------------
  2. KS — aggregate tied scores first, then cumulative distributions
---------------------------------------------------------------------------*/
proc sql;
    create table work.ks_ties as
    select role_scored,
           pred_pd_raw,
           sum(target_12m) as bads,
           sum(1-target_12m) as goods
    from work.pd_val
    group by role_scored, pred_pd_raw
    order by role_scored, pred_pd_raw desc;

    create table work.ks_totals as
    select role_scored,
           sum(target_12m) as total_bads,
           sum(1-target_12m) as total_goods
    from work.pd_val
    group by role_scored;
quit;

data work.ks_curve;
    merge work.ks_ties(in=a) work.ks_totals;
    by role_scored;
    retain cum_bads cum_goods;

    if first.role_scored then do;
        cum_bads=0;
        cum_goods=0;
    end;

    cum_bads+bads;
    cum_goods+goods;

    cdf_bad=cum_bads/total_bads;
    cdf_good=cum_goods/total_goods;
    ks_gap=abs(cdf_bad-cdf_good);
run;

proc sql;
    create table OUT.pd_ks as
    select role_scored as role length=5,
           max(ks_gap) as ks format=8.4
    from work.ks_curve
    group by role_scored;
quit;

/*---------------------------------------------------------------------------
  3. BRIER + PORTFOLIO CALIBRATION GAP
---------------------------------------------------------------------------*/
proc sql;
    create table OUT.pd_brier_calibration as
    select role_scored as role length=5,
           count(*) as observations,
           mean(target_12m) as observed_rate format=percent8.2,
           mean(pred_pd_raw) as mean_pd_raw format=percent8.2,
           mean(sqerr_raw) as brier_raw format=10.6,
           mean(pred_pd_raw)-mean(target_12m) as calibration_gap format=percent8.2
    from work.pd_val
    group by role_scored;
quit;

/*---------------------------------------------------------------------------
  4. RAW DECILE TABLES / LIFT / GAINS BY ROLE
---------------------------------------------------------------------------*/
proc sort data=work.pd_val out=work.decile_input;
    by role_scored;
run;

proc rank data=work.decile_input out=work.decile_rank groups=10 descending;
    by role_scored;
    var pred_pd_raw;
    ranks dec0;
run;

data work.decile_rank;
    set work.decile_rank;
    decile=dec0+1; /* 1 = highest risk */
run;

proc sql;
    create table work.decile_base as
    select role_scored as role length=5,
           decile,
           count(*) as n,
           sum(target_12m) as bads,
           mean(target_12m) as observed_rate,
           mean(pred_pd_raw) as mean_pred_pd
    from work.decile_rank
    group by role_scored, decile
    order by role, decile;

    create table work.role_bad_totals as
    select role_scored as role length=5,
           sum(target_12m) as total_bads,
           mean(target_12m) as portfolio_bad_rate
    from work.pd_val
    group by role_scored;
quit;

data OUT.pd_decile_lift;
    merge work.decile_base work.role_bad_totals;
    by role;
    retain cum_bads;
    if first.role then cum_bads=0;
    cum_bads+bads;

    bad_rate=observed_rate;
    lift=bad_rate/portfolio_bad_rate;
    capture=bads/total_bads;
    cumulative_gain=cum_bads/total_bads;

    format observed_rate mean_pred_pd bad_rate portfolio_bad_rate percent8.2
           capture cumulative_gain percent8.2 lift 8.2;
run;

/*---------------------------------------------------------------------------
  5. HOSMER-LEMESHOW-STYLE GROUPED CALIBRATION STATISTIC
     Uses the same role-specific deciles only as a diagnostic.
---------------------------------------------------------------------------*/
proc sql;
    create table work.hl_cells as
    select role_scored as role length=5,
           decile,
           count(*) as n,
           sum(target_12m) as observed,
           sum(pred_pd_raw) as expected
    from work.decile_rank
    group by role_scored, decile;
quit;

data work.hl_cells;
    set work.hl_cells;
    expected_non=n-expected;
    observed_non=n-observed;

    if expected>0 and expected_non>0 then
        hl_component=((observed-expected)**2/expected)
                   + ((observed_non-expected_non)**2/expected_non);
    else hl_component=.;
run;

proc sql;
    create table OUT.pd_hl as
    select role,
           sum(hl_component) as hl_stat format=10.3,
           count(hl_component) as groups_used,
           max(count(hl_component)-2,1) as approx_df
    from work.hl_cells
    group by role;
quit;

/*---------------------------------------------------------------------------
  6. PSI — FIX TRAIN CUTPOINTS, APPLY IDENTICALLY TO VALID/TEST
---------------------------------------------------------------------------*/
proc univariate data=work.pd_val(where=(role_scored='TRAIN')) noprint;
    var pred_pd_raw;
    output out=work.train_cuts
        pctlpts=10 20 30 40 50 60 70 80 90
        pctlpre=p_;
run;

data _null_;
    set work.train_cuts;
    call symputx('c10',p_10);
    call symputx('c20',p_20);
    call symputx('c30',p_30);
    call symputx('c40',p_40);
    call symputx('c50',p_50);
    call symputx('c60',p_60);
    call symputx('c70',p_70);
    call symputx('c80',p_80);
    call symputx('c90',p_90);
run;

data work.psi_binned;
    set work.pd_val;

    if pred_pd_raw <= &c10 then psi_bin=1;
    else if pred_pd_raw <= &c20 then psi_bin=2;
    else if pred_pd_raw <= &c30 then psi_bin=3;
    else if pred_pd_raw <= &c40 then psi_bin=4;
    else if pred_pd_raw <= &c50 then psi_bin=5;
    else if pred_pd_raw <= &c60 then psi_bin=6;
    else if pred_pd_raw <= &c70 then psi_bin=7;
    else if pred_pd_raw <= &c80 then psi_bin=8;
    else if pred_pd_raw <= &c90 then psi_bin=9;
    else psi_bin=10;
run;

proc sql;
    create table work.psi_counts as
    select role_scored as role length=5,
           psi_bin,
           count(*) as n
    from work.psi_binned
    group by role_scored, psi_bin;

    create table work.psi_totals as
    select role_scored as role length=5,
           count(*) as total_n
    from work.psi_binned
    group by role_scored;

    create table work.psi_props as
    select a.role,
           a.psi_bin,
           a.n/b.total_n as pct
    from work.psi_counts as a
    left join work.psi_totals as b
      on a.role=b.role;

    create table work.train_props as
    select psi_bin, pct as train_pct
    from work.psi_props
    where role='TRAIN';

    create table work.psi_components as
    select a.role,
           a.psi_bin,
           max(a.pct,1e-6) as role_pct,
           max(b.train_pct,1e-6) as train_pct,
           (calculated role_pct-calculated train_pct)
             *log(calculated role_pct/calculated train_pct) as psi_component
    from work.psi_props as a
    inner join work.train_props as b
      on a.psi_bin=b.psi_bin
    where a.role in ('VALID','TEST');

    create table OUT.pd_psi as
    select role,
           sum(psi_component) as psi format=8.4
    from work.psi_components
    group by role;
quit;

/*---------------------------------------------------------------------------
  7. CALIBRATION INTERCEPT / SLOPE DIAGNOSTICS BY ROLE
     These are diagnostics only; only VALID is used for the actual recalibration.
---------------------------------------------------------------------------*/
%macro cal_diag(role=, out=);
    ods output ParameterEstimates=&out.;
    proc logistic data=work.pd_val(where=(role_scored="&role."));
        model target_12m(event='1') = logit_pd_raw;
    run;
    ods output close;
%mend;

%cal_diag(role=TRAIN, out=work.cal_train);
%cal_diag(role=VALID, out=work.cal_valid);
%cal_diag(role=TEST,  out=work.cal_test);

data OUT.pd_calibration_diagnostics;
    length role $5;
    set work.cal_train(in=a)
        work.cal_valid(in=b)
        work.cal_test(in=c);
    if a then role='TRAIN';
    else if b then role='VALID';
    else if c then role='TEST';
    keep role Variable Estimate StdErr WaldChiSq ProbChiSq;
run;

/*---------------------------------------------------------------------------
  8. VALID-ONLY RECALIBRATION: logit(Y)=a+b*logit(PD_raw)
---------------------------------------------------------------------------*/
proc logistic data=work.pd_val(where=(role_scored='VALID'))
              outest=work.valid_cal_est noprint;
    model target_12m(event='1') = logit_pd_raw;
run;

data _null_;
    set work.valid_cal_est;
    call symputx('cal_a',Intercept);
    call symputx('cal_b',logit_pd_raw);
run;

data OUT.pd_calibration_params;
    length calibration_source $20;
    calibration_source='VALID OOT';
    intercept=&cal_a.;
    slope=&cal_b.;
run;

data MODEL.pd_scored_final;
    set work.pd_val;

    pred_pd_cal = 1/(1+exp(-(&cal_a. + &cal_b.*logit_pd_raw)));
    pred_pd_final=pred_pd_cal;
    sqerr_cal=(pred_pd_cal-target_12m)**2;
run;

/* Final TEST comparison — this is the untouched holdout evaluation. */
proc sql;
    create table OUT.pd_test_calibration_compare as
    select count(*) as observations,
           sum(target_12m) as target_positive_rows,
           mean(target_12m) as observed_rate format=percent8.2,
           mean(pred_pd_raw) as raw_mean_pd format=percent8.2,
           mean(pred_pd_cal) as calibrated_mean_pd format=percent8.2,
           mean(sqerr_raw) as raw_brier format=10.6,
           mean(sqerr_cal) as calibrated_brier format=10.6
    from MODEL.pd_scored_final
    where role_scored='TEST';
quit;

/* TEST calibration table after VALID-only recalibration. */
proc rank data=MODEL.pd_scored_final(where=(role_scored='TEST'))
          out=work.test_cal_dec groups=10 descending;
    var pred_pd_cal;
    ranks dec0;
run;

data work.test_cal_dec;
    set work.test_cal_dec;
    decile=dec0+1;
run;

proc sql;
    create table OUT.pd_test_cal_deciles as
    select decile,
           count(*) as n,
           sum(target_12m) as bads,
           mean(target_12m) as observed_rate format=percent8.2,
           mean(pred_pd_raw) as raw_mean_pd format=percent8.2,
           mean(pred_pd_cal) as calibrated_mean_pd format=percent8.2
    from work.test_cal_dec
    group by decile
    order by decile;
quit;

/*---------------------------------------------------------------------------
  9. MASTER VALIDATION SUMMARY
---------------------------------------------------------------------------*/
proc sql;
    create table OUT.pd_validation_summary as
    select a.role,
           a.auc,
           a.gini,
           b.ks,
           c.brier_raw,
           c.observed_rate,
           c.mean_pd_raw,
           c.calibration_gap,
           d.hl_stat,
           case when a.role='TRAIN' then 0 else e.psi end as psi
    from OUT.pd_auc_gini as a
    left join OUT.pd_ks as b on a.role=b.role
    left join OUT.pd_brier_calibration as c on a.role=c.role
    left join OUT.pd_hl as d on a.role=d.role
    left join OUT.pd_psi as e on a.role=e.role
    order by case a.role when 'TRAIN' then 1 when 'VALID' then 2 else 3 end;
quit;

/*---------------------------------------------------------------------------
  10. RESULTS
---------------------------------------------------------------------------*/
ods noproctitle;

title "Phase 3 — PD Validation Summary";
proc print data=OUT.pd_validation_summary noobs; run;

title "Phase 3 — Calibration Intercept / Slope Diagnostics";
proc print data=OUT.pd_calibration_diagnostics noobs; run;

title "Phase 3 — VALID-Only Calibration Parameters";
proc print data=OUT.pd_calibration_params noobs; run;

title "Phase 3 — Untouched TEST: Raw vs Calibrated PD";
proc print data=OUT.pd_test_calibration_compare noobs; run;

title "Phase 3 — TEST Calibration by Risk Decile";
proc print data=OUT.pd_test_cal_deciles noobs; run;

title "Phase 3 — TEST Lift / Gains (Raw Ranking)";
proc print data=OUT.pd_decile_lift(where=(role='TEST')) noobs; run;

title "Phase 3 — PSI vs TRAIN Fixed Score Bands";
proc print data=OUT.pd_psi noobs; run;

title;

%put NOTE: ===============================================================;
%put NOTE: PHASE 3 COMPLETE — PIT PD VALIDATED AND VALID-ONLY CALIBRATED.;
%put NOTE: TEST WAS NOT USED TO ESTIMATE BASE-MODEL OR CALIBRATION PARAMETERS.;
%put NOTE: ===============================================================;

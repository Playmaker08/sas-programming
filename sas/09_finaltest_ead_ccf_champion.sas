/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 5R-B — FINAL OUT-OF-TIME EAD / CCF VALIDATION
  09A_FINALTEST_EAD_CCF_CHAMPION.SAS

  PURPOSE
  -------
  Reveal the previously hidden 2025 FINALTEST performance exactly once for the
  repaired Phase-5 champion architecture selected using DEV + CALIB only.

  LOCKED CHAMPION ARCHITECTURE
  ----------------------------
    Credit Card 3m  : parsimonious direct-CCF regression from 08A
    Credit Card 6m  : DEV mean CCF
    Credit Card 12m : DEV mean CCF
    Auto Loan 3/6/12m     : product x horizon DEV mean EAD ratio
    Personal Loan 3/6/12m : product x horizon DEV mean EAD ratio

  IMPORTANT GOVERNANCE RULE
  -------------------------
  This program DOES NOT refit, recalibrate, retune, or alter the champion.
  It only evaluates the already-frozen predictions persisted by 08A.
============================================================================= */

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.ccf_h3_scored_r);
%assert_ds(ds=MODEL.ccf_long_scored_r);
%assert_ds(ds=MODEL.term_ead_scored_r);
%assert_ds(ds=OUT.ccf_r_h3_calib_compare);
%assert_ds(ds=OUT.ccf_r_long_calib);
%assert_ds(ds=OUT.term_ead_r_calib);

/*=============================================================================
  1. LOCK THE FINALTEST SCORING TABLES — NO REFITTING
=============================================================================*/
data work.card_h3_final;
    set MODEL.ccf_h3_scored_r;
    where role_r='FINALTEST';

    selected_ccf = pred_ccf_reg;
    selected_ead = pred_ead_reg;
    baseline_ccf = pred_ccf_mean;
    baseline_ead = pred_ead_mean;
run;

data work.card_long_final;
    set MODEL.ccf_long_scored_r;
    where role_r='FINALTEST';

    selected_ccf = pred_ccf_selected;
    selected_ead = pred_ead_selected;
run;

data work.term_final;
    set MODEL.term_ead_scored_r;
    where role_r='FINALTEST';
run;

/*=============================================================================
  2. CREDIT CARD 3M — FINALTEST CHAMPION VS DEV-MEAN BENCHMARK
=============================================================================*/
proc sql;
    create table OUT.ccf_r_h3_final_compare as
    select 'REFINED_REG' as candidate length=12,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(selected_ccf) as predicted_ccf format=8.4,
           sqrt(mean((selected_ccf-ccf_model_target)**2)) as rmse format=8.4,
           mean(abs(selected_ccf-ccf_model_target)) as mae format=8.4,
           mean(selected_ccf-ccf_model_target) as bias format=8.4,
           sum(selected_ead)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_h3_final

    union all

    select 'DEV_MEAN' as candidate length=12,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(baseline_ccf) as predicted_ccf format=8.4,
           sqrt(mean((baseline_ccf-ccf_model_target)**2)) as rmse format=8.4,
           mean(abs(baseline_ccf-ccf_model_target)) as mae format=8.4,
           mean(baseline_ccf-ccf_model_target) as bias format=8.4,
           sum(baseline_ead)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_h3_final;
quit;

/*=============================================================================
  3. CREDIT CARD 6M / 12M — FINALTEST PORTFOLIO BACKTEST
=============================================================================*/
proc sql;
    create table OUT.ccf_r_long_final as
    select horizon_months,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(selected_ccf) as predicted_ccf format=8.4,
           sqrt(mean((selected_ccf-ccf_model_target)**2)) as rmse format=8.4,
           mean(abs(selected_ccf-ccf_model_target)) as mae format=8.4,
           mean(selected_ccf-ccf_model_target) as bias format=8.4,
           sum(selected_ead)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_long_final
    group by horizon_months
    order by horizon_months;
quit;

/*=============================================================================
  4. CREDIT CARD 3M — FINALTEST CALIBRATION BY PREDICTED CCF QUINTILE

  This is diagnostic only.  Quintiles are created after scoring and are NOT
  used to modify the model.
=============================================================================*/
proc rank data=work.card_h3_final out=work.card_h3_q groups=5 descending;
    var selected_ccf;
    ranks q0;
run;

data work.card_h3_q;
    set work.card_h3_q;
    quintile=q0+1;
run;

proc sql;
    create table OUT.ccf_r_h3_final_quintile as
    select quintile,
           count(*) as n,
           mean(ccf_model_target) as observed_ccf format=8.4,
           mean(selected_ccf) as predicted_ccf format=8.4,
           mean(selected_ccf-ccf_model_target) as gap format=8.4,
           sum(selected_ead)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.card_h3_q
    group by quintile
    order by quintile;
quit;

/*=============================================================================
  5. TERM LOANS — FINALTEST PORTFOLIO BACKTEST
=============================================================================*/
proc sql;
    create table OUT.term_ead_r_final as
    select product_type,
           horizon_months,
           count(*) as n,
           mean(ead_ratio_realized) as observed_ratio format=8.4,
           mean(pred_ead_ratio_selected) as predicted_ratio format=8.4,
           sqrt(mean((pred_ead_ratio_selected-ead_ratio_realized)**2)) as rmse format=8.4,
           mean(abs(pred_ead_ratio_selected-ead_ratio_realized)) as mae format=8.4,
           mean(pred_ead_ratio_selected-ead_ratio_realized) as bias format=8.4,
           sum(pred_ead_selected)/sum(actual_ead) as ead_bt_ratio format=8.4
    from work.term_final
    group by product_type, horizon_months
    order by product_type, horizon_months;
quit;

/*=============================================================================
  6. CALIB -> FINALTEST STABILITY CHECK
=============================================================================*/
proc sql;
    create table OUT.ead_r_stability_card as
    select 3 as horizon_months,
           a.ead_bt_ratio as calib_bt_ratio format=8.4,
           b.ead_bt_ratio as final_bt_ratio format=8.4,
           (b.ead_bt_ratio-a.ead_bt_ratio) as bt_ratio_change format=8.4
    from OUT.ccf_r_h3_calib_compare as a,
         OUT.ccf_r_h3_final_compare as b
    where a.candidate='REGRESSION'
      and b.candidate='REFINED_REG'

    union all

    select a.horizon_months,
           a.ead_bt_ratio as calib_bt_ratio format=8.4,
           b.ead_bt_ratio as final_bt_ratio format=8.4,
           (b.ead_bt_ratio-a.ead_bt_ratio) as bt_ratio_change format=8.4
    from OUT.ccf_r_long_calib as a
    inner join OUT.ccf_r_long_final as b
      on a.horizon_months=b.horizon_months
    order by horizon_months;

    create table OUT.ead_r_stability_term as
    select a.product_type,
           a.horizon_months,
           a.ead_bt_ratio as calib_bt_ratio format=8.4,
           b.ead_bt_ratio as final_bt_ratio format=8.4,
           (b.ead_bt_ratio-a.ead_bt_ratio) as bt_ratio_change format=8.4
    from OUT.term_ead_r_calib as a
    inner join OUT.term_ead_r_final as b
      on a.product_type=b.product_type
     and a.horizon_months=b.horizon_months
    order by a.product_type, a.horizon_months;
quit;

/*=============================================================================
  7. PROJECT GOVERNANCE GATES

  Guardrail used here: portfolio EAD backtest ratio in [0.90, 1.10].
  For Credit Card 3m, the refined regression must ALSO beat the DEV-mean
  benchmark on both RMSE and MAE on FINALTEST.
=============================================================================*/
proc sql noprint;
    select ead_bt_ratio, rmse, mae
      into :h3_bt, :h3_rmse, :h3_mae
    from OUT.ccf_r_h3_final_compare
    where candidate='REFINED_REG';

    select rmse, mae
      into :h3_base_rmse, :h3_base_mae
    from OUT.ccf_r_h3_final_compare
    where candidate='DEV_MEAN';
quit;

data work.gate_h3;
    length component $32 status $8 rule $120;
    component='Credit Card 3M';
    horizon_months=3;
    ead_bt_ratio=&h3_bt.;
    metric_1=&h3_rmse.;
    metric_2=&h3_mae.;
    rule='BT ratio 0.90-1.10 AND regression RMSE/MAE < DEV-mean benchmark';
    if (ead_bt_ratio >= 0.90 and ead_bt_ratio <= 1.10)
       and (&h3_rmse. < &h3_base_rmse.)
       and (&h3_mae.  < &h3_base_mae.) then status='PASS';
    else status='FAIL';
run;

data work.gate_card_long;
    set OUT.ccf_r_long_final;
    length component $32 status $8 rule $120;
    component=cats('Credit Card ',strip(put(horizon_months,2.)),'M');
    metric_1=rmse;
    metric_2=mae;
    rule='Portfolio EAD backtest ratio in [0.90, 1.10]';
    if ead_bt_ratio >= 0.90 and ead_bt_ratio <= 1.10 then status='PASS';
    else status='FAIL';
    keep component horizon_months ead_bt_ratio metric_1 metric_2 rule status;
run;

data work.term_gate;
    set OUT.term_ead_r_final;
    length component $32 status $8 rule $120;
    component=cats(product_type,' ',strip(put(horizon_months,2.)),'M');
    metric_1=rmse;
    metric_2=mae;
    rule='Portfolio EAD backtest ratio in [0.90, 1.10]';
    if ead_bt_ratio >= 0.90 and ead_bt_ratio <= 1.10 then status='PASS';
    else status='FAIL';
    keep component horizon_months ead_bt_ratio metric_1 metric_2 rule status;
run;

data OUT.ead_r_governance_gate;
    set work.gate_h3 work.gate_card_long work.term_gate;
run;

proc sql;
    create table OUT.ead_r_final_decision as
    select count(*) as components,
           sum(status='PASS') as passed,
           sum(status='FAIL') as failed,
           case when calculated failed=0 then 'PHASE 5R APPROVED'
                else 'PHASE 5R NOT APPROVED'
           end as final_decision length=24
    from OUT.ead_r_governance_gate;
quit;

/*=============================================================================
  8. RESULTS — THIS IS THE ONE-TIME 2025 REVEAL
=============================================================================*/
ods noproctitle;

title "Phase 5R-B — FINALTEST 2025: Credit Card 3M Refined Regression vs DEV Mean";
proc print data=OUT.ccf_r_h3_final_compare noobs; run;

title "Phase 5R-B — FINALTEST 2025: Credit Card 6M/12M Stable CCF Champion";
proc print data=OUT.ccf_r_long_final noobs; run;

title "Phase 5R-B — FINALTEST 2025: Credit Card 3M Calibration by Predicted CCF Quintile";
proc print data=OUT.ccf_r_h3_final_quintile noobs; run;

title "Phase 5R-B — FINALTEST 2025: Term-Loan Stable EAD-Ratio Champion";
proc print data=OUT.term_ead_r_final noobs; run;

title "Phase 5R-B — CALIB to FINALTEST Stability: Credit Card";
proc print data=OUT.ead_r_stability_card noobs; run;

title "Phase 5R-B — CALIB to FINALTEST Stability: Term Loans";
proc print data=OUT.ead_r_stability_term noobs; run;

title "Phase 5R-B — Final Governance Gate";
proc print data=OUT.ead_r_governance_gate noobs; run;

title "Phase 5R-B — Final Phase Decision";
proc print data=OUT.ead_r_final_decision noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 5R-B FINALTEST EVALUATION COMPLETE.;
%put NOTE: 2025 HOLDOUT HAS NOW BEEN OPENED. DO NOT RETUNE AGAINST IT.;
%put NOTE: ===============================================================;

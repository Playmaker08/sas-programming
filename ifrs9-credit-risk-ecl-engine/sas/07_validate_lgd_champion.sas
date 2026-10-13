/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 4B — LGD VALIDATION
  07_VALIDATE_LGD_CHAMPION.SAS

  INPUT
  -----
  MODEL.LGD_SCORED

  VALIDATION
  ----------
  1) Champion vs baseline RMSE / MAE / bias
  2) Product and time-split calibration
  3) TEST calibration by predicted-LGD quintile
  4) Tail / boundary diagnostics
  5) Residual diagnostics by key risk segments
============================================================================= */

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;
%assert_ds(ds=MODEL.lgd_scored);

/*=============================================================================
  1. CALIBRATION BY ROLE / PRODUCT
=============================================================================*/
proc sql;
    create table OUT.lgd_calibration_summary as
    select role,
           product_type,
           count(*) as n,
           mean(realized_lgd_full) as observed_lgd format=percent8.2,
           mean(pred_lgd_champion) as predicted_lgd format=percent8.2,
           mean(pred_lgd_champion-realized_lgd_full)
               as calibration_gap format=percent8.2,
           sqrt(mean((pred_lgd_champion-realized_lgd_full)**2))
               as rmse format=8.4,
           mean(abs(pred_lgd_champion-realized_lgd_full))
               as mae format=8.4
    from MODEL.lgd_scored
    group by role, product_type
    order by role, product_type;
quit;

/*=============================================================================
  2. TEST QUINTILE CALIBRATION WITHIN PRODUCT
=============================================================================*/
proc sort data=MODEL.lgd_scored(where=(role='TEST')) out=work.test_lgd;
    by product_type;
run;

proc rank data=work.test_lgd out=work.test_lgd_rank groups=5 descending;
    by product_type;
    var pred_lgd_champion;
    ranks q0;
run;

data work.test_lgd_rank;
    set work.test_lgd_rank;
    quintile=q0+1; /* 1 = highest predicted LGD */
run;

proc sql;
    create table OUT.lgd_test_quintile_calibration as
    select product_type,
           quintile,
           count(*) as n,
           mean(realized_lgd_full) as observed_lgd format=percent8.2,
           mean(pred_lgd_champion) as predicted_lgd format=percent8.2,
           mean(pred_lgd_champion-realized_lgd_full)
               as gap format=percent8.2
    from work.test_lgd_rank
    group by product_type, quintile
    order by product_type, quintile;
quit;

/*=============================================================================
  3. BOUNDARY / TAIL DIAGNOSTICS
=============================================================================*/
proc sql;
    create table OUT.lgd_boundary_diagnostics as
    select role,
           product_type,
           count(*) as n,
           mean(realized_lgd_full>=0.9999) as pct_full_loss format=percent8.2,
           mean(realized_lgd_full<=0.0001) as pct_zero_loss format=percent8.2,
           mean(pred_lgd_champion>=0.95) as pct_pred_ge95 format=percent8.2,
           mean(pred_lgd_champion<=0.05) as pct_pred_le05 format=percent8.2
    from MODEL.lgd_scored
    group by role, product_type
    order by role, product_type;
quit;

/*=============================================================================
  4. SEGMENT RESIDUALS
=============================================================================*/
proc sql;
    create table OUT.lgd_score_segment_validation as
    select role,
           product_type,
           orig_score_tier,
           count(*) as n,
           mean(realized_lgd_full) as observed_lgd format=percent8.2,
           mean(pred_lgd_champion) as predicted_lgd format=percent8.2,
           mean(pred_lgd_champion-realized_lgd_full)
               as gap format=percent8.2
    from MODEL.lgd_scored
    group by role, product_type, orig_score_tier
    order by role, product_type, orig_score_tier;
quit;

/*=============================================================================
  5. TEST-ONLY CHAMPION VS BASELINE SUMMARY
=============================================================================*/
proc sql;
    create table OUT.lgd_test_final as
    select
        count(*) as test_defaults,
        mean(realized_lgd_full) as observed_lgd format=percent8.2,
        mean(pred_lgd_champion) as champion_mean_lgd format=percent8.2,
        mean(pred_lgd_baseline) as baseline_mean_lgd format=percent8.2,
        sqrt(mean((pred_lgd_champion-realized_lgd_full)**2))
            as champion_rmse format=8.4,
        sqrt(mean((pred_lgd_baseline-realized_lgd_full)**2))
            as baseline_rmse format=8.4,
        mean(abs(pred_lgd_champion-realized_lgd_full))
            as champion_mae format=8.4,
        mean(abs(pred_lgd_baseline-realized_lgd_full))
            as baseline_mae format=8.4,
        mean(pred_lgd_champion-realized_lgd_full)
            as champion_bias format=8.4
    from MODEL.lgd_scored
    where role='TEST';
quit;

ods noproctitle;

title "Phase 4B — LGD Calibration Summary";
proc print data=OUT.lgd_calibration_summary noobs; run;

title "Phase 4B — TEST Calibration by Predicted LGD Quintile";
proc print data=OUT.lgd_test_quintile_calibration noobs; run;

title "Phase 4B — LGD Boundary / Tail Diagnostics";
proc print data=OUT.lgd_boundary_diagnostics noobs; run;

title "Phase 4B — LGD Validation by Origination Score Tier";
proc print data=OUT.lgd_score_segment_validation noobs; run;

title "Phase 4B — Untouched TEST Champion vs Baseline";
proc print data=OUT.lgd_test_final noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 4B LGD VALIDATION COMPLETE.;
%put NOTE: ===============================================================;

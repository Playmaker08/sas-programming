/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 7 ECONOMIC REVIEW — AUTO LGD SUPPORT / EXTRAPOLATION DIAGNOSTIC
  15A_AUTO_LGD_SUPPORT_DIAGNOSTIC.SAS

  PURPOSE
  -------
  Investigate the unusually low Auto Stage-2 production LGD distribution
  BEFORE formally freezing Phase 7.

  This script:
    1) compares production collateral-coverage values with TRAIN support;
    2) quantifies near-zero LGD predictions by stage;
    3) builds a NON-PRODUCTION challenger diagnostic that caps
       collateral_coverage at the TRAIN 99th percentile before scoring the
       already-frozen Auto LGD model.

  IMPORTANT
  ---------
  - This file does NOT overwrite MODEL.RISK_MASTER.
  - This file does NOT refit the LGD model.
  - The clipped score is a diagnostic challenger only.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.lgd_model_abt);
%assert_ds(ds=MODEL.risk_master);

/*=============================================================================
  1. TRAIN SUPPORT FOR AUTO COLLATERAL COVERAGE
=============================================================================*/
proc means data=MODEL.lgd_model_abt(
              where=(product_type='Auto Loan' and role='TRAIN'))
    n mean min p1 p5 p10 p25 p50 p75 p90 p95 p99 max;
    var collateral_coverage realized_lgd_full;
    ods output Summary=OUT.phase7_auto_lgd_train_support;
run;

proc univariate data=MODEL.lgd_model_abt(
                   where=(product_type='Auto Loan' and role='TRAIN'))
                noprint;
    var collateral_coverage;
    output out=work.auto_train_pct
        pctlpts=1 5 50 95 99
        pctlpre=cc_p;
run;

data _null_;
    set work.auto_train_pct;
    call symputx('CC_P1',cc_p1);
    call symputx('CC_P5',cc_p5);
    call symputx('CC_P50',cc_p50);
    call symputx('CC_P95',cc_p95);
    call symputx('CC_P99',cc_p99);
run;

proc sql noprint;
    select max(collateral_coverage)
      into :CC_MAX trimmed
    from MODEL.lgd_model_abt
    where product_type='Auto Loan'
      and role='TRAIN';
quit;

/*=============================================================================
  2. PRODUCTION SUPPORT / EXTREME-PREDICTION DIAGNOSTICS
=============================================================================*/
proc sql;
    create table OUT.phase7_auto_prod_support_diag as
    select
        stage,
        count(*) as accounts,

        mean(collateral_coverage)
            as avg_collateral_coverage format=8.3,

        median(collateral_coverage)
            as med_collateral_coverage format=8.3,

        max(collateral_coverage)
            as max_collateral_coverage format=8.3,

        mean(collateral_coverage>&CC_P95.)
            as pct_above_train_p95 format=percent9.2,

        mean(collateral_coverage>&CC_P99.)
            as pct_above_train_p99 format=percent9.2,

        mean(collateral_coverage>&CC_MAX.)
            as pct_above_train_max format=percent9.2,

        mean(pred_lgd_base)
            as avg_lgd format=percent10.3,

        median(pred_lgd_base)
            as med_lgd format=percent10.3,

        mean(pred_lgd_base<0.001)
            as pct_lgd_lt_0_1pct format=percent9.2,

        mean(pred_lgd_base<0.01)
            as pct_lgd_lt_1pct format=percent9.2,

        mean(pred_lgd_base<0.05)
            as pct_lgd_lt_5pct format=percent9.2

    from MODEL.risk_master
    where product_type='Auto Loan'
    group by stage
    order by stage;

    create table OUT.phase7_auto_stage2_support_detail as
    select
        count(*) as accounts,

        sum(collateral_coverage>&CC_P99.) as above_train_p99,
        sum(collateral_coverage>&CC_MAX.) as above_train_max,

        sum(pred_lgd_base<0.001) as lgd_lt_0_1pct,
        sum(pred_lgd_base<0.01) as lgd_lt_1pct,
        sum(pred_lgd_base<0.05) as lgd_lt_5pct,

        mean(collateral_coverage)
            as avg_collateral_coverage format=8.3,

        median(collateral_coverage)
            as med_collateral_coverage format=8.3,

        mean(pred_lgd_base)
            as avg_lgd format=percent10.3,

        median(pred_lgd_base)
            as med_lgd format=percent10.3

    from MODEL.risk_master
    where product_type='Auto Loan'
      and stage=2;
quit;

/*=============================================================================
  3. DIAGNOSTIC CHALLENGER:
     CAP COLLATERAL COVERAGE AT TRAIN P99, THEN SCORE THE SAME FROZEN MODEL
=============================================================================*/
data work.auto_prod_clip;
    set MODEL.risk_master;
    where product_type='Auto Loan';

    collateral_coverage_raw=collateral_coverage;
    collateral_coverage=min(collateral_coverage,&CC_P99.);

    cc_clipped=(collateral_coverage_raw>&CC_P99.);
run;

proc plm restore=MODEL.lgd_auto_store;
    score data=work.auto_prod_clip
          out=work.auto_prod_clip_scored
          predicted=pred_lgd_logit_clip;
run;

data work.auto_prod_clip_scored;
    set work.auto_prod_clip_scored;

    pred_lgd_clip_p99=
        1/(1+exp(-pred_lgd_logit_clip));

    pred_lgd_clip_p99=
        min(max(pred_lgd_clip_p99,0),1);
run;

proc sql;
    create table OUT.phase7_auto_clip_challenger as
    select
        stage,
        count(*) as accounts,
        sum(cc_clipped) as clipped_accounts,

        mean(pred_lgd_base)
            as avg_lgd_original format=percent10.3,

        mean(pred_lgd_clip_p99)
            as avg_lgd_clip_p99 format=percent10.3,

        median(pred_lgd_base)
            as med_lgd_original format=percent10.3,

        median(pred_lgd_clip_p99)
            as med_lgd_clip_p99 format=percent10.3,

        mean(pred_lgd_base<0.01)
            as pct_orig_lt_1pct format=percent9.2,

        mean(pred_lgd_clip_p99<0.01)
            as pct_clip_lt_1pct format=percent9.2

    from work.auto_prod_clip_scored
    group by stage
    order by stage;
quit;

/*=============================================================================
  4. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 7 Economic Review — Auto LGD TRAIN Support";
proc print data=OUT.phase7_auto_lgd_train_support noobs; run;

title "Phase 7 Economic Review — Auto Production Support by Stage";
proc print data=OUT.phase7_auto_prod_support_diag noobs; run;

title "Phase 7 Economic Review — Auto Stage-2 Support Detail";
proc print data=OUT.phase7_auto_stage2_support_detail noobs; run;

title "Phase 7 Economic Review — P99-Clipped Collateral Coverage Challenger";
proc print data=OUT.phase7_auto_clip_challenger noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: AUTO LGD SUPPORT DIAGNOSTIC COMPLETE.;
%put NOTE: TRAIN collateral coverage P99=&CC_P99.;
%put NOTE: TRAIN collateral coverage MAX=&CC_MAX.;
%put NOTE: No production table was overwritten.;
%put NOTE: ===============================================================;

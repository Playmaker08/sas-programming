/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 7A-2 — AUTO LGD PRODUCTION SUPPORT GUARDRAIL
  13B_APPLY_AUTO_LGD_P99_GUARDRAIL.SAS

  PURPOSE
  -------
  Apply a production scoring guardrail to the frozen Auto LGD model after
  Phase-7 economic validation identified material extrapolation in
  collateral_coverage.

  GOVERNANCE RATIONALE
  --------------------
  * The Auto LGD model was trained on default observations.
  * Production collateral_coverage materially exceeds TRAIN support.
  * The model coefficient is strongly negative, so extrapolation can force
    LGD predictions implausibly close to zero.
  * We therefore cap ONLY the MODEL INPUT collateral_coverage at the TRAIN
    99th percentile.  The actual/raw collateral coverage is retained.
  * The LGD model is NOT refit.
  * The cap is derived solely from TRAIN support, not from 2025 realized loss
    outcomes or ECL targets.

  LINEAGE
  -------
  MODEL.PROD_RISK_PREGR
      = immutable pre-guardrail backup of MODEL.PRODUCTION_RISK_PARAMS

  MODEL.PRODUCTION_RISK_PARAMS
      = final production parameter table after the support guardrail

  IMPORTANT
  ---------
  Re-run Phase 7B and Phase 7C after this file:
      14_build_lifetime_ecl_engine.sas
      15_validate_phase7_V3.sas
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.lgd_model_abt);
%assert_ds(ds=MODEL.production_risk_params);

/*=============================================================================
  1. PRESERVE THE ORIGINAL PRE-GUARDRAIL PRODUCTION PARAMETER TABLE
     This makes the script safe to rerun without losing the original scores.
=============================================================================*/
%macro preserve_pregr;
    %if not %sysfunc(exist(MODEL.prod_risk_pregr)) %then %do;
        data MODEL.prod_risk_pregr;
            set MODEL.production_risk_params;
        run;
        %put NOTE: Created immutable pre-guardrail backup MODEL.PROD_RISK_PREGR.;
    %end;
    %else %do;
        %put NOTE: MODEL.PROD_RISK_PREGR already exists; reusing original pre-guardrail backup.;
    %end;
%mend;

%preserve_pregr;

/*=============================================================================
  2. DERIVE TRAIN-ONLY COLLATERAL-COVERAGE SUPPORT BOUND
=============================================================================*/
proc univariate data=MODEL.lgd_model_abt(
                   where=(product_type='Auto Loan' and role='TRAIN'))
                noprint;
    var collateral_coverage;
    output out=work.auto_cc_train_pct
        pctlpts=99
        pctlpre=cc_p;
run;

data _null_;
    set work.auto_cc_train_pct;
    call symputx('AUTO_CC_P99',cc_p99);
run;

proc sql noprint;
    select max(collateral_coverage)
      into :AUTO_CC_TRAIN_MAX trimmed
    from MODEL.lgd_model_abt
    where product_type='Auto Loan'
      and role='TRAIN';
quit;

%put NOTE: AUTO LGD TRAIN collateral coverage P99=&AUTO_CC_P99.;
%put NOTE: AUTO LGD TRAIN collateral coverage MAX=&AUTO_CC_TRAIN_MAX.;

/*=============================================================================
  3. SCORE AUTO WITH THE FROZEN MODEL USING P99-CAPPED MODEL INPUT
=============================================================================*/
data work.auto_gr_input;
    set MODEL.prod_risk_pregr;
    where product_type='Auto Loan';

    length lgd_guardrail_method $48;

    collateral_coverage_raw=collateral_coverage;
    collateral_coverage_used=
        min(collateral_coverage_raw,&AUTO_CC_P99.);

    lgd_guardrail_flag=
        (collateral_coverage_raw>&AUTO_CC_P99.);

    lgd_guardrail_cap=&AUTO_CC_P99.;
    lgd_guardrail_method='TRAIN-P99 cap on collateral coverage';

    /*
      PROC PLM expects the original model variable name.
      Only the scoring input is capped.
    */
    collateral_coverage=collateral_coverage_used;
run;

proc plm restore=MODEL.lgd_auto_store;
    score data=work.auto_gr_input
          out=work.auto_gr_scored
          predicted=pred_lgd_logit_gr;
run;

data work.auto_gr_scored;
    set work.auto_gr_scored;

    pred_lgd_pre_guardrail=pred_lgd_base;

    pred_lgd_guarded=
        1/(1+exp(-pred_lgd_logit_gr));

    pred_lgd_guarded=
        min(max(pred_lgd_guarded,0),1);

    /*
      Replace the production LGD parameter with the guarded score,
      while restoring the RAW collateral coverage field for reporting.
    */
    pred_lgd_base=pred_lgd_guarded;
    collateral_coverage=collateral_coverage_raw;
run;

/*=============================================================================
  4. NON-AUTO PRODUCTS ARE UNCHANGED
=============================================================================*/
data work.nonauto_gr;
    set MODEL.prod_risk_pregr;
    where product_type ne 'Auto Loan';

    length lgd_guardrail_method $48;

    pred_lgd_pre_guardrail=pred_lgd_base;
    pred_lgd_guarded=pred_lgd_base;

    collateral_coverage_raw=collateral_coverage;
    collateral_coverage_used=collateral_coverage;

    lgd_guardrail_flag=0;
    lgd_guardrail_cap=.;
    lgd_guardrail_method='Not applicable';
run;

/*=============================================================================
  5. REBUILD FINAL PRODUCTION PARAMETER TABLE
=============================================================================*/
data MODEL.production_risk_params;
    set work.auto_gr_scored
        work.nonauto_gr;
run;

proc sort data=MODEL.production_risk_params;
    by account_id;
run;

/*=============================================================================
  6. HARD DQ
=============================================================================*/
proc sql noprint;
    select count(*) into :N_PRE trimmed
    from MODEL.prod_risk_pregr;

    select count(*) into :N_POST trimmed
    from MODEL.production_risk_params;

    select count(*) into :N_BAD trimmed
    from MODEL.production_risk_params
    where missing(pred_lgd_base)
       or pred_lgd_base<0
       or pred_lgd_base>1;

    select count(*) into :N_AUTO_OVER_USED trimmed
    from MODEL.production_risk_params
    where product_type='Auto Loan'
      and collateral_coverage_used>&AUTO_CC_P99.+1e-12;
quit;

%macro guardrail_gate;
    %if &N_PRE. ne &N_POST. %then %do;
        %put ERROR: Guardrail changed production row count.;
        %abort cancel;
    %end;

    %if &N_BAD.>0 %then %do;
        %put ERROR: Guardrail produced invalid LGD predictions: &N_BAD.;
        %abort cancel;
    %end;

    %if &N_AUTO_OVER_USED.>0 %then %do;
        %put ERROR: Auto model-input collateral coverage still exceeds TRAIN P99.;
        %abort cancel;
    %end;
%mend;

%guardrail_gate;

/*=============================================================================
  7. GOVERNANCE OUTPUTS
=============================================================================*/
proc sql;
    create table OUT.p7_auto_gr_summary as
    select
        stage,
        count(*) as accounts,
        sum(lgd_guardrail_flag) as guarded_accounts,
        mean(lgd_guardrail_flag) as guarded_share format=percent9.2,

        mean(pred_lgd_pre_guardrail)
            as avg_lgd_before format=percent10.3,

        mean(pred_lgd_base)
            as avg_lgd_after format=percent10.3,

        median(pred_lgd_pre_guardrail)
            as med_lgd_before format=percent10.3,

        median(pred_lgd_base)
            as med_lgd_after format=percent10.3,

        mean(pred_lgd_pre_guardrail<0.01)
            as pct_before_lt1 format=percent9.2,

        mean(pred_lgd_base<0.01)
            as pct_after_lt1 format=percent9.2

    from MODEL.production_risk_params
    where product_type='Auto Loan'
    group by stage
    order by stage;

    create table OUT.p7_auto_gr_policy as
    select
        &AUTO_CC_P99. as train_cc_p99 format=8.4,
        &AUTO_CC_TRAIN_MAX. as train_cc_max format=8.4,
        sum(product_type='Auto Loan') as auto_accounts,
        sum(product_type='Auto Loan' and lgd_guardrail_flag=1)
            as guarded_auto_accounts,
        mean(case when product_type='Auto Loan'
                  then lgd_guardrail_flag else . end)
            as guarded_auto_share format=percent9.2
    from MODEL.production_risk_params;
quit;

ods noproctitle;

title "Phase 7A-2 — Auto LGD P99 Guardrail Policy";
proc print data=OUT.p7_auto_gr_policy noobs; run;

title "Phase 7A-2 — Auto LGD Before vs After Guardrail";
proc print data=OUT.p7_auto_gr_summary noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: AUTO LGD PRODUCTION SUPPORT GUARDRAIL COMPLETE.;
%put NOTE: MODEL.PRODUCTION_RISK_PARAMS now contains guarded Auto LGD scores.;
%put NOTE: Original pre-guardrail scores preserved in MODEL.PROD_RISK_PREGR.;
%put NOTE: Re-run Phase 7B and Phase 7C next.;
%put NOTE: ===============================================================;

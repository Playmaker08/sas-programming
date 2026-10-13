/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 8B — POWER BI / ANALYTICS EXPORT LAYER
  17_EXPORT_POWERBI_MART.SAS

  PURPOSE
  -------
  Export clean CSV tables for Power BI and Python challenger analysis.
  No model output is changed.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=OUT.p8_fact_account_risk);
%assert_ds(ds=OUT.p8_stage_kpi);
%assert_ds(ds=OUT.p8_product_stage_kpi);
%assert_ds(ds=OUT.p8_scenario_sensitivity);
%assert_ds(ds=OUT.p8_sicr_monitor);
%assert_ds(ds=OUT.p8_score_migration);
%assert_ds(ds=OUT.p8_auto_guardrail_monitor);
%assert_ds(ds=OUT.p8_top25_ecl_accounts);
%assert_ds(ds=MODEL.macro_scenarios_monthly);

%let OUTPATH=%sysfunc(pathname(OUT));

/*=============================================================================
  1. ACCOUNT FACT — SELECT ONLY REPORTING / ANALYTICS FIELDS
=============================================================================*/
data OUT.p8_powerbi_account_fact;
    set OUT.p8_fact_account_risk;

    keep
        account_id customer_id product_type
        report_date origination_date
        stage stage_label stage_reason
        current_score_tier orig_score_tier
        current_score origination_score score_drop
        dpd
        pd_current_cal pd_orig_cal pd_ratio_raw
        pred_lgd_base
        gross_exposure
        ead_h3 ead_h6 ead_h12
        ecl_base ecl_upside ecl_downside
        weighted_ecl allowance_rate
        stress_delta_ecl
        low_risk_diag
        lgd_guardrail_flag
        collateral_coverage_raw
        collateral_coverage_used
        sicr_bucket pd_band ecl_band;
run;

/*=============================================================================
  2. EXPORT CSV TABLES
=============================================================================*/
%macro export_csv(ds=, file=);
    proc export data=&ds.
        outfile="&OUTPATH./&file."
        dbms=csv
        replace;
    run;
%mend;

%export_csv(ds=OUT.p8_powerbi_account_fact,
            file=p8_powerbi_account_fact.csv);

%export_csv(ds=OUT.p8_stage_kpi,
            file=p8_stage_kpi.csv);

%export_csv(ds=OUT.p8_product_stage_kpi,
            file=p8_product_stage_kpi.csv);

%export_csv(ds=OUT.p8_scenario_sensitivity,
            file=p8_scenario_sensitivity.csv);

%export_csv(ds=OUT.p8_sicr_monitor,
            file=p8_sicr_monitor.csv);

%export_csv(ds=OUT.p8_score_migration,
            file=p8_score_migration.csv);

%export_csv(ds=OUT.p8_auto_guardrail_monitor,
            file=p8_auto_guardrail_monitor.csv);

%export_csv(ds=OUT.p8_top25_ecl_accounts,
            file=p8_top25_ecl_accounts.csv);

%export_csv(ds=MODEL.macro_scenarios_monthly,
            file=p8_macro_scenarios_monthly.csv);

/*=============================================================================
  3. EXPORT MANIFEST
=============================================================================*/
data OUT.p8_export_manifest;
    length file_name $48 purpose $100;

    file_name='p8_powerbi_account_fact.csv';
    purpose='Account-level Power BI / Python fact table';
    output;

    file_name='p8_stage_kpi.csv';
    purpose='Stage-level management KPIs';
    output;

    file_name='p8_product_stage_kpi.csv';
    purpose='Product x stage allowance analysis';
    output;

    file_name='p8_scenario_sensitivity.csv';
    purpose='Scenario sensitivity by product and stage';
    output;

    file_name='p8_sicr_monitor.csv';
    purpose='SICR / PD-deterioration monitoring';
    output;

    file_name='p8_score_migration.csv';
    purpose='Origination-to-current score-tier migration';
    output;

    file_name='p8_auto_guardrail_monitor.csv';
    purpose='Auto LGD production guardrail monitoring';
    output;

    file_name='p8_top25_ecl_accounts.csv';
    purpose='Top ECL concentration review';
    output;

    file_name='p8_macro_scenarios_monthly.csv';
    purpose='Forward-looking macro scenario paths';
    output;
run;

title "Phase 8B — Export Manifest";
proc print data=OUT.p8_export_manifest noobs; run;
title;

%put NOTE: ===============================================================;
%put NOTE: PHASE 8B POWER BI / PYTHON EXPORT COMPLETE.;
%put NOTE: Export directory=&OUTPATH.;
%put NOTE: ===============================================================;

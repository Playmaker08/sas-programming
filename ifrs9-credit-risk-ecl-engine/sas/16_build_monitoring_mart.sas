/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 8A — MONITORING MART
  16_BUILD_MONITORING_MART.SAS

  PURPOSE
  -------
  Convert the frozen MODEL.RISK_MASTER into a management / model-risk
  monitoring layer without changing any model outputs.

  OUTPUT THEMES
  -------------
  1) Portfolio / stage / product KPIs
  2) Scenario sensitivity
  3) SICR / PD migration
  4) Auto-LGD guardrail monitoring
  5) Concentration / top-risk accounts
  6) Power-BI-ready account fact
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.risk_master);
%assert_ds(ds=MODEL.macro_scenarios_monthly);

/*=============================================================================
  1. ACCOUNT-LEVEL MONITORING FACT
=============================================================================*/
data OUT.p8_fact_account_risk;
    set MODEL.risk_master;

    length sicr_bucket $24
           pd_band $16
           ecl_band $20;

    /* Transparent monitoring buckets only; no impact on staging. */
    if stage=3 then sicr_bucket='Credit-impaired';
    else if pd_ratio_raw>=10 then sicr_bucket='PD ratio >=10x';
    else if pd_ratio_raw>=5 then sicr_bucket='PD ratio 5-10x';
    else if pd_ratio_raw>=2 then sicr_bucket='PD ratio 2-5x';
    else sicr_bucket='PD ratio <2x';

    if pd_current_cal<0.01 then pd_band='<1%';
    else if pd_current_cal<0.03 then pd_band='1%-3%';
    else if pd_current_cal<0.10 then pd_band='3%-10%';
    else if pd_current_cal<0.30 then pd_band='10%-30%';
    else pd_band='30%+';

    if weighted_ecl<100 then ecl_band='<$100';
    else if weighted_ecl<1000 then ecl_band='$100-$1k';
    else if weighted_ecl<10000 then ecl_band='$1k-$10k';
    else if weighted_ecl<50000 then ecl_band='$10k-$50k';
    else ecl_band='$50k+';

    if gross_exposure>0 then ecl_to_exposure=weighted_ecl/gross_exposure;
    else ecl_to_exposure=.;

    /* Preserve explicit production-guardrail monitoring. */
    if missing(lgd_guardrail_flag) then lgd_guardrail_flag=0;

    format
        gross_exposure weighted_ecl ecl_base ecl_upside ecl_downside
        stress_delta_ecl dollar16.2
        pd_current_cal pd_orig_cal pred_lgd_base allowance_rate
        ecl_to_exposure percent10.3;
run;

/*=============================================================================
  2. PORTFOLIO KPI
=============================================================================*/
proc sql;
    create table OUT.p8_portfolio_kpi as
    select
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,

        sum(ecl_base) as base_ecl format=dollar18.,
        sum(ecl_upside) as upside_ecl format=dollar18.,
        sum(ecl_downside) as downside_ecl format=dollar18.,

        (sum(ecl_downside)-sum(ecl_base))
            as downside_vs_base format=dollar18.,

        (sum(ecl_base)-sum(ecl_upside))
            as base_vs_upside format=dollar18.,

        mean(pd_current_cal)
            as avg_current_pd format=percent10.3,

        mean(pred_lgd_base)
            as avg_base_lgd format=percent10.3

    from OUT.p8_fact_account_risk;

    create table OUT.p8_stage_kpi as
    select
        stage,
        stage_label,
        count(*) as accounts,
        calculated accounts /
            (select count(*) from OUT.p8_fact_account_risk)
            as account_share format=percent9.2,

        sum(gross_exposure) as exposure format=dollar18.,
        calculated exposure /
            (select sum(gross_exposure) from OUT.p8_fact_account_risk)
            as exposure_share format=percent9.2,

        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        calculated weighted_ecl /
            (select sum(weighted_ecl) from OUT.p8_fact_account_risk)
            as ecl_share format=percent9.2,

        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,

        mean(pd_current_cal)
            as avg_current_pd format=percent10.3,

        mean(pd_orig_cal)
            as avg_orig_pd format=percent10.3,

        mean(pd_ratio_raw)
            as avg_pd_ratio format=8.2,

        median(pd_ratio_raw)
            as med_pd_ratio format=8.2,

        mean(pred_lgd_base)
            as avg_lgd format=percent10.3

    from OUT.p8_fact_account_risk
    group by stage, stage_label
    order by stage;

    create table OUT.p8_product_stage_kpi as
    select
        product_type,
        stage,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,
        mean(pd_current_cal) as avg_current_pd format=percent10.3,
        mean(pred_lgd_base) as avg_lgd format=percent10.3
    from OUT.p8_fact_account_risk
    group by product_type, stage
    order by product_type, stage;
quit;

/*=============================================================================
  3. SCENARIO SENSITIVITY
=============================================================================*/
proc sql;
    create table OUT.p8_scenario_sensitivity as
    select
        product_type,
        stage,
        count(*) as accounts,
        sum(ecl_upside) as upside_ecl format=dollar18.,
        sum(ecl_base) as base_ecl format=dollar18.,
        sum(ecl_downside) as downside_ecl format=dollar18.,
        sum(ecl_downside)/sum(ecl_base)
            as downside_to_base format=8.3,
        sum(ecl_upside)/sum(ecl_base)
            as upside_to_base format=8.3,
        sum(ecl_downside-ecl_base)
            as downside_delta format=dollar18.
    from OUT.p8_fact_account_risk
    group by product_type, stage
    order by product_type, stage;
quit;

/*=============================================================================
  4. SICR / PD MIGRATION MONITORING
=============================================================================*/
proc sql;
    create table OUT.p8_sicr_monitor as
    select
        stage,
        sicr_bucket,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        mean(pd_current_cal) as avg_current_pd format=percent10.3,
        mean(pd_orig_cal) as avg_orig_pd format=percent10.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2
    from OUT.p8_fact_account_risk
    group by stage, sicr_bucket
    order by stage, sicr_bucket;

    create table OUT.p8_score_migration as
    select
        orig_score_tier,
        current_score_tier,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        mean(score_drop) as avg_score_drop format=8.1,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2
    from OUT.p8_fact_account_risk
    group by orig_score_tier, current_score_tier
    order by orig_score_tier, current_score_tier;

    create table OUT.p8_stage2_lowrisk_monitor as
    select
        product_type,
        current_score_tier,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,
        mean(pd_current_cal) as avg_current_pd format=percent10.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2
    from OUT.p8_fact_account_risk
    where stage=2 and low_risk_diag=1
    group by product_type, current_score_tier
    order by product_type, current_score_tier;
quit;

/*=============================================================================
  5. AUTO LGD GUARDRAIL MONITORING
=============================================================================*/
proc sql;
    create table OUT.p8_auto_guardrail_monitor as
    select
        stage,
        count(*) as auto_accounts,
        sum(lgd_guardrail_flag=1) as guarded_accounts,
        mean(lgd_guardrail_flag=1)
            as guarded_share format=percent9.2,

        mean(collateral_coverage_raw)
            as avg_raw_collateral_coverage format=8.3,

        mean(collateral_coverage_used)
            as avg_used_collateral_coverage format=8.3,

        mean(pred_lgd_pre_guardrail)
            as avg_lgd_before format=percent10.3,

        mean(pred_lgd_base)
            as avg_lgd_after format=percent10.3,

        median(pred_lgd_pre_guardrail)
            as med_lgd_before format=percent10.3,

        median(pred_lgd_base)
            as med_lgd_after format=percent10.3

    from OUT.p8_fact_account_risk
    where product_type='Auto Loan'
    group by stage
    order by stage;
quit;

/*=============================================================================
  6. CONCENTRATION / TOP-RISK ACCOUNTS
=============================================================================*/
proc sort data=OUT.p8_fact_account_risk
          out=work.p8_by_ecl;
    by descending weighted_ecl;
run;

data OUT.p8_top25_ecl_accounts;
    set work.p8_by_ecl(obs=25);
    rank=_n_;
run;

proc sort data=OUT.p8_fact_account_risk
          out=work.p8_by_exposure;
    by descending gross_exposure;
run;

data OUT.p8_top25_exposure_accounts;
    set work.p8_by_exposure(obs=25);
    rank=_n_;
run;

/* Precision-safe concentration aggregation: avoid macro numeric conversion. */
proc sql;
    create table work.p8_total as
    select
        sum(weighted_ecl) as total_ecl,
        sum(gross_exposure) as total_exposure
    from OUT.p8_fact_account_risk;

    create table work.p8_top25_ecl_sum as
    select
        sum(weighted_ecl) as top25_ecl
    from OUT.p8_top25_ecl_accounts;

    create table work.p8_top25_exp_sum as
    select
        sum(gross_exposure) as top25_exposure
    from OUT.p8_top25_exposure_accounts;
quit;

data OUT.p8_concentration_kpi;
    merge work.p8_total
          work.p8_top25_ecl_sum
          work.p8_top25_exp_sum;

    top25_ecl_share=top25_ecl/total_ecl;
    top25_exposure_share=top25_exposure/total_exposure;

    format total_ecl top25_ecl total_exposure top25_exposure dollar18.2
           top25_ecl_share top25_exposure_share percent9.2;
run;

/*=============================================================================
  7. MANAGEMENT OUTPUT
=============================================================================*/
ods noproctitle;

title "Phase 8A — Portfolio KPI";
proc print data=OUT.p8_portfolio_kpi noobs; run;

title "Phase 8A — Stage KPI";
proc print data=OUT.p8_stage_kpi noobs; run;

title "Phase 8A — Product x Stage KPI";
proc print data=OUT.p8_product_stage_kpi noobs; run;

title "Phase 8A — Scenario Sensitivity";
proc print data=OUT.p8_scenario_sensitivity noobs; run;

title "Phase 8A — Auto LGD Guardrail Monitor";
proc print data=OUT.p8_auto_guardrail_monitor noobs; run;

title "Phase 8A — Concentration KPI";
proc print data=OUT.p8_concentration_kpi noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 8A MONITORING MART COMPLETE.;
%put NOTE: ===============================================================;

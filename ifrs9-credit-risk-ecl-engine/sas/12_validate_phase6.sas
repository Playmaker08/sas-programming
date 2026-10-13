/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 6C V2 — STAGING + SCENARIO VALIDATION GATE
  12_VALIDATE_PHASE6_V2.SAS

  WHY V2
  ------
  Phase 6B V2 governs scenario ordering using cumulative real-GDP LEVEL,
  not pointwise real-GDP GROWTH.  This validator must use the same rule.

  A downside recession can later show faster GDP growth during recovery while
  its cumulative GDP level remains below Base.  Therefore pointwise growth-rate
  ordering is not a valid all-month governance requirement.

  THIS FILE DOES NOT CHANGE STAGES OR SCENARIOS.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.ifrs9_stage_snapshot);
%assert_ds(ds=MODEL.macro_scenarios_monthly);
%assert_ds(ds=MODEL.macro_scenarios_annual);

/*=============================================================================
  1. STAGING RULE AUDIT
=============================================================================*/
proc sql;
    create table OUT.phase6_stage_dq as
    select
        count(*) as rows,
        count(distinct account_id) as accounts,

        sum(missing(pd_current_cal)) as missing_current_pd,
        sum(missing(pd_orig_raw)) as missing_orig_pd,
        sum(stage not in (1,2,3)) as invalid_stage,

        sum(stage=1 and
            (default_flag=1
             or dpd>=&DEFAULT_DPD.
             or dpd>=&SICR_DPD.
             or pd_ratio_raw>=&SICR_PD_MULTIPLE.))
            as stage1_rule_violations,

        sum(stage=2 and
            (default_flag=1 or dpd>=&DEFAULT_DPD.))
            as stage2_credit_impaired,

        sum(stage=2 and
            not (dpd>=&SICR_DPD.
                 or pd_ratio_raw>=&SICR_PD_MULTIPLE.))
            as stage2_without_trigger,

        sum(stage=3 and
            not (default_flag=1 or dpd>=&DEFAULT_DPD.))
            as stage3_without_trigger

    from MODEL.ifrs9_stage_snapshot;

    create table OUT.phase6_stage_exposure as
    select
        stage,
        stage_label,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(gross_exposure)
          / (select sum(gross_exposure)
             from MODEL.ifrs9_stage_snapshot)
          as exposure_share format=percent9.2,
        mean(pd_current_cal) as avg_current_pd format=percent9.3,
        mean(pd_orig_cal) as avg_orig_pd format=percent9.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2,
        median(pd_ratio_raw) as med_pd_ratio format=8.2,
        mean(score_drop) as avg_score_drop format=8.1
    from MODEL.ifrs9_stage_snapshot
    group by stage, stage_label
    order by stage;

    create table OUT.phase6_sicr_flags as
    select
        stage,
        sum(sicr_dpd_flag=1) as dpd_sicr_accounts,
        sum(sicr_rel_flag=1) as relpd_sicr_accounts,
        sum(sicr_dpd_flag=1 and sicr_rel_flag=1) as both_sicr_accounts,
        sum(low_risk_diag=1) as low_risk_diag_accounts,
        sum(qual_watch_flag=1) as qualitative_watch_accounts
    from MODEL.ifrs9_stage_snapshot
    group by stage
    order by stage;
quit;

/* Diagnostic subset: Stage-2 accounts that remain low-risk in absolute terms.
   This is NOT an automatic exemption; it is a governance-monitoring population. */
proc sql;
    create table OUT.phase6_stage2_lowrisk_diag as
    select
        product_type,
        current_score_tier,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        mean(pd_current_cal) as avg_current_pd format=percent9.3,
        mean(pd_orig_cal) as avg_orig_pd format=percent9.3,
        mean(pd_ratio_raw) as avg_pd_ratio format=8.2
    from MODEL.ifrs9_stage_snapshot
    where stage=2 and low_risk_diag=1
    group by product_type, current_score_tier
    order by product_type, current_score_tier;
quit;

/* PD-ratio distribution by stage. */
proc means data=MODEL.ifrs9_stage_snapshot
    n mean p10 p25 p50 p75 p90 p95 p99 max;
    class stage;
    var pd_ratio_raw pd_abs_change_raw score_drop pd_current_cal pd_orig_cal;
    ods output Summary=OUT.phase6_pd_migration_dist;
run;

/*=============================================================================
  2. SCENARIO AUDIT — V2 RULES
=============================================================================*/
proc sql;
    create table OUT.phase6_scenario_dq as
    select
        count(*) as rows,
        count(distinct month_index) as horizons,
        count(distinct scenario) as scenarios,
        sum(missing(unemployment_rate)
            or missing(fed_funds_rate)
            or missing(real_gdp_growth)
            or missing(gdp_level_index)
            or missing(stress_index)) as missing_macro_rows
    from MODEL.macro_scenarios_monthly;

    create table work.scen_check_v2 as
    select
        month_index,
        sum(scenario_weight) as total_weight,

        max(case when scenario='UPSIDE'
                 then unemployment_rate else . end) as up_u,
        max(case when scenario='BASE'
                 then unemployment_rate else . end) as base_u,
        max(case when scenario='DOWNSIDE'
                 then unemployment_rate else . end) as down_u,

        max(case when scenario='UPSIDE'
                 then gdp_level_index else . end) as up_gdp_level,
        max(case when scenario='BASE'
                 then gdp_level_index else . end) as base_gdp_level,
        max(case when scenario='DOWNSIDE'
                 then gdp_level_index else . end) as down_gdp_level,

        max(case when scenario='UPSIDE'
                 then stress_index else . end) as up_s,
        max(case when scenario='BASE'
                 then stress_index else . end) as base_s,
        max(case when scenario='DOWNSIDE'
                 then stress_index else . end) as down_s

    from MODEL.macro_scenarios_monthly
    group by month_index;

    create table OUT.phase6_scenario_rule_check as
    select
        month_index,
        total_weight,

        (abs(total_weight-1)>1e-8) as bad_weight,

        (not (down_u>=base_u and base_u>=up_u))
            as bad_unemp_order,

        /* Correct V2 governance rule: cumulative GDP level ordering. */
        (not (down_gdp_level<=base_gdp_level
              and base_gdp_level<=up_gdp_level))
            as bad_gdp_level_order,

        (not (down_s>=base_s and base_s>=up_s))
            as bad_stress_order

    from work.scen_check_v2
    order by month_index;
quit;

/*=============================================================================
  3. FINAL GOVERNANCE GATE
=============================================================================*/
proc sql noprint;
    select
        stage1_rule_violations,
        stage2_credit_impaired,
        stage2_without_trigger,
        stage3_without_trigger,
        missing_current_pd,
        missing_orig_pd,
        invalid_stage
    into
        :V1, :V2, :V3, :V4, :V5, :V6, :V7
    from OUT.phase6_stage_dq;

    select count(*) into :SCEN_FAIL trimmed
    from OUT.phase6_scenario_rule_check
    where bad_weight=1
       or bad_unemp_order=1
       or bad_gdp_level_order=1
       or bad_stress_order=1;
quit;

data OUT.phase6_governance_gate;
    length component $32 status $8 rule $120;

    component='Staging rule consistency';
    rule='No account may violate the deterministic Stage 1/2/3 hierarchy';
    if sum(&V1.,&V2.,&V3.,&V4.)=0 then status='PASS';
    else status='FAIL';
    output;

    component='Staging data completeness';
    rule='No missing current/origination PD and no invalid stage';
    if sum(&V5.,&V6.,&V7.)=0 then status='PASS';
    else status='FAIL';
    output;

    component='Scenario governance';
    rule='Weights sum to 1; unemployment, GDP level and stress ordering hold';
    if &SCEN_FAIL.=0 then status='PASS';
    else status='FAIL';
    output;
run;

proc sql;
    create table OUT.phase6_final_decision as
    select
        count(*) as components,
        sum(status='PASS') as passed,
        sum(status='FAIL') as failed,
        case
            when calculated failed=0 then 'PHASE 6 TECHNICALLY READY'
            else 'PHASE 6 NOT READY'
        end as technical_decision length=28
    from OUT.phase6_governance_gate;
quit;

/*=============================================================================
  4. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 6C V2 — Staging Rule DQ";
proc print data=OUT.phase6_stage_dq noobs; run;

title "Phase 6C V2 — Stage Exposure / PD Migration";
proc print data=OUT.phase6_stage_exposure noobs; run;

title "Phase 6C V2 — SICR Trigger Diagnostics";
proc print data=OUT.phase6_sicr_flags noobs; run;

title "Phase 6C V2 — Stage-2 Low-Risk Diagnostic Population";
proc print data=OUT.phase6_stage2_lowrisk_diag noobs; run;

title "Phase 6C V2 — Annual Scenario Review";
proc print data=MODEL.macro_scenarios_annual noobs;
    var scenario scenario_weight horizon_year forecast_date
        unemployment_rate fed_funds_rate real_gdp_growth
        gdp_level_index stress_index;
run;

title "Phase 6C V2 — Scenario Rule Check (Annual Points)";
proc print data=OUT.phase6_scenario_rule_check noobs;
    where mod(month_index,12)=0;
run;

title "Phase 6C V2 — Governance Gate";
proc print data=OUT.phase6_governance_gate noobs; run;

title "Phase 6C V2 — Technical Decision";
proc print data=OUT.phase6_final_decision noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 6 V2 VALIDATION COMPLETE.;
%put NOTE: GDP governance uses cumulative GDP LEVEL, consistent with 6B V2.;
%put NOTE: ===============================================================;

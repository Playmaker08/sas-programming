/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 7C V3 — ECL VALIDATION / GOVERNANCE GATE
  15_VALIDATE_PHASE7_V3.SAS

  WHY V2
  ------
  V1 used CURRENT DRAWN BALANCE as a hard upper bound for total ECL.
  That is not valid for revolving commitments because IFRS 9 EAD includes
  expected future drawings of undrawn credit lines.  It can therefore be
  economically valid for ECL to exceed today's drawn balance.

  V2:
    1) retains "ECL > current drawn" as a DIAGNOSTIC only;
    2) uses each account's maximum scenario EAD from the cashflow engine as
       the hard economic/numerical ECL upper bound;
    3) rebuilds the governance gate from one-row validation tables directly,
       avoiding fragile blank macro-variable behavior;
    4) adds Stage-2 lifetime-uplift and Auto Stage-2 LGD diagnostics.

  V3 additionally fixes the weighted-ECL identity SQL for SAS Studio and
  prevents a missing identity difference from ever being interpreted as PASS.

  THIS FILE DOES NOT CHANGE ANY MODEL, STAGE, SCENARIO OR ECL.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.production_risk_params);
%assert_ds(ds=MODEL.ecl_cashflow_engine);
%assert_ds(ds=MODEL.ecl_account_scenario);
%assert_ds(ds=MODEL.risk_master);

/*=============================================================================
  1. ACCOUNT-LEVEL ECONOMIC EAD UPPER BOUND
=============================================================================*/
proc sql;
    create table work.account_max_ead as
    select
        account_id,
        max(ead_scenario) as max_scenario_ead
    from MODEL.ecl_cashflow_engine
    group by account_id;

    create table work.risk_master_bound as
    select
        r.*,
        e.max_scenario_ead
    from MODEL.risk_master as r
    left join work.account_max_ead as e
      on r.account_id=e.account_id
    order by r.account_id;
quit;

/*=============================================================================
  2. CORE DATA QUALITY
=============================================================================*/
proc sql;
    create table OUT.phase7_core_dq_v2 as
    select
        count(*) as accounts,
        count(distinct account_id) as distinct_accounts,

        sum(missing(pd_current_cal)
            or missing(pd_orig_cal)) as missing_pd,

        sum(missing(pred_lgd_base)
            or pred_lgd_base<0
            or pred_lgd_base>1) as bad_lgd,

        sum(missing(weighted_ecl)
            or weighted_ecl<0) as bad_ecl,

        /*
          Diagnostic only:
          not a failure for revolving accounts because undrawn commitments
          are part of EAD.
        */
        sum(weighted_ecl>gross_exposure+0.01)
            as ecl_above_current_drawn_diag,

        /*
          True numerical/economic upper-bound test:
          Expected loss cannot exceed the maximum modeled scenario EAD when
          marginal PD sums to <=1, LGD<=1 and discount factor<=1.
        */
        sum(missing(max_scenario_ead)
            or weighted_ecl>max_scenario_ead+0.01)
            as ecl_above_max_scenario_ead

    from work.risk_master_bound;

    create table OUT.phase7_ecl_above_drawn_diag as
    select
        product_type,
        stage,
        count(*) as accounts,
        sum(gross_exposure) as current_drawn format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(max_scenario_ead) as max_scenario_ead format=dollar18.
    from work.risk_master_bound
    where weighted_ecl>gross_exposure+0.01
    group by product_type, stage
    order by product_type, stage;

    create table OUT.phase7_cashflow_dq_v2 as
    select
        count(*) as rows,
        sum(marginal_pd<0 or marginal_pd>1) as bad_marginal_pd,
        sum(cumulative_pd<0 or cumulative_pd>1) as bad_cumulative_pd,
        sum(lgd_scenario<0 or lgd_scenario>1) as bad_lgd,
        sum(ead_scenario<0) as bad_ead,
        sum(discount_factor<=0 or discount_factor>1+1e-12) as bad_discount,
        sum(ecl_contribution<0) as bad_ecl
    from MODEL.ecl_cashflow_engine;
quit;

/*=============================================================================
  3. BASE 12M PD RECONCILIATION
=============================================================================*/
proc sql;
    create table OUT.phase7_pd12_reconciliation_v2 as
    select
        count(*) as accounts,
        mean(abs(s.cumulative_pd-p.pd_current_cal))
            as mean_abs_diff format=12.10,
        max(abs(s.cumulative_pd-p.pd_current_cal))
            as max_abs_diff format=12.10
    from MODEL.ecl_cashflow_engine as s
    inner join MODEL.risk_master as p
      on s.account_id=p.account_id
    where s.scenario='BASE'
      and s.month_index=12
      and p.stage in (1,2)
      and p.ecl_horizon_months>=12;
quit;

/*=============================================================================
  4. ACCOUNT-LEVEL STAGE / SCENARIO RULES
=============================================================================*/
proc sql;
    create table OUT.phase7_account_rule_check_v2 as
    select
        account_id,
        product_type,
        stage,
        gross_exposure,
        weighted_ecl,
        weighted_ecl_12m,
        ecl_upside,
        ecl_base,
        ecl_downside,

        (ecl_downside+1e-8 < ecl_base
         or ecl_base+1e-8 < ecl_upside)
            as scenario_order_violation,

        (stage=1
         and abs(weighted_ecl-weighted_ecl_12m)>0.01)
            as stage1_horizon_violation,

        (stage=2
         and weighted_ecl+0.01<weighted_ecl_12m)
            as stage2_lifetime_violation,

        (stage=3
         and (weighted_ecl<=0
              or weighted_ecl>max(gross_exposure,0)+0.01))
            as stage3_loss_violation

    from MODEL.risk_master;

    create table OUT.phase7_rule_summary_v2 as
    select
        count(*) as accounts,
        sum(scenario_order_violation) as scenario_order_violations,
        sum(stage1_horizon_violation) as stage1_horizon_violations,
        sum(stage2_lifetime_violation) as stage2_lifetime_violations,
        sum(stage3_loss_violation) as stage3_loss_violations
    from OUT.phase7_account_rule_check_v2;
quit;

/*=============================================================================
  5. PORTFOLIO / STAGE / PRODUCT DIAGNOSTICS
=============================================================================*/
proc sql;
    create table OUT.phase7_validation_stage_v2 as
    select
        stage,
        stage_label,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl_12m) as weighted_12m_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,
        mean(pd_current_cal) as avg_current_pd format=percent10.3,
        mean(pred_lgd_base) as avg_base_lgd format=percent10.3,
        mean(base_lifetime_cum_pd)
            as avg_base_lifetime_pd format=percent10.3
    from MODEL.risk_master
    group by stage, stage_label
    order by stage;

    create table OUT.phase7_validation_product_v2 as
    select
        product_type,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,
        sum(ecl_downside)/sum(ecl_base)
            as downside_to_base format=8.3,
        sum(ecl_upside)/sum(ecl_base)
            as upside_to_base format=8.3
    from MODEL.risk_master
    group by product_type
    order by product_type;

    create table OUT.phase7_stage2_lifetime_uplift as
    select
        product_type,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl_12m) as ecl_12m format=dollar18.,
        sum(weighted_ecl) as ecl_lifetime format=dollar18.,
        sum(weighted_ecl)/sum(weighted_ecl_12m)
            as lifetime_to_12m format=8.3,
        (sum(weighted_ecl)-sum(weighted_ecl_12m))
            as lifetime_uplift format=dollar18.
    from MODEL.risk_master
    where stage=2
    group by product_type
    order by product_type;

    create table OUT.phase7_stage2_lowrisk_ecl_v2 as
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
    from MODEL.risk_master
    where stage=2 and low_risk_diag=1
    group by product_type, current_score_tier
    order by product_type, current_score_tier;
quit;

/* Auto Stage-2 LGD distribution: monitoring diagnostic only. */
proc means data=MODEL.risk_master(where=(product_type='Auto Loan' and stage=2))
    n mean min p1 p5 p10 p25 p50 p75 p90 p95 p99 max;
    var pred_lgd_base;
    ods output Summary=OUT.phase7_auto_stage2_lgd_diag;
run;

/*=============================================================================
  6. WEIGHTED ECL IDENTITY — V3 FIX

  SAS PROC SQL does not reliably accept the V2 scalar-subquery SELECT form
  used here in SAS Studio.  Compute the two scalar aggregates separately,
  then persist them in one deterministic one-row table.
=============================================================================*/
proc sql noprint;
    select sum(weighted_ecl)
      into :RM_WEIGHTED_ECL trimmed
    from MODEL.risk_master;

    select sum(scenario_weight*scenario_ecl)
      into :RECON_WEIGHTED_ECL trimmed
    from MODEL.ecl_account_scenario;
quit;

data OUT.phase7_weighted_identity_v3;
    risk_master_weighted_ecl=&RM_WEIGHTED_ECL.;
    reconstructed_weighted_ecl=&RECON_WEIGHTED_ECL.;

    difference=
        risk_master_weighted_ecl-reconstructed_weighted_ecl;

    format
        risk_master_weighted_ecl
        reconstructed_weighted_ecl dollar18.2
        difference dollar14.6;
run;

/*=============================================================================
  7. ROBUST GOVERNANCE GATE INPUT
=============================================================================*/
data work.phase7_gate_inputs;
    merge
        OUT.phase7_core_dq_v2(
            rename=(
                accounts=core_accounts
                distinct_accounts=core_distinct_accounts
                bad_lgd=core_bad_lgd
                bad_ecl=core_bad_ecl
            )
        )
        OUT.phase7_cashflow_dq_v2(
            rename=(
                rows=cashflow_rows
                bad_lgd=cashflow_bad_lgd
                bad_ecl=cashflow_bad_ecl
            )
        )
        OUT.phase7_pd12_reconciliation_v2(
            rename=(
                accounts=pd12_accounts
                mean_abs_diff=pd12_mean_abs_diff
                max_abs_diff=pd12_max_abs_diff
            )
        )
        OUT.phase7_rule_summary_v2(
            rename=(accounts=rule_accounts)
        )
        OUT.phase7_weighted_identity_v3;
run;

data OUT.phase7_governance_gate_v2;
    set work.phase7_gate_inputs;

    length component $40 status $8 rule $160;

    component='Core account DQ';
    rule='No missing PD/LGD/ECL and ECL <= maximum modeled scenario EAD';
    if sum(missing_pd,
           core_bad_lgd,
           core_bad_ecl,
           ecl_above_max_scenario_ead)=0
        then status='PASS';
    else status='FAIL';
    output;

    component='Monthly cashflow DQ';
    rule='PD/LGD/EAD/discount/ECL monthly values remain within valid numerical bounds';
    if sum(bad_marginal_pd,
           bad_cumulative_pd,
           cashflow_bad_lgd,
           bad_ead,
           bad_discount,
           cashflow_bad_ecl)=0
        then status='PASS';
    else status='FAIL';
    output;

    component='BASE 12m PD reconciliation';
    rule='BASE month-12 cumulative PD reproduces approved calibrated current 12m PD';
    if pd12_max_abs_diff<1e-8
        then status='PASS';
    else status='FAIL';
    output;

    component='Stage / scenario rules';
    rule='Downside>=Base>=Upside; Stage1=12m; Stage2 lifetime>=12m; Stage3 bounded';
    if sum(scenario_order_violations,
           stage1_horizon_violations,
           stage2_lifetime_violations,
           stage3_loss_violations)=0
        then status='PASS';
    else status='FAIL';
    output;

    component='Weighted ECL identity';
    rule='Risk-master weighted ECL equals scenario-probability-weighted reconstruction';
    if not missing(difference)
       and abs(difference)<0.01
        then status='PASS';
    else status='FAIL';
    output;

    keep component status rule;
run;

proc sql;
    create table OUT.phase7_final_decision_v2 as
    select
        count(*) as components,
        sum(status='PASS') as passed,
        sum(status='FAIL') as failed,
        case
            when calculated failed=0
                then 'PHASE 7 TECHNICALLY READY'
            else 'PHASE 7 NOT READY'
        end as technical_decision length=28
    from OUT.phase7_governance_gate_v2;
quit;

/*=============================================================================
  8. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 7C V2 — Core Account DQ";
proc print data=OUT.phase7_core_dq_v2 noobs; run;

title "Phase 7C V2 — ECL Above Current Drawn Diagnostic";
proc print data=OUT.phase7_ecl_above_drawn_diag noobs; run;

title "Phase 7C V2 — Monthly Cashflow DQ";
proc print data=OUT.phase7_cashflow_dq_v2 noobs; run;

title "Phase 7C V2 — BASE 12M PD Reconciliation";
proc print data=OUT.phase7_pd12_reconciliation_v2 noobs; run;

title "Phase 7C V2 — Stage ECL Validation";
proc print data=OUT.phase7_validation_stage_v2 noobs; run;

title "Phase 7C V2 — Product ECL Validation / Scenario Sensitivity";
proc print data=OUT.phase7_validation_product_v2 noobs; run;

title "Phase 7C V2 — Stage-2 Lifetime Uplift";
proc print data=OUT.phase7_stage2_lifetime_uplift noobs; run;

title "Phase 7C V2 — Stage-2 Low-Risk Diagnostic ECL";
proc print data=OUT.phase7_stage2_lowrisk_ecl_v2 noobs; run;

title "Phase 7C V2 — Auto Stage-2 LGD Distribution";
proc print data=OUT.phase7_auto_stage2_lgd_diag noobs; run;

title "Phase 7C V2 — Account Rule Summary";
proc print data=OUT.phase7_rule_summary_v2 noobs; run;

title "Phase 7C V3 — Weighted ECL Identity";
proc print data=OUT.phase7_weighted_identity_v3 noobs; run;

title "Phase 7C V2 — Governance Gate";
proc print data=OUT.phase7_governance_gate_v2 noobs; run;

title "Phase 7C V2 — Technical Decision";
proc print data=OUT.phase7_final_decision_v2 noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 7 V3 VALIDATION COMPLETE.;
%put NOTE: CURRENT DRAWN BALANCE IS DIAGNOSTIC, NOT A HARD ECL UPPER BOUND.;
%put NOTE: HARD BOUND = MAX MODELED SCENARIO EAD PER ACCOUNT.;
%put NOTE: ===============================================================;

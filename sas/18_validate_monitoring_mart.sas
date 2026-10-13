/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 8C V2 — MONITORING MART VALIDATION
  18_VALIDATE_MONITORING_MART_V2.SAS

  WHY V2
  ------
  Replaces SELECT-only scalar-subquery syntax with separate aggregate queries
  for SAS Studio compatibility.  Validation rules are unchanged.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.risk_master);
%assert_ds(ds=OUT.p8_fact_account_risk);
%assert_ds(ds=OUT.p8_portfolio_kpi);
%assert_ds(ds=OUT.p8_stage_kpi);
%assert_ds(ds=OUT.p8_product_stage_kpi);
%assert_ds(ds=OUT.p8_auto_guardrail_monitor);
%assert_ds(ds=OUT.p8_concentration_kpi);

/*=============================================================================
  1. SOURCE vs MART RECONCILIATION
=============================================================================*/
proc sql noprint;
    select count(*),
           count(distinct account_id),
           sum(gross_exposure),
           sum(weighted_ecl)
      into :SRC_ROWS trimmed,
           :SRC_ACCTS trimmed,
           :SRC_EXP trimmed,
           :SRC_ECL trimmed
    from MODEL.risk_master;

    select count(*),
           count(distinct account_id),
           sum(gross_exposure),
           sum(weighted_ecl)
      into :MART_ROWS trimmed,
           :MART_ACCTS trimmed,
           :MART_EXP trimmed,
           :MART_ECL trimmed
    from OUT.p8_fact_account_risk;
quit;

data OUT.p8_reconciliation;
    source_rows=&SRC_ROWS.;
    mart_rows=&MART_ROWS.;
    source_accounts=&SRC_ACCTS.;
    mart_accounts=&MART_ACCTS.;
    source_exposure=&SRC_EXP.;
    mart_exposure=&MART_EXP.;
    source_ecl=&SRC_ECL.;
    mart_ecl=&MART_ECL.;

    exposure_diff=mart_exposure-source_exposure;
    ecl_diff=mart_ecl-source_ecl;

    format source_exposure mart_exposure
           source_ecl mart_ecl dollar18.2
           exposure_diff ecl_diff dollar14.6;
run;

/*=============================================================================
  2. DQ / LOGIC CHECKS
=============================================================================*/
proc sql;
    create table OUT.p8_monitoring_dq as
    select
        count(*) as rows,
        count(distinct account_id) as accounts,

        sum(missing(account_id)) as missing_account_id,
        sum(missing(product_type)) as missing_product,
        sum(stage not in (1,2,3)) as invalid_stage,

        sum(missing(gross_exposure)
            or gross_exposure<0) as bad_exposure,

        sum(missing(weighted_ecl)
            or weighted_ecl<0) as bad_ecl,

        sum(missing(pd_current_cal)
            or pd_current_cal<0
            or pd_current_cal>1) as bad_pd,

        sum(missing(pred_lgd_base)
            or pred_lgd_base<0
            or pred_lgd_base>1) as bad_lgd,

        sum(product_type ne 'Auto Loan'
            and lgd_guardrail_flag=1)
            as nonauto_guardrail_flags

    from OUT.p8_fact_account_risk;

    create table OUT.p8_stage_recon as
    select
        sum(accounts) as accounts,
        sum(exposure) as exposure format=dollar18.2,
        sum(weighted_ecl) as weighted_ecl format=dollar18.2,
        sum(account_share) as account_share format=percent10.4,
        sum(exposure_share) as exposure_share format=percent10.4,
        sum(ecl_share) as ecl_share format=percent10.4
    from OUT.p8_stage_kpi;

    create table OUT.p8_guardrail_recon as
    select
        sum(auto_accounts) as auto_accounts,
        sum(guarded_accounts) as guarded_accounts
    from OUT.p8_auto_guardrail_monitor;
quit;

/*=============================================================================
  3. GOVERNANCE GATE
=============================================================================*/
data work.gate_recon;
    set OUT.p8_reconciliation;
    length component $36 status $8 rule $140;

    component='Source-to-mart reconciliation';
    rule='Rows/accounts/exposure/ECL reconcile exactly to frozen RISK_MASTER';

    if source_rows=mart_rows
       and source_accounts=mart_accounts
       and abs(exposure_diff)<0.01
       and abs(ecl_diff)<0.01
       then status='PASS';
    else status='FAIL';

    keep component status rule;
run;

data work.gate_dq;
    set OUT.p8_monitoring_dq;
    length component $36 status $8 rule $140;

    component='Monitoring data quality';
    rule='No missing IDs/products, invalid stages, bad exposure/ECL/PD/LGD, or non-Auto guardrail flags';

    if sum(missing_account_id,
           missing_product,
           invalid_stage,
           bad_exposure,
           bad_ecl,
           bad_pd,
           bad_lgd,
           nonauto_guardrail_flags)=0
       then status='PASS';
    else status='FAIL';

    keep component status rule;
run;

data work.gate_stage;
    set OUT.p8_stage_recon;
    length component $36 status $8 rule $140;

    component='Stage aggregation';
    rule='Stage account/exposure/ECL shares each sum to 100%';

    if abs(account_share-1)<1e-8
       and abs(exposure_share-1)<1e-8
       and abs(ecl_share-1)<1e-8
       then status='PASS';
    else status='FAIL';

    keep component status rule;
run;

data OUT.p8_governance_gate;
    set work.gate_recon
        work.gate_dq
        work.gate_stage;
run;

proc sql;
    create table OUT.p8_final_decision as
    select
        count(*) as components,
        sum(status='PASS') as passed,
        sum(status='FAIL') as failed,
        case when calculated failed=0
             then 'PHASE 8A REPORTING READY'
             else 'PHASE 8A NOT READY'
        end as technical_decision length=28
    from OUT.p8_governance_gate;
quit;

/*=============================================================================
  4. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 8C V2 — Source to Monitoring Mart Reconciliation";
proc print data=OUT.p8_reconciliation noobs; run;

title "Phase 8C V2 — Monitoring DQ";
proc print data=OUT.p8_monitoring_dq noobs; run;

title "Phase 8C V2 — Stage Reconciliation";
proc print data=OUT.p8_stage_recon noobs; run;

title "Phase 8C V2 — Governance Gate";
proc print data=OUT.p8_governance_gate noobs; run;

title "Phase 8C V2 — Technical Decision";
proc print data=OUT.p8_final_decision noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 8C V2 MONITORING VALIDATION COMPLETE.;
%put NOTE: ===============================================================;

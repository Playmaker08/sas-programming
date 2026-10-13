/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  03A_FIX_RECOVERY_CUTOFF_FLAG.SAS

  PURPOSE
  -------
  Repair the as-of recovery availability flag created in Phase 1.3.

  WHY THIS PATCH EXISTS
  ---------------------
  In the original Phase 1.3 DATA step, AVAILABLE_BY_CUTOFF was assigned after
  explicit OUTPUT statements.  SAS writes the observation at OUTPUT time, so
  the flag was missing in the written recovery-cash-flow rows.

  IMPORTANT
  ---------
  - This does NOT regenerate any random recovery cash flows.
  - REALIZED_LGD_FULL is unchanged.
  - MODEL.LGD_ABT_MATURE membership is unchanged.
  - EAD/CCF targets are unchanged.
  - This patch corrects PV_NET_RECOVERY_ASOF and OBSERVED_LGD_ASOF only.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=INT.recovery_cashflows);
%assert_ds(ds=INT.default_enriched);

/* Recalculate the flag AFTER the cash-flow table already exists. */
data INT.recovery_cashflows;
    set INT.recovery_cashflows;
    available_by_cutoff=(cashflow_date<=&SNAP_END.);
run;

/* Re-aggregate without changing full-horizon recovery economics. */
proc sql;
    create table work.recovery_agg_fix as
    select
        account_id,
        sum(gross_recovery) as total_gross_recovery,
        sum(recovery_cost) as total_recovery_cost,
        sum(net_recovery) as total_net_recovery,

        sum(
            net_recovery /
            ((1 + effective_interest_rate/12)**lag_months)
        ) as pv_net_recovery_full,

        sum(
            case when available_by_cutoff=1 then
                net_recovery /
                ((1 + effective_interest_rate/12)**lag_months)
            else 0 end
        ) as pv_net_recovery_asof,

        sum(net_recovery>0) as n_positive_cashflows,
        max(case when net_recovery>0 then lag_months else . end)
            as last_recovery_month
    from INT.recovery_cashflows
    group by account_id;
quit;

proc sql;
    create table MODEL.lgd_abt as
    select
        d.*,
        r.total_gross_recovery,
        r.total_recovery_cost,
        r.total_net_recovery,
        r.pv_net_recovery_full,
        r.pv_net_recovery_asof,
        r.n_positive_cashflows,
        r.last_recovery_month,

        case when d.balance_at_default>0 then
            r.total_gross_recovery/d.balance_at_default
        else . end as gross_recovery_rate,

        case when d.balance_at_default>0 then
            r.total_net_recovery/d.balance_at_default
        else . end as net_recovery_rate,

        case when d.balance_at_default>0 then
            max(0,min(1,
                (d.balance_at_default-r.pv_net_recovery_full)
                / d.balance_at_default
            ))
        else . end as realized_lgd_full,

        case when d.balance_at_default>0 then
            max(0,min(1,
                (d.balance_at_default-r.pv_net_recovery_asof)
                / d.balance_at_default
            ))
        else . end as observed_lgd_asof,

        (d.default_date <= intnx('month',&SNAP_END.,-18,'e'))
            as recovery_mature_flag

    from INT.default_enriched as d
    left join work.recovery_agg_fix as r
        on d.account_id=r.account_id
    order by d.account_id;
quit;

data MODEL.lgd_abt_mature;
    set MODEL.lgd_abt;
    if recovery_mature_flag=1;
run;

/* DQ: availability flag must now be populated on every recovery row. */
proc sql noprint;
    select count(*) into :N_FLAG_MISS trimmed
    from INT.recovery_cashflows
    where missing(available_by_cutoff);
quit;

%if &N_FLAG_MISS. > 0 %then %do;
    %put ERROR: &N_FLAG_MISS recovery rows still have missing AVAILABLE_BY_CUTOFF.;
    %abort cancel;
%end;

/* Audit output. */
title "Phase 1.3A Cutoff-Flag Repair Audit";
proc freq data=INT.recovery_cashflows;
    tables available_by_cutoff / missing;
run;

title "Observed vs Full LGD by Recovery Maturity";
proc means data=MODEL.lgd_abt n mean median p25 p75;
    class product_type recovery_mature_flag;
    var observed_lgd_asof realized_lgd_full;
run;

title;

%put NOTE: ===============================================================;
%put NOTE: PHASE 1.3A PATCH COMPLETE.;
%put NOTE: Full LGD and EAD targets were not regenerated.;
%put NOTE: ===============================================================;

/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 7B — LIFETIME PD TERM STRUCTURE + SCENARIO-WEIGHTED ECL
  14_BUILD_LIFETIME_ECL_ENGINE.SAS

  PURPOSE
  -------
  Build account x scenario x month ECL cash flows from the approved:
      * PIT PD champion + VALID calibration,
      * LGD champion,
      * EAD/CCF champion,
      * Phase-6 staging policy,
      * Base/Upside/Downside macro scenarios.

  CORE FORMULA
  ------------
      ECL(i,s) = SUM_t [
          marginal_PD(i,s,t)
          * LGD(i,s,t)
          * EAD(i,s,t)
          * discount_factor(i,t)
      ]

  Stage 1: 12-month ECL (or shorter contractual life)
  Stage 2: lifetime ECL
  Stage 3: immediate default probability = 100%; scenario-sensitive recovery LGD

  PROJECT ASSUMPTIONS
  -------------------
  * Revolving-card behavioral life: 60 months.
  * Scenario overlay operates on governed stress_index, NOT raw PIT-PD macro
    coefficients.
  * Beyond month 12, Stage-2 base hazard mean-reverts toward origination hazard
    with a 36-month exponential mean-reversion parameter.
  * Term-loan EAD beyond 12m follows contractual amortization, anchored to the
    approved 12m EAD ratio.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%let CARD_BEHAV_LIFE=60;
%let MAX_LIFETIME_M=84;
%let HAZARD_REVERSION_M=36;

/* Governed scenario overlay elasticities. */
%let PD_BETA_AUTO=0.40;
%let PD_BETA_CARD=0.50;
%let PD_BETA_PERSONAL=0.45;

%let LGD_BETA_AUTO=0.45;
%let LGD_BETA_CARD=0.20;
%let LGD_BETA_PERSONAL=0.25;

%let EAD_BETA_CARD=0.10;
%let EAD_BETA_TERM=0.03;

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=MODEL.production_risk_params);
%assert_ds(ds=MODEL.macro_scenarios_monthly);

/*=============================================================================
  1. PERSIST ECL POLICY / OVERLAY ASSUMPTIONS
=============================================================================*/
data OUT.phase7_ecl_policy;
    length policy_item $36 policy_value $24 policy_note $120;

    policy_item='Card behavioral life';
    policy_value=cats("&CARD_BEHAV_LIFE.",' months');
    policy_note='Project behavioral-life assumption for Stage-2 revolving exposure';
    output;

    policy_item='Max lifetime horizon';
    policy_value=cats("&MAX_LIFETIME_M.",' months');
    policy_note='Limited by the approved macro-scenario horizon';
    output;

    policy_item='Hazard mean reversion';
    policy_value=cats("&HAZARD_REVERSION_M.",' months');
    policy_note='Stage-2 post-12m current-to-origination hazard convergence parameter';
    output;

    policy_item='PD stress beta Auto';
    policy_value="&PD_BETA_AUTO.";
    policy_note='Governed overlay on scenario stress index; not a causal model coefficient';
    output;

    policy_item='PD stress beta Card';
    policy_value="&PD_BETA_CARD.";
    policy_note='Governed overlay on scenario stress index; not a causal model coefficient';
    output;

    policy_item='PD stress beta Personal';
    policy_value="&PD_BETA_PERSONAL.";
    policy_note='Governed overlay on scenario stress index; not a causal model coefficient';
    output;

    policy_item='LGD stress beta Auto';
    policy_value="&LGD_BETA_AUTO.";
    policy_note='Logit-scale scenario overlay';
    output;

    policy_item='LGD stress beta Card';
    policy_value="&LGD_BETA_CARD.";
    policy_note='Logit-scale scenario overlay';
    output;

    policy_item='LGD stress beta Personal';
    policy_value="&LGD_BETA_PERSONAL.";
    policy_note='Logit-scale scenario overlay';
    output;

    policy_item='EAD stress beta Card';
    policy_value="&EAD_BETA_CARD.";
    policy_note='Multiplicative overlay applied to CCF path';
    output;

    policy_item='EAD stress beta Term';
    policy_value="&EAD_BETA_TERM.";
    policy_note='Small multiplicative overlay on conditional default exposure';
    output;
run;

/*=============================================================================
  2. ECL HORIZON BY STAGE / PRODUCT
=============================================================================*/
data work.ecl_accounts;
    set MODEL.production_risk_params;

    length ecl_horizon_basis $48;

    if stage=3 then do;
        ecl_horizon_months=1;
        ecl_horizon_basis='Immediate credit-impaired loss';
    end;

    else if stage=1 then do;
        if product_type='Credit Card' then
            ecl_horizon_months=12;
        else
            ecl_horizon_months=min(12,max(contract_rem_mths,1));

        ecl_horizon_basis='12-month ECL';
    end;

    else if stage=2 then do;
        if product_type='Credit Card' then do;
            ecl_horizon_months=&CARD_BEHAV_LIFE.;
            ecl_horizon_basis='Lifetime behavioral card horizon';
        end;
        else do;
            ecl_horizon_months=
                min(&MAX_LIFETIME_M.,max(contract_rem_mths,1));
            ecl_horizon_basis='Lifetime contractual horizon';
        end;
    end;

    ecl_horizon_months=min(ecl_horizon_months,&MAX_LIFETIME_M.);
run;

/* Stage-3 LGD uses year-1 scenario severity because recoveries occur after the
   reporting-date default, not solely in the first forecast month. */
proc sql;
    create table work.scenario_y1 as
    select
        scenario,
        stress_index as stress_y1
    from MODEL.macro_scenarios_monthly
    where month_index=12;

    create table work.ecl_grid as
    select
        a.*,
        s.scenario,
        s.scenario_weight,
        s.month_index,
        s.forecast_date,
        s.unemployment_rate as scen_unemployment,
        s.fed_funds_rate as scen_fed_funds,
        s.real_gdp_growth as scen_real_gdp_growth,
        s.gdp_level_index,
        s.stress_index,
        y.stress_y1

    from work.ecl_accounts as a
    inner join MODEL.macro_scenarios_monthly as s
      on s.month_index<=a.ecl_horizon_months

    left join work.scenario_y1 as y
      on s.scenario=y.scenario

    order by a.account_id, s.scenario, s.month_index;
quit;

/*=============================================================================
  3. MONTHLY PD / LGD / EAD / DISCOUNT PATHS
=============================================================================*/
data MODEL.ecl_cashflow_engine;
    set work.ecl_grid;
    by account_id scenario month_index;

    retain survival_start;

    /* Product-specific governed overlay strengths. */
    if product_type='Auto Loan' then do;
        pd_beta=&PD_BETA_AUTO.;
        lgd_beta=&LGD_BETA_AUTO.;
    end;
    else if product_type='Credit Card' then do;
        pd_beta=&PD_BETA_CARD.;
        lgd_beta=&LGD_BETA_CARD.;
    end;
    else do;
        pd_beta=&PD_BETA_PERSONAL.;
        lgd_beta=&LGD_BETA_PERSONAL.;
    end;

    /*----------------------------------------------------------------------
      PD TERM STRUCTURE
    ----------------------------------------------------------------------*/
    pd_cur=min(max(pd_current_cal,1e-8),1-1e-8);
    pd_org=min(max(pd_orig_cal,1e-8),1-1e-8);

    lambda_current=-log(1-pd_cur)/12;
    lambda_orig=-log(1-pd_org)/12;

    if first.scenario then survival_start=1;

    if stage=3 then do;
        /* Already credit-impaired at the reporting date. */
        monthly_cond_pd=1;
        marginal_pd=1;
        cumulative_pd=1;
        survival_end=0;
    end;

    else do;
        /*
          Months 1-12 exactly reconcile BASE cumulative PD to approved
          calibrated current 12m PD because BASE stress_index = 0.
        */
        if month_index<=12 then
            lambda_base=lambda_current;
        else
            lambda_base=
                lambda_orig
                + (lambda_current-lambda_orig)
                  * exp(-(month_index-12)/&HAZARD_REVERSION_M.);

        lambda_scen=
            max(0,lambda_base*exp(pd_beta*stress_index));

        monthly_cond_pd=
            1-exp(-lambda_scen);

        monthly_cond_pd=
            min(max(monthly_cond_pd,0),1-1e-8);

        marginal_pd=
            survival_start*monthly_cond_pd;

        survival_end=
            survival_start*(1-monthly_cond_pd);

        cumulative_pd=1-survival_end;

        survival_start=survival_end;
    end;

    /*----------------------------------------------------------------------
      LGD PATH — LOGIT-SCALE FORWARD-LOOKING OVERLAY
    ----------------------------------------------------------------------*/
    lgd0=min(max(pred_lgd_base,1e-4),1-1e-4);
    lgd0_logit=log(lgd0/(1-lgd0));

    if stage=3 then lgd_stress=stress_y1;
    else lgd_stress=stress_index;

    lgd_scenario=
        1/(1+exp(-(lgd0_logit + lgd_beta*lgd_stress)));

    lgd_scenario=min(max(lgd_scenario,0),1);

    /*----------------------------------------------------------------------
      EAD PATH
    ----------------------------------------------------------------------*/
    if stage=3 then do;
        ead_base=max(current_balance,0);
        ead_scenario=ead_base;
        ccf_base=.;
        ccf_scenario=.;
        ead_ratio_base=.;
    end;

    else if product_type='Credit Card' then do;
        /*
          Interpolate approved 3m / 6m / 12m CCF anchors.
          From reporting date to month 3, ramp from 0 to approved 3m CCF.
          Beyond month 12, hold the approved stable 12m CCF.
        */
        if month_index<=3 then
            ccf_base=(month_index/3)*ccf_h3;

        else if month_index<=6 then
            ccf_base=
                ccf_h3
                + ((month_index-3)/3)*(ccf_h6-ccf_h3);

        else if month_index<=12 then
            ccf_base=
                ccf_h6
                + ((month_index-6)/6)*(ccf_h12-ccf_h6);

        else
            ccf_base=ccf_h12;

        ccf_scenario=
            min(max(ccf_base*exp(&EAD_BETA_CARD.*stress_index),0),1.25);

        ead_base=max(0,current_balance + ccf_base*available_limit);
        ead_scenario=max(0,current_balance + ccf_scenario*available_limit);

        ead_ratio_base=.;
    end;

    else do;
        /*
          Term loans:
            0m ratio = 1
            interpolate approved 3m/6m/12m ratios
            beyond 12m, run contractual amortization from approved 12m anchor.
        */
        if month_index<=3 then
            ead_ratio_base=
                1 + (ratio_h3-1)*(month_index/3);

        else if month_index<=6 then
            ead_ratio_base=
                ratio_h3
                + (ratio_h6-ratio_h3)*((month_index-3)/3);

        else if month_index<=12 then
            ead_ratio_base=
                ratio_h6
                + (ratio_h12-ratio_h6)*((month_index-6)/6);

        if month_index<=12 then
            ead_base=max(0,current_balance*ead_ratio_base);

        else do;
            monthly_rate=max(effective_interest_rate,0)/12;

            if monthly_rate>0 then do;
                contract_bal_12=
                    max(0,
                        current_balance*(1+monthly_rate)**12
                        - scheduled_payment*
                          (((1+monthly_rate)**12-1)/monthly_rate)
                    );

                contract_bal_t=
                    max(0,
                        current_balance*(1+monthly_rate)**month_index
                        - scheduled_payment*
                          (((1+monthly_rate)**month_index-1)/monthly_rate)
                    );
            end;

            else do;
                contract_bal_12=max(0,current_balance-12*scheduled_payment);
                contract_bal_t=max(0,current_balance-month_index*scheduled_payment);
            end;

            if contract_bal_12>1e-8 then
                ead_base=
                    max(0,current_balance*ratio_h12
                          *(contract_bal_t/contract_bal_12));
            else ead_base=0;

            if current_balance>0 then
                ead_ratio_base=ead_base/current_balance;
            else ead_ratio_base=0;
        end;

        ead_scenario=
            max(0,ead_base*exp(&EAD_BETA_TERM.*stress_index));

        ccf_base=.;
        ccf_scenario=.;
    end;

    /*----------------------------------------------------------------------
      DISCOUNTING + ECL
    ----------------------------------------------------------------------*/
    if stage=3 then discount_factor=1;
    else
        discount_factor=
            (1+max(effective_interest_rate,0)/12)**(-month_index);

    ecl_contribution=
        marginal_pd
        * lgd_scenario
        * ead_scenario
        * discount_factor;

    weighted_ecl_contribution=
        scenario_weight*ecl_contribution;

    format
        pd_current_cal pd_orig_cal
        monthly_cond_pd marginal_pd cumulative_pd
        pred_lgd_base lgd_scenario
        scenario_weight percent10.5
        ead_base ead_scenario ecl_contribution
        weighted_ecl_contribution dollar16.2
        forecast_date date9.;
run;

/*=============================================================================
  4. ACCOUNT x SCENARIO ECL
=============================================================================*/
proc sql;
    create table MODEL.ecl_account_scenario as
    select
        account_id,
        scenario,
        max(scenario_weight) as scenario_weight,
        max(stage) as stage,
        max(product_type) as product_type length=16,

        sum(ecl_contribution) as scenario_ecl format=dollar16.2,

        sum(case when month_index<=12
                 then ecl_contribution
                 else 0 end)
            as scenario_ecl_12m format=dollar16.2,

        max(cumulative_pd) as lifetime_cum_pd format=percent10.3,

        max(case when month_index=12
                 then cumulative_pd
                 else . end)
            as cumulative_pd_12m format=percent10.3

    from MODEL.ecl_cashflow_engine
    group by account_id, scenario
    order by account_id, scenario;
quit;

/* Pivot scenarios to the final one-row-per-account Risk Master. */
proc sql;
    create table work.ecl_account_pivot as
    select
        account_id,

        max(case when scenario='BASE'
                 then scenario_ecl end) as ecl_base,

        max(case when scenario='UPSIDE'
                 then scenario_ecl end) as ecl_upside,

        max(case when scenario='DOWNSIDE'
                 then scenario_ecl end) as ecl_downside,

        sum(scenario_weight*scenario_ecl)
            as weighted_ecl,

        sum(scenario_weight*scenario_ecl_12m)
            as weighted_ecl_12m,

        max(case when scenario='BASE'
                 then lifetime_cum_pd end) as base_lifetime_cum_pd,

        max(case when scenario='BASE'
                 then cumulative_pd_12m end) as base_cum_pd_12m

    from MODEL.ecl_account_scenario
    group by account_id;
quit;

proc sort data=work.ecl_accounts; by account_id; run;
proc sort data=work.ecl_account_pivot; by account_id; run;

data MODEL.risk_master;
    merge work.ecl_accounts(in=a)
          work.ecl_account_pivot(in=b);
    by account_id;
    if a;

    stress_delta_ecl=ecl_downside-ecl_base;
    scenario_spread_ecl=ecl_downside-ecl_upside;

    if gross_exposure>0 then
        allowance_rate=weighted_ecl/gross_exposure;
    else allowance_rate=.;

    format
        ecl_base ecl_upside ecl_downside weighted_ecl weighted_ecl_12m
        stress_delta_ecl scenario_spread_ecl dollar16.2
        allowance_rate percent10.3
        base_lifetime_cum_pd base_cum_pd_12m percent10.3;
run;

/*=============================================================================
  5. MANAGEMENT OUTPUTS
=============================================================================*/
proc sql;
    create table OUT.phase7_ecl_by_stage as
    select
        stage,
        stage_label,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(ecl_base) as base_ecl format=dollar18.,
        sum(ecl_upside) as upside_ecl format=dollar18.,
        sum(ecl_downside) as downside_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,
        mean(base_lifetime_cum_pd)
            as avg_base_lifetime_pd format=percent10.3
    from MODEL.risk_master
    group by stage, stage_label
    order by stage;

    create table OUT.phase7_ecl_by_product_stage as
    select
        product_type,
        stage,
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3
    from MODEL.risk_master
    group by product_type, stage
    order by product_type, stage;

    create table OUT.phase7_scenario_portfolio as
    select
        scenario,
        max(scenario_weight) as scenario_weight format=percent8.2,
        sum(scenario_ecl) as portfolio_ecl format=dollar18.,
        sum(scenario_ecl_12m) as portfolio_12m_ecl format=dollar18.
    from MODEL.ecl_account_scenario
    group by scenario
    order by scenario;

    create table OUT.phase7_portfolio_summary as
    select
        count(*) as accounts,
        sum(gross_exposure) as exposure format=dollar18.,
        sum(weighted_ecl) as weighted_ecl format=dollar18.,
        sum(weighted_ecl_12m) as weighted_12m_ecl format=dollar18.,
        sum(weighted_ecl)/sum(gross_exposure)
            as allowance_rate format=percent10.3,
        sum(ecl_downside)-sum(ecl_base)
            as downside_vs_base_delta format=dollar18.,
        sum(ecl_base)-sum(ecl_upside)
            as base_vs_upside_delta format=dollar18.
    from MODEL.risk_master;
quit;

ods noproctitle;

title "Phase 7B — ECL Policy / Overlay Assumptions";
proc print data=OUT.phase7_ecl_policy noobs; run;

title "Phase 7B — Portfolio ECL by Stage";
proc print data=OUT.phase7_ecl_by_stage noobs; run;

title "Phase 7B — Portfolio ECL by Product x Stage";
proc print data=OUT.phase7_ecl_by_product_stage noobs; run;

title "Phase 7B — Scenario Portfolio ECL";
proc print data=OUT.phase7_scenario_portfolio noobs; run;

title "Phase 7B — Overall Portfolio Summary";
proc print data=OUT.phase7_portfolio_summary noobs; run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 7B LIFETIME ECL ENGINE COMPLETE.;
%put NOTE: MODEL.RISK_MASTER created.;
%put NOTE: DO NOT FREEZE PHASE 7 UNTIL 15_VALIDATE_PHASE7.SAS PASSES.;
%put NOTE: ===============================================================;

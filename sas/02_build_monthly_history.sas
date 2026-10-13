/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  02_BUILD_MONTHLY_HISTORY.SAS

  PURPOSE
  -------
  Build a stateful, longitudinal account-month history from the Phase 1.1
  portfolio foundation.

  KEY DESIGN PRINCIPLES
  ---------------------
  1) Account behavior is path-dependent; months are NOT independent draws.
  2) Monthly macro history comes from INT.MACRO_HISTORY (real FRED series).
  3) Delinquency evolves through Current -> 30 -> 60 -> 90+ with cures.
  4) First 90+ DPD observation is treated as synthetic default.
  5) Credit-card balances evolve through utilization; term loans amortize.
  6) Auto collateral depreciates through time.
  7) Hidden simulation drivers are kept in INT.MONTHLY_HISTORY_SIM only.
     MODEL.MONTHLY_SNAPSHOT excludes those hidden drivers to prevent leakage.

  OUTPUTS
  -------
  INT.MONTHLY_HISTORY_SIM   full simulation/audit table (contains hidden drivers)
  MODEL.MONTHLY_SNAPSHOT    model-facing observed monthly table
  INT.DEFAULT_EVENTS        one row per synthetic default
  OUT.PHASE12_ANNUAL_CALIBRATION
  OUT.PHASE12_DEC25_PORTFOLIO

  IMPORTANT
  ---------
  Transition parameters below are project calibration assumptions, NOT
  regulatory constants and NOT claims of exact industry transition matrices.
  They are designed to reproduce economically plausible portfolio behavior and
  are intended to be tuned against public aggregate benchmarks after review.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

/*=============================================================================
  0. PREREQUISITE CHECKS
=============================================================================*/

%macro assert_ds(ds=);
    %local dsid rc;
    %let dsid=%sysfunc(open(&ds.));
    %if &dsid.=0 %then %do;
        %put ERROR: Required data set &ds. does not exist or cannot be opened.;
        %abort cancel;
    %end;
    %let rc=%sysfunc(close(&dsid.));
%mend;

%assert_ds(ds=INT.account_master);
%assert_ds(ds=INT.macro_history);

/*=============================================================================
  1. BUILD ACCOUNT x MONTH GRID

  We simulate from origination, even when origination is before SNAP_START.
  Earlier months are used only to season the account.  Model-facing output
  begins at SNAP_START.
=============================================================================*/

proc sql;
    create table work.account_month_grid as
    select
        a.account_id,
        a.customer_id,
        a.product_type,
        a.vehicle_type,
        a.origination_date,
        a.maturity_date,
        a.original_balance,
        a.initial_balance,
        a.initial_utilization,
        a.credit_limit,
        a.apr,
        a.effective_interest_rate,
        a.scheduled_payment,
        a.collateral_value_orig,
        a.ltv_orig,
        a.origination_score,
        a.orig_score_tier,
        a.gross_annual_income,
        a.debt_to_income,
        a.employment_status,
        a.latent_risk,
        m.report_date,
        m.unemployment_rate,
        m.fed_funds_rate,
        m.real_gdp_growth
    from INT.account_master as a
    inner join INT.macro_history as m
        on m.report_date >= a.origination_date
       and m.report_date <= &SNAP_END.
    order by a.account_id, m.report_date;
quit;

/*=============================================================================
  2. STATEFUL MONTHLY SIMULATION
=============================================================================*/

data INT.monthly_history_sim
     INT.default_events(
        keep=
            account_id customer_id product_type default_date
            balance_at_default credit_limit_at_default undrawn_at_default
            collateral_value_at_default score_at_default
            unemployment_rate fed_funds_rate real_gdp_growth
            months_on_book default_reason
     );

    set work.account_month_grid;
    by account_id report_date;

    if _n_=1 then call streaminit(&SEED.+202);

    length employment_status_current $14
           previous_employment_status $14
           current_score_tier $14
           delinquency_bucket $8
           account_status $10
           default_reason $24;

    retain
        current_balance
        current_utilization
        current_score
        current_collateral_value
        dpd
        defaulted
        paid_off
        unemployment_spell
        employment_status_current
        previous_employment_status
        months_on_book;

    /* Variables used for audit/calibration only. */
    length simulation_version $12;
    simulation_version='PHASE1_2_V2';

    /*--------------------------------------------------------------------------
      INITIALIZE EACH ACCOUNT AT ORIGINATION
    --------------------------------------------------------------------------*/
    if first.account_id then do;
        current_balance          = initial_balance;
        current_score            = origination_score;
        current_utilization      = initial_utilization;
        current_collateral_value = collateral_value_orig;
        dpd                      = 0;
        defaulted                = 0;
        paid_off                 = 0;
        unemployment_spell       = 0;
        employment_status_current= employment_status;
        previous_employment_status=employment_status;
        months_on_book           = 0;

        payment_amount           = 0;
        interest_charge          = 0;
        job_loss_flag            = 0;
        cure_flag                = 0;
        roll_forward_flag        = 0;
        new_default              = 0;
        p_enter_30               = .;
        macro_stress_mult        = 1;
        account_status           = 'Active';
    end;
    else do;

        /* Once an account has defaulted or paid off, ignore future grid rows. */
        if defaulted=1 or paid_off=1 then delete;

        months_on_book + 1;
        job_loss_flag     = 0;
        cure_flag         = 0;
        roll_forward_flag = 0;
        new_default       = 0;
        payment_amount    = 0;
        interest_charge   = 0;

        /*----------------------------------------------------------------------
          CURRENT SCORE TIER AT START OF MONTH
        ----------------------------------------------------------------------*/
        if current_score<580 then current_score_tier='Deep subprime';
        else if current_score<620 then current_score_tier='Subprime';
        else if current_score<660 then current_score_tier='Near-prime';
        else if current_score<720 then current_score_tier='Prime';
        else if current_score<800 then current_score_tier='Prime plus';
        else current_score_tier='Superprime';

        /*----------------------------------------------------------------------
          EMPLOYMENT STATE

          This is a project behavioral assumption.  Monthly job-loss probability
          increases with the observed unemployment rate.  Temporary unemployment
          spells persist for multiple months instead of independently resetting.
        ----------------------------------------------------------------------*/
        if unemployment_spell>0 then do;
            unemployment_spell=unemployment_spell-1;
            employment_status_current='Unemployed';

            if unemployment_spell=0 then
                employment_status_current=previous_employment_status;
        end;
        else if employment_status_current in ('Employed','Self-employed') then do;
            p_job_loss = 0.0035
                         + 0.0016*max(0,unemployment_rate-4.0)
                         + 0.0010*(employment_status_current='Self-employed');
            p_job_loss=max(0.001,min(0.025,p_job_loss));

            if rand('uniform') < p_job_loss then do;
                previous_employment_status=employment_status_current;
                employment_status_current='Unemployed';
                unemployment_spell=ceil(2 + 7*rand('uniform'));
                job_loss_flag=1;
            end;
        end;
        else if employment_status_current='Unemployed' then do;
            /* Baseline-unemployed borrowers can re-enter employment. */
            p_reemployment = 0.18 - 0.020*max(0,unemployment_rate-4.0);
            p_reemployment=max(0.06,min(0.25,p_reemployment));
            if rand('uniform') < p_reemployment then
                employment_status_current='Employed';
        end;

        /*----------------------------------------------------------------------
          MACRO STRESS MULTIPLIER

          GDP is winsorized inside the risk function to avoid extraordinary
          quarterly annualized prints dominating a monthly credit transition.
        ----------------------------------------------------------------------*/
        gdp_for_risk=max(-5,min(5,real_gdp_growth));

        macro_stress_mult=exp(
              0.16*(unemployment_rate-4.0)
            + 0.025*max(0,fed_funds_rate-2.0)
            - 0.035*gdp_for_risk
        );

        macro_stress_mult=max(0.55,min(2.50,macro_stress_mult));

        /*----------------------------------------------------------------------
          PANDEMIC-ERA HOUSEHOLD SUPPORT / PAYMENT-RELIEF CALIBRATION

          Public consumer-credit data show unusually low delinquency/charge-off
          performance during 2020-2021 despite severe macro stress.  The synthetic
          portfolio therefore includes a temporary SUPPORT MULTIPLIER representing
          the combined effect of fiscal transfers, lender accommodations, payment
          relief, and unusually strong household liquidity.

          IMPORTANT: this is a portfolio-calibration assumption, NOT a claim that
          every borrower received a specific program or forbearance treatment.
          It is intentionally phased out by 2022.
        ----------------------------------------------------------------------*/
        policy_support_mult=1.00;

        if report_date >= '30APR2020'd and report_date <= '31DEC2020'd then
            policy_support_mult=0.40;
        else if report_date >= '31JAN2021'd and report_date <= '30JUN2021'd then
            policy_support_mult=0.50;
        else if report_date >= '31JUL2021'd and report_date <= '31DEC2021'd then
            policy_support_mult=0.65;
        else if report_date >= '31JAN2022'd and report_date <= '30JUN2022'd then
            policy_support_mult=0.90;

        /*----------------------------------------------------------------------
          BASE PROBABILITY OF ENTERING 30+ DPD FROM CURRENT

          Risk tiers are deliberately monotonic.  Product mix and macro/behavior
          multipliers create heterogeneous transition paths.
        ----------------------------------------------------------------------*/
        select (product_type);
            when ('Credit Card') do;
                select (current_score_tier);
                    when ('Superprime')    base_p30=0.0025;
                    when ('Prime plus')    base_p30=0.0050;
                    when ('Prime')         base_p30=0.0120;
                    when ('Near-prime')    base_p30=0.0280;
                    when ('Subprime')      base_p30=0.0550;
                    otherwise              base_p30=0.0900;
                end;
            end;

            when ('Auto Loan') do;
                select (current_score_tier);
                    when ('Superprime')    base_p30=0.0015;
                    when ('Prime plus')    base_p30=0.0030;
                    when ('Prime')         base_p30=0.0070;
                    when ('Near-prime')    base_p30=0.0160;
                    when ('Subprime')      base_p30=0.0350;
                    otherwise              base_p30=0.0600;
                end;
            end;

            otherwise do; /* Personal Loan */
                select (current_score_tier);
                    when ('Superprime')    base_p30=0.0020;
                    when ('Prime plus')    base_p30=0.0045;
                    when ('Prime')         base_p30=0.0100;
                    when ('Near-prime')    base_p30=0.0240;
                    when ('Subprime')      base_p30=0.0500;
                    otherwise              base_p30=0.0850;
                end;
            end;
        end;

        dti_mult = exp(1.10*(debt_to_income-0.27));
        hidden_risk_mult = exp(0.22*latent_risk);
        employment_mult = ifn(employment_status_current='Unemployed',2.20,1.00);

        if product_type='Credit Card' then
            util_mult=exp(1.55*max(0,current_utilization-0.30));
        else util_mult=1;

        p_enter_30 = base_p30
                     * macro_stress_mult
                     * dti_mult
                     * hidden_risk_mult
                     * employment_mult
                     * util_mult
                     * policy_support_mult;

        p_enter_30=max(0.0002,min(0.22,p_enter_30));

        /*----------------------------------------------------------------------
          DELINQUENCY STATE TRANSITIONS
        ----------------------------------------------------------------------*/
        prior_dpd=dpd;
        score_strength=max(0,min(1.25,(current_score-560)/240));

        if prior_dpd=0 then do;
            if rand('uniform') < p_enter_30 then do;
                dpd=30;
                roll_forward_flag=1;
            end;
            else dpd=0;
        end;

        else if prior_dpd=30 then do;
            p_cure30 = 0.28
                       + 0.30*score_strength
                       - 0.045*max(0,unemployment_rate-4.0)
                       - 0.12*(employment_status_current='Unemployed')
                       + 0.20*(1-policy_support_mult);
            p_cure30=max(0.08,min(0.80,p_cure30));

            if product_type='Credit Card' then base_roll60=0.24;
            else if product_type='Auto Loan' then base_roll60=0.20;
            else base_roll60=0.23;

            p_roll60=base_roll60
                     * macro_stress_mult**0.45
                     * exp(0.18*latent_risk)
                     * ifn(employment_status_current='Unemployed',1.35,1.00)
                     * policy_support_mult**0.50;
            p_roll60=max(0.07,min(0.55,p_roll60));

            /* Keep probabilities coherent. */
            if p_cure30+p_roll60>0.92 then
                p_roll60=0.92-p_cure30;

            u_transition=rand('uniform');
            if u_transition < p_cure30 then do;
                dpd=0;
                cure_flag=1;
            end;
            else if u_transition < p_cure30+p_roll60 then do;
                dpd=60;
                roll_forward_flag=1;
            end;
            else dpd=30;
        end;

        else if prior_dpd=60 then do;
            p_cure60 = 0.03 + 0.08*score_strength
                       + 0.08*(1-policy_support_mult);
            p_back30 = 0.10 + 0.16*score_strength
                       + 0.10*(1-policy_support_mult);

            if product_type='Credit Card' then base_to90=0.34;
            else if product_type='Auto Loan' then base_to90=0.29;
            else base_to90=0.36;

            p_to90=base_to90
                   * macro_stress_mult**0.50
                   * exp(0.18*latent_risk)
                   * ifn(employment_status_current='Unemployed',1.25,1.00)
                   * policy_support_mult**0.60;
            p_to90=max(0.10,min(0.68,p_to90));

            /* Make room for cure/backward moves. */
            if p_cure60+p_back30+p_to90>0.95 then
                p_to90=0.95-p_cure60-p_back30;

            u_transition=rand('uniform');

            if u_transition < p_cure60 then do;
                dpd=0;
                cure_flag=1;
            end;
            else if u_transition < p_cure60+p_back30 then do;
                dpd=30;
                cure_flag=1;
            end;
            else if u_transition < p_cure60+p_back30+p_to90 then do;
                dpd=90;
                roll_forward_flag=1;
            end;
            else dpd=60;
        end;

        /*----------------------------------------------------------------------
          PRODUCT-SPECIFIC BALANCE / UTILIZATION / PAYMENT EVOLUTION
        ----------------------------------------------------------------------*/
        prior_balance=current_balance;

        if product_type='Credit Card' then do;

            /* Seasoned utilization target varies strongly by current risk tier. */
            select (current_score_tier);
                when ('Superprime')    util_target=0.08;
                when ('Prime plus')    util_target=0.13;
                when ('Prime')         util_target=0.30;
                when ('Near-prime')    util_target=0.47;
                when ('Subprime')      util_target=0.65;
                otherwise              util_target=0.80;
            end;

            util_target = util_target
                          + 0.020*max(0,unemployment_rate-4.0)
                          + 0.080*(employment_status_current='Unemployed')
                          + 0.040*(dpd=30)
                          + 0.080*(dpd=60)
                          + 0.120*(dpd=90)
                          + 0.025*max(0,latent_risk);

            util_target=max(0.01,min(1.03,util_target));

            current_utilization =
                0.84*current_utilization
                + 0.16*util_target
                + rand('normal',0,0.025);

            current_utilization=max(0,min(1.05,current_utilization));
            current_balance=round(credit_limit*current_utilization,0.01);

            /* Payment amount is behavioral output, not the state driver. */
            pay_rate = 0.30
                       - 0.18*current_utilization
                       - 0.10*(current_score_tier in ('Subprime','Deep subprime'))
                       - 0.14*(employment_status_current='Unemployed')
                       - 0.10*(dpd=30)
                       - 0.18*(dpd=60)
                       - 0.25*(dpd=90)
                       + rand('normal',0,0.035);

            pay_rate=max(0,min(0.60,pay_rate));
            payment_amount=round(min(prior_balance,prior_balance*pay_rate),0.01);
            interest_charge=round(prior_balance*(apr/100)/12,0.01);
        end;

        else do; /* Auto Loan + Personal Loan */

            interest_charge=round(current_balance*effective_interest_rate/12,0.01);

            if dpd=0 then do;
                pay_factor=max(0.92,min(1.10,rand('normal',1.00,0.035)));
            end;
            else if dpd=30 then do;
                pay_factor=max(0.10,min(0.75,rand('normal',0.42,0.16)));
            end;
            else if dpd=60 then do;
                pay_factor=max(0,min(0.45,rand('normal',0.18,0.12)));
            end;
            else pay_factor=0;

            payment_amount=round(
                min(current_balance+interest_charge,
                    max(0,scheduled_payment*pay_factor)),
                0.01
            );

            current_balance=max(0,
                current_balance + interest_charge - payment_amount
            );
            current_balance=round(current_balance,0.01);

            /* Auto collateral depreciates with age and vehicle condition noise. */
            if product_type='Auto Loan' and current_collateral_value>0 then do;
                if vehicle_type='New' then do;
                    if months_on_book<=12 then dep_rate=0.0170;
                    else if months_on_book<=36 then dep_rate=0.0100;
                    else dep_rate=0.0070;
                end;
                else do;
                    if months_on_book<=12 then dep_rate=0.0110;
                    else if months_on_book<=36 then dep_rate=0.0080;
                    else dep_rate=0.0060;
                end;

                dep_rate=dep_rate+rand('normal',0,0.0015);
                dep_rate=max(0.003,min(0.025,dep_rate));

                current_collateral_value=max(500,
                    current_collateral_value*(1-dep_rate)
                );
                current_collateral_value=round(current_collateral_value,1);
            end;

            if current_balance<=50 and dpd<90 then do;
                current_balance=0;
                paid_off=1;
                account_status='PaidOff';
            end;
        end;

        /*----------------------------------------------------------------------
          SCORE MIGRATION

          Score has mean reversion but deteriorates with delinquency, high card
          utilization, unemployment, and weak macro conditions.
        ----------------------------------------------------------------------*/
        score_change=
              0.045*(origination_score-current_score)
            - 5*(dpd=30)
            - 12*(dpd=60)
            - 24*(dpd=90)
            - 5*(job_loss_flag=1)
            - 2.0*max(0,unemployment_rate-4.0)
            + 1.0*max(0,real_gdp_growth)/5
            + rand('normal',0,3.0);

        if product_type='Credit Card' then
            score_change=score_change
                         - 7*max(0,current_utilization-0.80)
                         + 1.5*(current_utilization<0.10);

        if cure_flag=1 then score_change=score_change+2.5;

        current_score=round(max(450,min(850,current_score+score_change)),1);

        /*----------------------------------------------------------------------
          DEFAULT = FIRST ENTRY INTO 90+ DPD
        ----------------------------------------------------------------------*/
        if dpd=90 and prior_dpd<90 then do;
            new_default=1;
            defaulted=1;
            account_status='Default';
            default_reason='First 90+ DPD';
        end;
        else if paid_off=0 then account_status='Active';
    end; /* not first.account_id */

    /*--------------------------------------------------------------------------
      INITIAL-MONTH DERIVED FIELDS + EVERY-MONTH OUTPUT FIELDS
    --------------------------------------------------------------------------*/
    if first.account_id then do;
        if current_score<580 then current_score_tier='Deep subprime';
        else if current_score<620 then current_score_tier='Subprime';
        else if current_score<660 then current_score_tier='Near-prime';
        else if current_score<720 then current_score_tier='Prime';
        else if current_score<800 then current_score_tier='Prime plus';
        else current_score_tier='Superprime';
    end;
    else do;
        if current_score<580 then current_score_tier='Deep subprime';
        else if current_score<620 then current_score_tier='Subprime';
        else if current_score<660 then current_score_tier='Near-prime';
        else if current_score<720 then current_score_tier='Prime';
        else if current_score<800 then current_score_tier='Prime plus';
        else current_score_tier='Superprime';
    end;

    if dpd=0 then delinquency_bucket='Current';
    else if dpd=30 then delinquency_bucket='30 DPD';
    else if dpd=60 then delinquency_bucket='60 DPD';
    else delinquency_bucket='90+ DPD';

    if product_type='Credit Card' then do;
        available_limit=max(0,credit_limit-current_balance);
        current_ltv=.;
        current_collateral_value=.;
    end;
    else do;
        current_utilization=.;
        available_limit=.;
        if product_type='Auto Loan' and current_collateral_value>0 then
            current_ltv=current_balance/current_collateral_value;
        else current_ltv=.;
    end;

    /* Output model window only; earlier months are used for seasoning. */
    if report_date >= &SNAP_START. then do;
        output INT.monthly_history_sim;
    end;

    if new_default=1 then do;
        default_date=report_date;
        balance_at_default=current_balance;
        credit_limit_at_default=credit_limit;
        if product_type='Credit Card' then
            undrawn_at_default=max(0,credit_limit-current_balance);
        else undrawn_at_default=.;
        collateral_value_at_default=current_collateral_value;
        score_at_default=current_score;
        output INT.default_events;
    end;

    format report_date origination_date maturity_date default_date date9.;
run;

/*=============================================================================
  3. CREATE MODEL-FACING MONTHLY SNAPSHOT (NO HIDDEN SIMULATION VARIABLES)
=============================================================================*/

data MODEL.monthly_snapshot;
    set INT.monthly_history_sim;

    /* Paid-off zero-exposure rows are not risk observations. */
    if account_status='PaidOff' then delete;

    default_flag=(account_status='Default');

    keep
        account_id customer_id report_date origination_date maturity_date
        product_type vehicle_type
        gross_annual_income debt_to_income
        employment_status_current
        current_score current_score_tier
        current_balance credit_limit available_limit current_utilization
        scheduled_payment payment_amount interest_charge
        current_collateral_value current_ltv
        dpd delinquency_bucket account_status default_flag
        months_on_book
        apr effective_interest_rate
        unemployment_rate fed_funds_rate real_gdp_growth;
run;

proc sort data=MODEL.monthly_snapshot;
    by account_id report_date;
run;

proc sort data=INT.default_events;
    by account_id default_date;
run;

/*=============================================================================
  4. HARD DATA-QUALITY CHECKS
=============================================================================*/

/* Duplicate account-month observations are not allowed. */
proc sql noprint;
    select count(*) into :N_DUP_MONTHS trimmed
    from (
        select account_id, report_date, count(*) as n
        from MODEL.monthly_snapshot
        group by account_id, report_date
        having calculated n>1
    );
quit;

%if &N_DUP_MONTHS. > 0 %then %do;
    %put ERROR: MODEL.MONTHLY_SNAPSHOT contains &N_DUP_MONTHS duplicate account-month keys.;
    %abort cancel;
%end;

/* One synthetic default event per account maximum. */
proc sql noprint;
    select count(*) into :N_DUP_DEFAULTS trimmed
    from (
        select account_id, count(*) as n
        from INT.default_events
        group by account_id
        having calculated n>1
    );
quit;

%if &N_DUP_DEFAULTS. > 0 %then %do;
    %put ERROR: INT.DEFAULT_EVENTS contains duplicate default events for &N_DUP_DEFAULTS accounts.;
    %abort cancel;
%end;

/* Range / missingness audit. */
data _null_;
    set MODEL.monthly_snapshot end=eof;
    retain n_bad 0;

    if current_balance<0 then n_bad+1;
    if dpd not in (0,30,60,90) then n_bad+1;
    if missing(current_score) then n_bad+1;
    if missing(unemployment_rate)
       or missing(fed_funds_rate)
       or missing(real_gdp_growth) then n_bad+1;
    if product_type='Credit Card' and
       (current_utilization<0 or current_utilization>1.05) then n_bad+1;
    if report_date<&SNAP_START. or report_date>&SNAP_END. then n_bad+1;

    if eof then do;
        put 'NOTE: Phase 1.2 hard-DQ violations = ' n_bad;
        if n_bad>0 then do;
            put 'ERROR: Phase 1.2 hard-DQ checks failed.';
            abort cancel;
        end;
    end;
run;

/*=============================================================================
  5. CALIBRATION / REALISM OUTPUTS
=============================================================================*/

/* Annual account-default incidence and balance-based default-incidence proxy.
   The balance proxy is NOT definitionally identical to the NY Fed flow metric. */
proc sql;
    create table OUT.phase12_annual_calibration as
    select
        year(report_date) as calendar_year,
        product_type,
        count(distinct account_id) as observed_accounts,
        sum(default_flag) as new_defaults,
        calculated new_defaults / calculated observed_accounts
            as account_default_rate format=percent8.2,
        sum(current_balance) / count(distinct report_date)
            as avg_monthly_exposure format=dollar18.,
        sum(case when default_flag=1 then current_balance else 0 end)
            as default_ead format=dollar18.,
        calculated default_ead / calculated avg_monthly_exposure
            as ann_def_bal_rate_proxy format=percent8.2
    from MODEL.monthly_snapshot
    group by calculated calendar_year, product_type
    order by calculated calendar_year, product_type;
quit;

/* December-2025 portfolio cut. */
proc sql;
    create table OUT.phase12_dec25_portfolio as
    select
        product_type,
        count(*) as accounts,
        sum(current_balance) as exposure format=dollar18.,
        mean(current_score) as avg_score format=8.1,
        mean(case when product_type='Credit Card' then current_utilization else . end)
            as avg_card_utilization format=percent8.2,
        mean(dpd>=30) as pct_30plus format=percent8.2,
        mean(dpd>=60) as pct_60plus format=percent8.2
    from MODEL.monthly_snapshot
    where report_date=&SNAP_END.
    group by product_type;
quit;

ods noproctitle;

title "Phase 1.2 Row Counts";
proc sql;
    select count(*) as monthly_rows,
           count(distinct account_id) as accounts_observed,
           min(report_date) as min_report_date format=date9.,
           max(report_date) as max_report_date format=date9.
    from MODEL.monthly_snapshot;

    select count(*) as default_events
    from INT.default_events;
quit;

title "Annual Default Calibration by Product";
proc print data=OUT.phase12_annual_calibration noobs;
run;

title "December 2025 Portfolio Snapshot";
proc print data=OUT.phase12_dec25_portfolio noobs;
run;

title "December 2025 Delinquency Distribution";
proc freq data=MODEL.monthly_snapshot;
    where report_date=&SNAP_END.;
    tables product_type*delinquency_bucket / nocol norow nopercent;
run;

title "Seasoned Credit Card Utilization by Current Score Tier - DEC2025";
proc means data=MODEL.monthly_snapshot(
        where=(report_date=&SNAP_END. and product_type='Credit Card')
    ) n mean p25 p50 p75 p90;
    class current_score_tier;
    var current_utilization current_balance credit_limit;
run;

title "Default Events by Product";
proc freq data=INT.default_events;
    tables product_type / missing;
run;

title "Default Exposure and Score";
proc means data=INT.default_events n mean p25 p50 p75 p90;
    class product_type;
    var balance_at_default score_at_default collateral_value_at_default;
run;

title;
ods proctitle;

/*=============================================================================
  PHASE 1.2 CHECKPOINT
  --------------------
  DO NOT proceed to recovery/LGD/EAD target generation until the outputs above
  have been reviewed for realism.
=============================================================================*/

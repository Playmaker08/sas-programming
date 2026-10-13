/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  01_BUILD_FOUNDATION.SAS

  PURPOSE
  -------
  Build the realistic portfolio foundation BEFORE any model is fitted:
      1) Load locally stored real U.S. macro history from FRED
      2) Create synthetic-but-calibrated borrower population
      3) Create product-level account originations
      4) Calibrate pricing / limits / terms to public market benchmarks
      5) Produce initial realism checks

  IMPORTANT
  ---------
  - The loan-level records are SYNTHETIC. They are not presented as bank data.
  - Public U.S. aggregate benchmarks are used only for calibration.
  - No protected-class variable (race, sex, religion, etc.) is generated.
  - Age is retained for portfolio description only and should be excluded from
    the champion PD model unless a separate legal/fair-lending review supports it.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

/*=============================================================================
  PART A — REAL MACRO HISTORY FROM LOCAL FRED CSV FILES

  Raw source files are manually downloaded from FRED and stored under data/raw.
  This avoids network restrictions in SAS OnDemand and improves reproducibility.
=============================================================================*/

%let FRED_DIR=&PROJECT_ROOT./data/raw;

/* Fail early if required raw files are missing. */
%macro assert_file(path=);
    filename _chk "&path.";
    %if not %sysfunc(fexist(_chk)) %then %do;
        %put ERROR: Required raw file not found: &path.;
        filename _chk clear;
        %abort cancel;
    %end;
    filename _chk clear;
%mend;

%assert_file(path=&FRED_DIR./UNRATE.csv);
%assert_file(path=&FRED_DIR./FEDFUNDS.csv);
%assert_file(path=&FRED_DIR./GDP_REAL_GROWTH.csv);

/* Import local FRED files. */
proc import datafile="&FRED_DIR./UNRATE.csv"
    out=work.fred_unrate dbms=csv replace;
    guessingrows=max;
    getnames=yes;
run;

proc import datafile="&FRED_DIR./FEDFUNDS.csv"
    out=work.fred_fedfunds dbms=csv replace;
    guessingrows=max;
    getnames=yes;
run;

proc import datafile="&FRED_DIR./GDP_REAL_GROWTH.csv"
    out=work.fred_gdp dbms=csv replace;
    guessingrows=max;
    getnames=yes;
run;

/*
  Normalize FRED series using the schema produced by SAS PROC IMPORT.

  In SAS OnDemand, the FRED CSV import shown in the project environment
  creates OBSERVATION_DATE as a SAS date and the series value as numeric.
  We therefore use the imported variables directly rather than VVALUEX.
*/
data work.unrate;
    set work.fred_unrate;
    obs_date=observation_date;
    unemployment_rate=UNRATE;

    if missing(obs_date) or missing(unemployment_rate) then delete;
    if obs_date < '01JAN2018'd or obs_date > '31DEC2025'd then delete;

    month_end=intnx('month',obs_date,0,'e');
    format obs_date month_end date9.;
    keep obs_date month_end unemployment_rate;
run;

data work.fedfunds;
    set work.fred_fedfunds;
    obs_date=observation_date;
    fed_funds_rate=FEDFUNDS;

    if missing(obs_date) or missing(fed_funds_rate) then delete;
    if obs_date < '01JAN2018'd or obs_date > '31DEC2025'd then delete;

    month_end=intnx('month',obs_date,0,'e');
    format obs_date month_end date9.;
    keep obs_date month_end fed_funds_rate;
run;

data work.gdp_q;
    set work.fred_gdp;
    obs_date=observation_date;
    real_gdp_growth=A191RL1Q225SBEA;

    if missing(obs_date) or missing(real_gdp_growth) then delete;
    if obs_date < '01JAN2018'd or obs_date > '31DEC2025'd then delete;

    qtr_start=intnx('qtr',obs_date,0,'b');
    format obs_date qtr_start date9.;
    keep obs_date qtr_start real_gdp_growth;
run;

/* Show actual raw coverage before any downstream modeling. */
proc sql;
    title "Raw FRED Coverage Check";
    select 'UNRATE' as series length=20,
           count(*) as n_obs,
           min(obs_date) as min_date format=date9.,
           max(obs_date) as max_date format=date9.
    from work.unrate
    union all
    select 'FEDFUNDS', count(*), min(obs_date), max(obs_date)
    from work.fedfunds
    union all
    select 'REAL_GDP_GROWTH', count(*), min(obs_date), max(obs_date)
    from work.gdp_q;
quit;
title;

/*
  The project origination engine starts in 2019 and the snapshot window runs
  through 2025.  Stop if the locally stored FRED history is only the default
  recent 5-year export rather than the required full history.
*/
%macro assert_macro_coverage(ds=, datevar=, required_start=, required_end=, label=);
    %local min_d max_d;
    proc sql noprint;
        select min(&datevar.), max(&datevar.)
        into :min_d trimmed, :max_d trimmed
        from &ds.;
    quit;

    %if %sysevalf(&min_d > &required_start) %then %do;
        %put ERROR: &label starts too late. Re-download the FRED CSV with an observation start of 01JAN2018.;
        %abort cancel;
    %end;

    %if %sysevalf(&max_d < &required_end) %then %do;
        %put ERROR: &label ends too early. Re-download the FRED CSV through the required 2025 period.;
        %abort cancel;
    %end;
%mend;

%assert_macro_coverage(
    ds=work.unrate,
    datevar=obs_date,
    required_start='01JAN2018'd,
    required_end='01DEC2025'd,
    label=UNRATE
);

%assert_macro_coverage(
    ds=work.fedfunds,
    datevar=obs_date,
    required_start='01JAN2018'd,
    required_end='01DEC2025'd,
    label=FEDFUNDS
);

/* Quarterly GDP only needs to cover the quarter containing DEC2025. */
%assert_macro_coverage(
    ds=work.gdp_q,
    datevar=obs_date,
    required_start='01JAN2018'd,
    required_end='01OCT2025'd,
    label=REAL_GDP_GROWTH
);

/* Check imports before downstream joins. */
%macro assert_nonempty(ds=);
    %local dsid nobs rc;
    %let dsid=%sysfunc(open(&ds.));
    %if &dsid.=0 %then %do;
        %put ERROR: Cannot open required data set &ds.;
        %abort cancel;
    %end;
    %let nobs=%sysfunc(attrn(&dsid.,NOBS));
    %let rc=%sysfunc(close(&dsid.));
    %if &nobs.=0 %then %do;
        %put ERROR: Required data set &ds. has zero observations.;
        %abort cancel;
    %end;
    %put NOTE: &ds. loaded successfully with &nobs. observations.;
%mend;

%assert_nonempty(ds=work.unrate);
%assert_nonempty(ds=work.fedfunds);
%assert_nonempty(ds=work.gdp_q);

/* Monthly calendar with quarterly GDP carried across the quarter. */
data work.calendar;
    do month_index=0 to intck('month','01JAN2018'd,'01DEC2025'd);
        month_end=intnx('month','01JAN2018'd,month_index,'e');
        qtr_start=intnx('qtr',month_end,0,'b');
        output;
    end;
    format month_end qtr_start date9.;
    drop month_index;
run;

proc sort data=work.calendar;  by month_end; run;
proc sort data=work.unrate;   by month_end; run;
proc sort data=work.fedfunds; by month_end; run;
proc sort data=work.gdp_q;    by qtr_start; run;

data INT.macro_history;
    merge work.calendar(in=a)
          work.unrate
          work.fedfunds;
    by month_end;
    if a;
run;

proc sort data=INT.macro_history; by qtr_start; run;

data INT.macro_history;
    merge INT.macro_history(in=a)
          work.gdp_q;
    by qtr_start;
    if a;
    report_date=month_end;
    format report_date month_end qtr_start date9.;
    drop month_end;
run;

proc sort data=INT.macro_history; by report_date; run;

/* Hard stop if macro history is incomplete. */
data _null_;
    set INT.macro_history end=eof;
    retain n_missing 0;
    if missing(unemployment_rate)
       or missing(fed_funds_rate)
       or missing(real_gdp_growth) then n_missing+1;
    if eof then do;
        put 'NOTE: Macro rows with any missing required series = ' n_missing;
        if n_missing>0 then do;
            put 'ERROR: Macro history contains missing required series. Stop before borrower generation.';
            abort cancel;
        end;
    end;
run;

/*=============================================================================
  PART B — BORROWER POPULATION
=============================================================================*/

data INT.customer_master;
    call streaminit(&SEED.);

    length customer_id $10
           employment_status $14
           region $12;

    do customer_n=1 to &N_CUSTOMERS.;

        customer_id=cats('C',put(customer_n,z7.));

        /* Adult retail-credit population; truncated bell-shaped age profile. */
        age=floor(max(21,min(78,rand('normal',44,13))));

        /*
          Synthetic gross household income.  Median is intentionally centered
          near the recent U.S. household-income level but with a wide right tail.
          This is a calibration assumption, not a reproduction of Census microdata.
        */
        gross_annual_income=exp(log(84000)+0.58*rand('normal'));
        gross_annual_income=max(18000,min(450000,gross_annual_income));
        gross_annual_income=round(gross_annual_income,100);

        /* Broad Census-region mix for a diversified U.S. retail portfolio. */
        u=rand('uniform');
        if u<0.17 then region='Northeast';
        else if u<0.38 then region='Midwest';
        else if u<0.76 then region='South';
        else region='West';

        /* Employment is generated for underwriting realism, not fair-lending use. */
        u=rand('uniform');
        if age>=65 then do;
            if u<0.58 then employment_status='Retired';
            else if u<0.83 then employment_status='Employed';
            else if u<0.94 then employment_status='Self-employed';
            else employment_status='Other';
        end;
        else if age<=25 then do;
            if u<0.68 then employment_status='Employed';
            else if u<0.78 then employment_status='Student';
            else if u<0.90 then employment_status='Self-employed';
            else if u<0.96 then employment_status='Unemployed';
            else employment_status='Other';
        end;
        else do;
            if u<0.80 then employment_status='Employed';
            else if u<0.92 then employment_status='Self-employed';
            else if u<0.965 then employment_status='Unemployed';
            else employment_status='Other';
        end;

        /* Hidden risk driver creates realistic correlation without becoming a model input. */
        latent_risk=rand('normal');

        /* Debt-service burden proxy, correlated with latent financial stress. */
        debt_to_income=max(0.05,min(0.68,
            0.27 + 0.075*latent_risk + rand('normal',0,0.075)));

        /* Credit score centered around a prime U.S. consumer population. */
        credit_score_base=
            720
            + 24*log(gross_annual_income/84000)
            - 55*latent_risk
            - 38*(employment_status='Unemployed')
            + rand('normal',0,45);

        credit_score_base=round(max(480,min(850,credit_score_base)),1);

        /* Credit-score segmentation consistent with CFPB report bands. */
        length score_tier $14;
        if credit_score_base<580 then score_tier='Deep subprime';
        else if credit_score_base<620 then score_tier='Subprime';
        else if credit_score_base<660 then score_tier='Near-prime';
        else if credit_score_base<720 then score_tier='Prime';
        else if credit_score_base<800 then score_tier='Prime plus';
        else score_tier='Superprime';

        /* Number of banking relationships in this synthetic institution. */
        u=rand('uniform');
        if u<0.68 then n_accounts=1;
        else if u<0.94 then n_accounts=2;
        else n_accounts=3;

        output;
    end;

    drop u customer_n;
    stop;
run;

/*=============================================================================
  PART C — ACCOUNT ORIGINATION
=============================================================================*/

data work.account_seed;
    set INT.customer_master;
    if _n_=1 then call streaminit(&SEED.+101);

    length account_id $12 product_type $16 vehicle_type $6;

    do acct_seq=1 to n_accounts;
        account_n+1;
        account_id=cats('A',put(account_n,z9.));

        /* Product mix is a project-bank design choice, not a national share. */
        u=rand('uniform');
        if u<0.45 then product_type='Credit Card';
        else if u<0.78 then product_type='Auto Loan';
        else product_type='Personal Loan';

        /* Originations from 2019-2025 create seasoned + new vintages in snapshots. */
        origination_date='01JAN2019'd + floor(rand('uniform')*('31DEC2025'd-'01JAN2019'd+1));
        origination_date=intnx('month',origination_date,0,'e');
        origination_month=origination_date;

        /* Account-level score differs modestly from customer baseline. */
        origination_score=round(max(470,min(850,
            credit_score_base + rand('normal',0,18))),1);

        length orig_score_tier $14;
        if origination_score<580 then orig_score_tier='Deep subprime';
        else if origination_score<620 then orig_score_tier='Subprime';
        else if origination_score<660 then orig_score_tier='Near-prime';
        else if origination_score<720 then orig_score_tier='Prime';
        else if origination_score<800 then orig_score_tier='Prime plus';
        else orig_score_tier='Superprime';

        credit_limit=.;
        original_balance=.;
        initial_balance=.;
        initial_utilization=.;
        term_months=.;
        vehicle_type='';
        ltv_orig=.;
        collateral_value_orig=.;

        if product_type='Credit Card' then do;
            /* Limit scales with income and score; capped to retail-card range. */
            credit_limit=exp(
                log(7000)
                + 0.42*log(gross_annual_income/84000)
                + 0.0032*(origination_score-700)
                + rand('normal',0,0.42)
            );
            credit_limit=round(max(500,min(40000,credit_limit)),100);

            /* Utilization differs materially by risk tier. */
            select (orig_score_tier);
                when ('Superprime')    initial_utilization=rand('beta',1.0,8.0);
                when ('Prime plus')    initial_utilization=rand('beta',1.2,6.5);
                when ('Prime')         initial_utilization=rand('beta',1.5,5.0);
                when ('Near-prime')    initial_utilization=rand('beta',1.8,4.0);
                when ('Subprime')      initial_utilization=rand('beta',2.2,3.0);
                otherwise              initial_utilization=rand('beta',2.8,2.3);
            end;
            initial_utilization=min(1.05,max(0,initial_utilization));
            initial_balance=round(credit_limit*initial_utilization,10);
            original_balance=initial_balance;
            term_months=.;
        end;

        else if product_type='Auto Loan' then do;
            vehicle_type=ifc(rand('uniform')<0.55,'New','Used');

            if vehicle_type='New' then do;
                original_balance=exp(log(40000)+0.30*rand('normal'));
                ltv_orig=max(0.70,min(1.25,rand('normal',0.97,0.10)));
            end;
            else do;
                original_balance=exp(log(24000)+0.38*rand('normal'));
                ltv_orig=max(0.72,min(1.35,rand('normal',1.06,0.13)));
            end;

            /* Income and score gently constrain financed amount. */
            original_balance=original_balance*
                max(0.72,min(1.30,(gross_annual_income/84000)**0.18));
            original_balance=round(max(6000,min(80000,original_balance)),100);
            initial_balance=original_balance;
            collateral_value_orig=round(original_balance/ltv_orig,100);

            u2=rand('uniform');
            if u2<0.08 then term_months=48;
            else if u2<0.38 then term_months=60;
            else if u2<0.88 then term_months=72;
            else term_months=84;
        end;

        else if product_type='Personal Loan' then do;
            original_balance=exp(
                log(12000)
                + 0.25*log(gross_annual_income/84000)
                + rand('normal',0,0.50)
            );
            original_balance=round(max(1500,min(50000,original_balance)),100);
            initial_balance=original_balance;

            u2=rand('uniform');
            if u2<0.20 then term_months=24;
            else if u2<0.58 then term_months=36;
            else if u2<0.86 then term_months=48;
            else term_months=60;
        end;

        output;
    end;

    format origination_date origination_month date9.;
    drop u u2 acct_seq account_n n_accounts;
run;

proc sort data=work.account_seed; by origination_month; run;
proc sort data=INT.macro_history out=work.macro_orig;
    by report_date;
run;

data work.macro_orig;
    set work.macro_orig;
    origination_month=report_date;
    keep origination_month unemployment_rate fed_funds_rate real_gdp_growth;
run;
proc sort data=work.macro_orig; by origination_month; run;

/* Merge macro environment at origination and set risk-based pricing. */
data INT.account_master;
    merge work.account_seed(in=a)
          work.macro_orig;
    by origination_month;
    if a;

    length pricing_tier $14;
    pricing_tier=orig_score_tier;

    /* Risk spread in percentage points. */
    select (pricing_tier);
        when ('Superprime')    risk_spread=-1.40;
        when ('Prime plus')    risk_spread=-0.80;
        when ('Prime')         risk_spread= 0.00;
        when ('Near-prime')    risk_spread= 2.50;
        when ('Subprime')      risk_spread= 5.50;
        otherwise              risk_spread= 8.50;
    end;

    /* Product APRs calibrated around Federal Reserve G.19 market levels. */
    if product_type='Credit Card' then
        apr=max(12,min(32,14.8 + 1.05*fed_funds_rate + risk_spread
                       + rand('normal',0,1.1)));

    else if product_type='Auto Loan' then
        apr=max(3,min(25,4.3 + 0.55*fed_funds_rate + risk_spread
                      + 0.8*(vehicle_type='Used') + rand('normal',0,0.65)));

    else if product_type='Personal Loan' then
        apr=max(6,min(32,7.6 + 0.70*fed_funds_rate + 1.15*risk_spread
                      + rand('normal',0,0.90)));

    apr=round(apr,0.01);
    effective_interest_rate=apr/100;

    /* Contractual scheduled payment for installment products. */
    if product_type ne 'Credit Card' then do;
        monthly_rate=effective_interest_rate/12;
        if monthly_rate>0 then scheduled_payment=
            original_balance * monthly_rate /
            (1-(1+monthly_rate)**(-term_months));
        else scheduled_payment=original_balance/term_months;
        scheduled_payment=round(scheduled_payment,0.01);
        maturity_date=intnx('month',origination_date,term_months,'e');
    end;
    else do;
        scheduled_payment=.;
        maturity_date=.;
    end;

    format origination_date origination_month maturity_date date9.;

    drop risk_spread monthly_rate;
run;

/*=============================================================================
  PART D — INITIAL REALISM / CALIBRATION CHECKS
=============================================================================*/

ods noproctitle;

title "Customer Credit Score and Income Calibration";
proc means data=INT.customer_master n mean std min p10 p25 p50 p75 p90 max;
    var credit_score_base gross_annual_income debt_to_income;
run;

title "Credit Score Tier Distribution";
proc freq data=INT.customer_master;
    tables score_tier / missing;
run;

title "Portfolio Product Mix";
proc freq data=INT.account_master;
    tables product_type / missing;
run;

title "Account Origination Economics by Product";
proc means data=INT.account_master n mean p25 p50 p75;
    class product_type;
    var original_balance credit_limit initial_utilization apr term_months;
run;

title "Auto Loan Terms";
proc means data=INT.account_master(where=(product_type='Auto Loan'))
           n mean p25 p50 p75;
    var original_balance apr term_months ltv_orig collateral_value_orig;
run;

title "Credit Card Utilization by Origination Score Tier";
proc means data=INT.account_master(where=(product_type='Credit Card'))
           n mean p25 p50 p75 p90;
    class orig_score_tier;
    var credit_limit initial_utilization initial_balance apr;
run;

title "Personal Loan Terms";
proc means data=INT.account_master(where=(product_type='Personal Loan'))
           n mean p25 p50 p75;
    var original_balance apr term_months scheduled_payment;
run;

title "Real Macro History Loaded from FRED";
proc print data=INT.macro_history(obs=24);
run;

title;
ods proctitle;

/*=============================================================================
  OUTPUTS CREATED BY THIS SCRIPT
  ------------------------------
  INT.MACRO_HISTORY
  INT.CUSTOMER_MASTER
  INT.ACCOUNT_MASTER

  NEXT SCRIPT
  -----------
  02_BUILD_MONTHLY_SNAPSHOTS.SAS
  will create state-dependent monthly balances, utilization, score migration,
  employment shocks, DPD transitions, cure/default events, recoveries, and the
  modeling ABTs.  We deliberately do NOT generate those before checking the
  origination distributions above.
=============================================================================*/

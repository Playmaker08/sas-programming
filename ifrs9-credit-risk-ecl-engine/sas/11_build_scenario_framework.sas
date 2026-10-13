/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  PHASE 6B V2 — FORWARD-LOOKING MACRO SCENARIO FRAMEWORK
  11_BUILD_SCENARIO_FRAMEWORK_V2.SAS

  WHY V2
  ------
  The original scenario paths were economically usable, but the governance test
  incorrectly required downside REAL GDP GROWTH to be below Base in every month.
  That is too strict: after a recession, a downside scenario can temporarily show
  faster GDP growth during recovery while the cumulative GDP LEVEL remains below
  Base.

  V2 therefore:
    1) keeps the original macro scenario assumptions;
    2) constructs a cumulative real-GDP level index;
    3) tests downside/base/upside ordering on GDP LEVEL rather than monthly growth;
    4) retains unemployment and composite stress-index ordering;
    5) wraps fail-fast checks in a macro so %ABORT is valid in SAS Studio.

  IMPORTANT
  ---------
  - Scenario assumptions remain PROJECT assumptions, not official forecasts.
  - The approved PIT-PD model's raw macro coefficients are NOT shocked directly.
=============================================================================*/

%include "%sysget(HOME)/sas/00_setup.sas";

%let REPORT_DATE=&SNAP_END.;
%let SCEN_MONTHS=84;

%macro assert_ds(ds=);
    %if not %sysfunc(exist(&ds.)) %then %do;
        %put ERROR: Required data set &ds. does not exist.;
        %abort cancel;
    %end;
%mend;

%assert_ds(ds=INT.macro_history);
%assert_ds(ds=MODEL.ifrs9_stage_snapshot);

/*=============================================================================
  1. REAL MACRO ANCHOR
=============================================================================*/
proc sql noprint;
    select max(report_date)
      into :MACRO_ANCHOR_DATE trimmed
    from INT.macro_history
    where report_date<=&REPORT_DATE.;
quit;

data _null_;
    set INT.macro_history;
    where report_date=&MACRO_ANCHOR_DATE.;

    call symputx('ANCHOR_U',unemployment_rate);
    call symputx('ANCHOR_F',fed_funds_rate);
    call symputx('ANCHOR_G',real_gdp_growth);
run;

data OUT.ifrs9_scenario_anchor;
    report_date=&REPORT_DATE.;
    macro_anchor_date=&MACRO_ANCHOR_DATE.;
    unemployment_rate=&ANCHOR_U.;
    fed_funds_rate=&ANCHOR_F.;
    real_gdp_growth=&ANCHOR_G.;
    format report_date macro_anchor_date date9.;
run;

/*=============================================================================
  2. BUILD MONTHLY BASE / UPSIDE / DOWNSIDE PATHS
=============================================================================*/
data MODEL.macro_scenarios_monthly;
    length scenario $8;

    array up_u[0:7] _temporary_
        (0 -0.35 -0.50 -0.40 -0.25 -0.15 -0.05 0);
    array up_f[0:7] _temporary_
        (0 -0.25 -0.40 -0.40 -0.30 -0.20 -0.10 0);
    array up_g[0:7] _temporary_
        (0  1.00  0.70  0.50  0.30  0.20  0.10 0);

    /*
      Downside GDP growth deliberately allows a later catch-up/rebound.
      The cumulative GDP LEVEL remains the appropriate governance object.
    */
    array dn_u[0:7] _temporary_
        (0  1.40  2.20  1.60  1.00  0.60  0.30  0.10);
    array dn_f[0:7] _temporary_
        (0 -0.25 -0.75 -0.75 -0.50 -0.25 -0.10  0);
    array dn_g[0:7] _temporary_
        (0 -3.00 -1.50 -0.50  0.20  0.20  0.10  0);

    do scenario='BASE','UPSIDE','DOWNSIDE';

        if scenario='BASE' then scenario_weight=&W_BASE.;
        else if scenario='UPSIDE' then scenario_weight=&W_UPSIDE.;
        else scenario_weight=&W_DOWNSIDE.;

        /*
          GDP level index begins at 100 at reporting date.
          Growth inputs are annual percentage rates; convert to an approximate
          monthly compounded growth factor.
        */
        gdp_level_index=100;

        do month_index=1 to &SCEN_MONTHS.;

            t=month_index/12;

            /* Base convergence from actual reporting-date macro state. */
            base_unemployment =
                &ANCHOR_U. + (4.2-&ANCHOR_U.)*(1-exp(-0.55*t));

            base_fed_funds =
                &ANCHOR_F. + (3.0-&ANCHOR_F.)*(1-exp(-0.45*t));

            base_real_gdp =
                2.0 + (&ANCHOR_G.-2.0)*exp(-0.60*t);

            /* Linear interpolation of annual scenario shocks. */
            lo=floor(t);
            hi=ceil(t);

            if lo<0 then lo=0;
            if hi>7 then hi=7;

            if lo=hi then frac=0;
            else frac=t-lo;

            if scenario='BASE' then do;
                shock_u=0;
                shock_f=0;
                shock_g=0;
            end;

            else if scenario='UPSIDE' then do;
                if lo=hi then do;
                    shock_u=up_u[lo];
                    shock_f=up_f[lo];
                    shock_g=up_g[lo];
                end;
                else do;
                    shock_u=up_u[lo] + frac*(up_u[hi]-up_u[lo]);
                    shock_f=up_f[lo] + frac*(up_f[hi]-up_f[lo]);
                    shock_g=up_g[lo] + frac*(up_g[hi]-up_g[lo]);
                end;
            end;

            else do; /* DOWNSIDE */
                if lo=hi then do;
                    shock_u=dn_u[lo];
                    shock_f=dn_f[lo];
                    shock_g=dn_g[lo];
                end;
                else do;
                    shock_u=dn_u[lo] + frac*(dn_u[hi]-dn_u[lo]);
                    shock_f=dn_f[lo] + frac*(dn_f[hi]-dn_f[lo]);
                    shock_g=dn_g[lo] + frac*(dn_g[hi]-dn_g[lo]);
                end;
            end;

            unemployment_rate=
                max(2.5,min(12,base_unemployment+shock_u));

            fed_funds_rate=
                max(0,min(10,base_fed_funds+shock_f));

            real_gdp_growth=
                max(-8,min(8,base_real_gdp+shock_g));

            /*
              Composite scenario severity:
                positive = adverse
                negative = favorable

              This remains a governed overlay index, not a causal coefficient.
            */
            stress_index =
                  0.60*((unemployment_rate-base_unemployment)/1.5)
                - 0.40*((real_gdp_growth-base_real_gdp)/2.0);

            /*
              Convert annual real-GDP growth rate to an approximate monthly
              growth factor and update the cumulative GDP level index.
            */
            monthly_gdp_factor=(1+real_gdp_growth/100)**(1/12);
            gdp_level_index=gdp_level_index*monthly_gdp_factor;

            forecast_date=intnx('month',&REPORT_DATE.,month_index,'e');

            output;
        end;
    end;

    format forecast_date date9.
           scenario_weight percent8.2;

    keep
        scenario scenario_weight month_index forecast_date
        unemployment_rate fed_funds_rate real_gdp_growth
        base_unemployment base_fed_funds base_real_gdp
        stress_index gdp_level_index;
run;

proc sort data=MODEL.macro_scenarios_monthly;
    by month_index scenario;
run;

/* Annual governance / management view. */
data MODEL.macro_scenarios_annual;
    set MODEL.macro_scenarios_monthly;
    if mod(month_index,12)=0;
    horizon_year=month_index/12;
run;

/*=============================================================================
  3. GOVERNANCE TABLES
=============================================================================*/
proc sql;
    create table OUT.ifrs9_scenario_weight_check as
    select
        month_index,
        sum(scenario_weight) as total_weight format=8.6
    from MODEL.macro_scenarios_monthly
    group by month_index;

    create table work.scenario_wide as
    select
        month_index,

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
                 then stress_index else . end) as up_stress,
        max(case when scenario='BASE'
                 then stress_index else . end) as base_stress,
        max(case when scenario='DOWNSIDE'
                 then stress_index else . end) as down_stress

    from MODEL.macro_scenarios_monthly
    group by month_index;

    create table OUT.ifrs9_scenario_order_check as
    select
        month_index,

        up_u, base_u, down_u,
        up_gdp_level, base_gdp_level, down_gdp_level,
        up_stress, base_stress, down_stress,

        (not (down_u>=base_u and base_u>=up_u))
            as unemp_violation,

        /*
          Correct economic test:
          downside GDP LEVEL <= base GDP LEVEL <= upside GDP LEVEL.
          We deliberately do NOT require the growth rate itself to obey this
          ordering every month during recovery.
        */
        (not (down_gdp_level<=base_gdp_level
              and base_gdp_level<=up_gdp_level))
            as gdp_level_violation,

        (not (down_stress>=base_stress
              and base_stress>=up_stress))
            as stress_violation

    from work.scenario_wide
    order by month_index;
quit;

proc sql noprint;
    select count(*) into :BAD_WEIGHT trimmed
    from OUT.ifrs9_scenario_weight_check
    where abs(total_weight-1)>1e-8;

    select count(*) into :BAD_ORDER trimmed
    from OUT.ifrs9_scenario_order_check
    where unemp_violation=1
       or gdp_level_violation=1
       or stress_violation=1;

    select count(*) into :BAD_SCEN trimmed
    from MODEL.macro_scenarios_monthly
    where missing(unemployment_rate)
       or missing(fed_funds_rate)
       or missing(real_gdp_growth)
       or missing(stress_index)
       or missing(gdp_level_index)
       or scenario_weight<=0;
quit;

/*=============================================================================
  4. FAIL-FAST GATE — INSIDE A MACRO SO %ABORT IS VALID
=============================================================================*/
%macro scenario_governance_gate;

    %if &BAD_WEIGHT.>0 %then %do;
        %put ERROR: Scenario weights fail the sum-to-one check.;
        %abort cancel;
    %end;

    %if &BAD_ORDER.>0 %then %do;
        %put ERROR: Scenario economic ordering failed in &BAD_ORDER months.;
        %abort cancel;
    %end;

    %if &BAD_SCEN.>0 %then %do;
        %put ERROR: Scenario table contains invalid/missing values.;
        %abort cancel;
    %end;

    %put NOTE: Scenario governance checks PASS.;
    %put NOTE: BAD_WEIGHT=&BAD_WEIGHT BAD_ORDER=&BAD_ORDER BAD_SCEN=&BAD_SCEN.;

%mend;

%scenario_governance_gate;

/*=============================================================================
  5. RESULTS
=============================================================================*/
ods noproctitle;

title "Phase 6B V2 — Reporting-Date Macro Anchor";
proc print data=OUT.ifrs9_scenario_anchor noobs; run;

title "Phase 6B V2 — Annual Forward-Looking Scenario Paths";
proc print data=MODEL.macro_scenarios_annual noobs;
    var scenario scenario_weight horizon_year forecast_date
        unemployment_rate fed_funds_rate real_gdp_growth
        gdp_level_index stress_index;
run;

title "Phase 6B V2 — Scenario Weight Check (First 12 Months)";
proc print data=OUT.ifrs9_scenario_weight_check(obs=12) noobs; run;

title "Phase 6B V2 — Scenario Economic Ordering Check (Annual Points)";
proc print data=OUT.ifrs9_scenario_order_check noobs;
    where mod(month_index,12)=0;
run;

title;
ods proctitle;

%put NOTE: ===============================================================;
%put NOTE: PHASE 6B V2 MACRO SCENARIO FRAMEWORK COMPLETE.;
%put NOTE: 84 monthly horizons x 3 scenarios created.;
%put NOTE: GDP governance uses cumulative GDP LEVEL, not pointwise growth.;
%put NOTE: ===============================================================;

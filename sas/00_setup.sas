/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE
  00_SETUP.SAS
  SAS-first portfolio project
=============================================================================*/

options nodate nonumber nocenter msglevel=i
        mprint mlogic symbolgen validvarname=any;
ods graphics on;

/*--------------------------------------------------------------------------
  EDIT ONLY THIS PATH BEFORE FIRST RUN
--------------------------------------------------------------------------*/
%let PROJECT_ROOT=%sysget(HOME);

/*--------------------------------------------------------------------------
  PROJECT SIZE / TIME WINDOW
--------------------------------------------------------------------------*/
%let N_CUSTOMERS=15000;
%let SNAP_START='31JAN2021'd;
%let SNAP_END  ='31DEC2025'd;
%let SEED=9172026;

/* Model-development cutoffs retained from the course architecture. */
%let TRAIN_END='31DEC2023'd;
%let VALID_END='30JUN2024'd;

/* IFRS 9 classroom/project staging parameters; NOT regulatory constants. */
%let SICR_PD_MULTIPLE=2.0;
%let SICR_DPD=30;
%let DEFAULT_DPD=90;

/* Scenario weights are project assumptions and will be governed later. */
%let W_BASE=0.60;
%let W_UPSIDE=0.20;
%let W_DOWNSIDE=0.20;

/*--------------------------------------------------------------------------
  LIBRARIES
  Create these folders under PROJECT_ROOT before running if your SAS
  environment does not allow automatic directory creation.
--------------------------------------------------------------------------*/
libname RAW   "&PROJECT_ROOT./data/raw";
libname INT   "&PROJECT_ROOT./data/intermediate";
libname MODEL "&PROJECT_ROOT./data/model";
libname OUT   "&PROJECT_ROOT./outputs";

/* Fail early if any permanent library is not assigned. */
%macro assert_lib(lib=);
    %if %sysfunc(libref(&lib.)) ne 0 %then %do;
        %put ERROR: Libref &lib. is not assigned. Check PROJECT_ROOT and folder structure.;
        %abort cancel;
    %end;
%mend;

%assert_lib(lib=RAW);
%assert_lib(lib=INT);
%assert_lib(lib=MODEL);
%assert_lib(lib=OUT);

/*--------------------------------------------------------------------------
  BASIC ASSERTIONS
--------------------------------------------------------------------------*/
%macro assert_scenario_weights;
    %local total;
    %let total=%sysevalf(&W_BASE + &W_UPSIDE + &W_DOWNSIDE);
    %if %sysevalf(%sysfunc(abs(&total-1)) > 1e-8) %then %do;
        %put ERROR: Scenario probabilities sum to &total, not 1.;
        %abort cancel;
    %end;
%mend;
%assert_scenario_weights;

%put NOTE: ===============================================================;
%put NOTE: IFRS 9 CREDIT RISK ENGINE INITIALIZED;
%put NOTE: PROJECT_ROOT=&PROJECT_ROOT;
%put NOTE: N_CUSTOMERS=&N_CUSTOMERS;
%put NOTE: SNAPSHOT WINDOW=%sysfunc(putn(&SNAP_START,date9.)) to %sysfunc(putn(&SNAP_END,date9.));
%put NOTE: ===============================================================;

/*=============================================================================
  IFRS 9 CREDIT RISK & ECL ENGINE — MASTER RUNNER

  EXPECTED SAS ONDEMAND LAYOUT
  ----------------------------
  ~/sas/      <- all .sas files in this folder
  ~/data/raw/ <- UNRATE.csv, FEDFUNDS.csv, GDP_REAL_GROWTH.csv
  ~/data/intermediate/
  ~/data/model/
  ~/outputs/

  This runner reproduces the frozen project pipeline from synthetic portfolio
  generation through monitoring / Power BI export.
=============================================================================*/

%let SAS_DIR=%sysget(HOME)/sas;

%put NOTE: ===================== PHASE 0/1 DATA =====================;
%include "&SAS_DIR./00_setup.sas";
%include "&SAS_DIR./01_build_foundation.sas";
%include "&SAS_DIR./02_build_monthly_history.sas";
%include "&SAS_DIR./03_build_recovery_ead_history.sas";
%include "&SAS_DIR./03A_fix_recovery_cutoff_flag.sas";

%put NOTE: ===================== PHASE 2/3 PIT PD ===================;
%include "&SAS_DIR./04_build_pit_pd_model.sas";
%include "&SAS_DIR./04A_refine_pit_pd_champion.sas";
%include "&SAS_DIR./05_validate_calibrate_pit_pd.sas";

%put NOTE: ===================== PHASE 4 LGD ========================;
%include "&SAS_DIR./06_build_lgd_champion.sas";
%include "&SAS_DIR./07_validate_lgd_champion.sas";

%put NOTE: ===================== PHASE 5 EAD/CCF ====================;
%include "&SAS_DIR./08_refine_ead_ccf_champion.sas";
%include "&SAS_DIR./09_finaltest_ead_ccf_champion.sas";

%put NOTE: ===================== PHASE 6 STAGING/SCENARIOS ==========;
%include "&SAS_DIR./10_build_ifrs9_staging_snapshot.sas";
%include "&SAS_DIR./11_build_scenario_framework.sas";
%include "&SAS_DIR./12_validate_phase6.sas";

%put NOTE: ===================== PHASE 7 LIFETIME ECL ===============;
%include "&SAS_DIR./13_build_production_risk_parameters.sas";
%include "&SAS_DIR./13B_apply_auto_lgd_p99_guardrail.sas";
%include "&SAS_DIR./14_build_lifetime_ecl_engine.sas";
%include "&SAS_DIR./15_validate_phase7.sas";

%put NOTE: ===================== PHASE 8 MONITORING ==================;
%include "&SAS_DIR./16_build_monitoring_mart.sas";
%include "&SAS_DIR./17_export_powerbi_mart.sas";
%include "&SAS_DIR./18_validate_monitoring_mart.sas";

%put NOTE: ==========================================================;
%put NOTE: IFRS 9 MASTER PIPELINE COMPLETE.;
%put NOTE: Review OUT.P8_FINAL_DECISION and the Phase 7 governance gate.;
%put NOTE: ==========================================================;

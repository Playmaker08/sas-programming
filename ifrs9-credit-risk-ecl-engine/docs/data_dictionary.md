# Reporting Data Dictionary

Primary reporting table: `data/processed/p8_powerbi_account_fact.csv`

| Field | Meaning |
|---|---|
| `account_id` | Synthetic account identifier |
| `customer_id` | Synthetic customer identifier |
| `product_type` | Credit Card, Auto Loan, Personal Loan |
| `report_date` | IFRS 9 reporting date |
| `origination_date` | Account origination date |
| `stage` | IFRS 9 stage number |
| `stage_label` | Human-readable stage |
| `stage_reason` | Primary staging trigger |
| `current_score` | Current synthetic credit score |
| `origination_score` | Origination synthetic score |
| `current_score_tier` | Current score band |
| `orig_score_tier` | Origination score band |
| `score_drop` | Origination score minus current score |
| `dpd` | Current days past due |
| `pd_current_cal` | Calibrated current 12M PIT PD |
| `pd_orig_cal` | Reconstructed calibrated origination PD |
| `pd_ratio_raw` | Current / origination raw-PD deterioration ratio |
| `pred_lgd_base` | Production base LGD after applicable guardrail |
| `gross_exposure` | Reporting-date drawn exposure |
| `ead_h3` / `ead_h6` / `ead_h12` | Approved EAD anchors |
| `ecl_base` | Base-scenario ECL |
| `ecl_upside` | Upside-scenario ECL |
| `ecl_downside` | Downside-scenario ECL |
| `weighted_ecl` | Probability-weighted ECL |
| `allowance_rate` | Weighted ECL / gross exposure |
| `stress_delta_ecl` | Scenario stress contribution |
| `low_risk_diag` | Low-risk diagnostic flag; does not override staging |
| `lgd_guardrail_flag` | Auto collateral-coverage P99 guardrail flag |
| `collateral_coverage_raw` | Raw Auto collateral coverage |
| `collateral_coverage_used` | Guardrailed model input |
| `sicr_bucket` | PD-deterioration monitoring bucket |
| `pd_band` | Current PD reporting band |
| `ecl_band` | Account-level ECL reporting band |

## Macro scenario table

`data/processed/p8_macro_scenarios_monthly.csv` contains 84 monthly observations for each of Base, Upside and Downside, including:
- unemployment rate,
- Fed Funds rate,
- real GDP growth,
- cumulative GDP level index,
- scenario stress index,
- scenario probability.

# Power BI Build Guide

## Data model

Primary table:
- `p8_powerbi_account_fact.csv` -> `Fact_AccountRisk`

Disconnected scenario table:
- `p8_macro_scenarios_monthly.csv` -> `Macro_Scenarios`

QA / governance tables are intentionally disconnected:
- Auto guardrail monitor
- Python challenger metrics / stage / product
- Python feature importance
- ECL concentration curve

## Page 1 — Executive Overview
- Hero cards: Exposure, Weighted ECL, Allowance Rate, Accounts
- Exposure by Stage
- ECL by Stage
- Stage-2 concentration callout
- Allowance rate by product
- Upside / Base / Downside ECL

## Page 2 — SICR & Credit Migration
- Stage-2 accounts / exposure / current PD / PD ratio
- SICR deterioration buckets
- Stage-reason breakdown
- Origination-to-current score migration matrix
- Origination vs current PD by stage

## Page 3 — Scenario & Stress Testing
- Upside / Base / Downside ECL
- Downside uplift and ECL spread
- Product × Stage downside/base sensitivity matrix
- Unemployment paths
- Real GDP growth paths
- Stress-index paths

Use `Average`, not `Sum`, when annual or monthly macro values are aggregated in line charts.

## Page 4 — Model Risk & Governance
- Challenger R²
- Challenger aggregate difference
- Auto LGD guardrail usage
- Governance gates
- Guardrail usage by stage
- Auto LGD before vs after guardrail
- SAS production vs Python challenger by stage
- ECL concentration curve

## Final dashboard screenshots

See `screenshots/`.

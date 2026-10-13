# Methodology

## 1. Portfolio foundation

The project simulates a retail portfolio across Credit Card, Auto Loan, and Personal Loan products. The synthetic engine creates customer/account attributes, monthly performance histories, defaults, recovery cash flows, and pre-default drawdown behavior while preserving state through time.

The simulation-only latent risk driver is never passed into development models.

## 2. PIT PD

### Target
A 12-month forward default target is created using a leakage-safe convention:

`X_t -> default during t+1 ... t+12`

### Development split
- TRAIN: through Dec-2023
- VALID: Jan-2024 through Jun-2024
- TEST: Jul-2024 through Dec-2024

### Champion
Logistic regression with borrower, performance, utilization, balance, affordability, tenure, product, and macro features.

An exact collinearity among DPD-derived features was identified and the redundant term was removed in the refined champion.

### Validation
- TRAIN AUC: 0.9089
- VALID AUC: 0.9012
- TEST AUC: 0.8972
- TEST raw Brier: 0.02977
- TEST calibrated Brier: 0.02940
- TEST observed default rate: 4.31%
- TEST calibrated mean PD: 3.89%

Calibration parameters are estimated on VALID only; TEST is not used for tuning.

## 3. LGD

### Secured Auto
A transformed regression is fitted to realized LGD using collateral coverage, borrower/default state, exposure, affordability, maturity and vehicle characteristics.

### Unsecured Card / Personal
A two-part hurdle architecture models:
1. probability of any recovery;
2. conditional recovery severity.

### Untouched TEST performance
Overall:
- observed LGD: 76.72%
- champion: 76.23%
- baseline: 78.78%
- champion RMSE: 0.0688
- champion MAE: 0.0512

By product:
- Auto RMSE: 0.0857 vs 0.1270 baseline
- Card RMSE: 0.0434 vs 0.0442
- Personal RMSE: 0.1025 vs 0.1087

## 4. EAD / CCF

A first long-horizon regression architecture was rejected after holdout testing exposed unstable extrapolation and collinearity.

The repaired production architecture uses:
- Card 3M: parsimonious CCF regression;
- Card 6M/12M: stable DEV mean CCF;
- Auto / Personal 3M/6M/12M: stable product × horizon DEV mean EAD ratios.

Governance was reset after the original holdout had been viewed:
- DEV: Jan-2021 through Jun-2024
- CALIB: Jul-2024 through Dec-2024
- FINALTEST: Jan-2025 through Dec-2025

All 9 product × horizon backtest gates passed.

## 5. SICR / Staging

Hierarchy:
1. Stage 3: current default / credit-impaired condition;
2. Stage 2: 30+ DPD backstop or relative PD deterioration;
3. Stage 1: otherwise performing.

The project uses a relative current/origination raw-PD multiple as a transparent SICR proxy. This is a project policy assumption, not a claim that one universal IFRS 9 multiple exists.

Final report-date distribution:
- Stage 1: 13,658 accounts; 94.59% of exposure
- Stage 2: 1,251 accounts; 5.01% of exposure
- Stage 3: 61 accounts; 0.40% of exposure

## 6. Forward-looking scenarios

Three 84-month macro paths:
- Base: 60%
- Upside: 20%
- Downside: 20%

Scenario ordering is governed using cumulative GDP level rather than monthly GDP-growth ordering, because a recovering downside economy can temporarily exhibit higher growth than the base path while remaining below it in level terms.

## 7. Lifetime ECL

The engine combines monthly:
- marginal PD,
- survival,
- scenario-adjusted LGD,
- scenario-adjusted EAD,
- effective-interest-rate discounting.

Stage 1 uses 12-month ECL. Stage 2 uses lifetime ECL subject to modeled behavioral / contractual horizons. Stage 3 uses simplified immediate credit-impaired loss mechanics.

Final weighted portfolio ECL:
- exposure: $129.459M
- ECL: $2.919M
- allowance rate: 2.255%
- Base ECL: $2.788M
- Upside ECL: $2.585M
- Downside ECL: $3.645M

## 8. Monitoring and challenger

The SAS monitoring mart reconciles exactly to the frozen risk master:
- source-to-mart exposure difference: $0
- source-to-mart ECL difference: $0
- governance: 3 / 3 PASS

An independent Python nonlinear surrogate explains production ECL behavior:
- R²: 0.9781
- MAE: $19.51
- RMSE: $115.66
- aggregate challenger / production ratio: 1.0017

Top explanatory drivers are calibrated current PD, production LGD, 12M EAD, gross exposure, shorter-horizon EAD anchors, stage, PD deterioration and DPD.

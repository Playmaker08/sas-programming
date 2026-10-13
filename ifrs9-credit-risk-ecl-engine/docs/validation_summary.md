# Validation Summary

| Component | Key test | Result | Decision |
|---|---|---:|---|
| PIT PD | TEST AUC | 0.8972 | PASS |
| PIT PD | TEST calibrated Brier | 0.0294 | PASS |
| PIT PD | TEST PSI | 0.0825 | PASS / monitor |
| LGD | TEST RMSE | 0.0688 | PASS |
| LGD | TEST MAE | 0.0512 | PASS |
| EAD/CCF | Product × horizon gates | 9 / 9 | PASS |
| Staging/scenarios | Governance checks | 3 / 3 | PASS |
| Lifetime ECL | Governance gates | 5 / 5 | PASS |
| Monitoring mart | Governance gates | 3 / 3 | PASS |
| Python challenger | R² | 0.9781 | PASS as surrogate |
| Python challenger | Aggregate difference | +0.17% | PASS |

## Final portfolio

| Metric | Value |
|---|---:|
| Accounts | 14,970 |
| Exposure | $129,458,972.62 |
| Weighted ECL | $2,918,936.60 (SAS full precision) |
| Allowance rate | 2.255% |
| Stage 1 ECL | $1,286,684 |
| Stage 2 ECL | $1,387,464 |
| Stage 3 ECL | $244,788 |
| Base ECL | $2,788,141 |
| Upside ECL | $2,585,105 |
| Downside ECL | $3,645,154 |

CSV exports can differ by a few cents from SAS full precision because formatted currency fields are rounded during export.

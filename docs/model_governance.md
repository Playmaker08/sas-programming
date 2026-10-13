# Model Governance & Limitation Register

## Frozen production components

The following components are frozen after validation:
- PIT PD specification and VALID calibration;
- LGD model structures;
- Auto LGD TRAIN-P99 production guardrail;
- EAD / CCF champions and horizon anchors;
- SICR / staging hierarchy;
- 84-month macro scenarios and 60/20/20 weights;
- lifetime PD mean-reversion structure;
- governed scenario overlay betas;
- Card Stage-2 60-month behavioral life;
- final `MODEL.RISK_MASTER`.

No component is retuned using the final portfolio ECL.

## Auto LGD production guardrail

Production review identified material extrapolation of Auto collateral coverage relative to the TRAIN-default support.

TRAIN collateral-coverage support:
- P95: 1.3212
- P99: 1.9894
- max: 2.0752

Production scoring:
- 5,220 Auto accounts
- 1,367 guarded
- 26.19% guardrail usage

Stage 2 was most affected:
- 69.42% guarded
- mean LGD: 7.14% -> 10.83%
- median LGD: 0.58% -> 6.52%

The model itself was not refitted. Only the production model input was capped at the TRAIN P99 while retaining raw collateral coverage for audit.

## Known limitations

### Stage 3 workout stock
The monthly synthetic history drops accounts after default / closure. Therefore the reporting-date Stage 3 population represents the visible/current default stock, not a fully reconstructed workout ledger. A production implementation should carry unresolved defaults until cure, write-off, or closure and model discounted workout cash shortfalls.

### Scenario overlays
PD/LGD/EAD stress betas are governed project assumptions. They are deliberately separated from the negative unemployment coefficient observed in the PIT PD regression and should not be interpreted as causal macro elasticities.

### Revolving lifetime EAD
For Stage-2 Credit Cards, the lifetime EAD path after 12 months uses a controlled behavioral assumption based on the approved 12M CCF anchor. This may be conservative relative to a dedicated long-horizon behavioral utilization model.

### SICR proxy
Relative 12M PD deterioration is used as a transparent SICR proxy. A bank implementation would generally compare lifetime risk over remaining maturity and apply portfolio-specific qualitative indicators / rebuttals.

### PD validation dependence
Temporal OOT validation is leakage-safe, but repeated account-month rows mean it is not an independent borrower-level holdout.

### Python challenger
The Python model targets frozen production ECL. Its R² measures cross-sectional explanatory fidelity, not realized-loss predictive performance.

## Governance decisions

- PD: APPROVED / FROZEN
- LGD: APPROVED / FROZEN
- EAD/CCF: APPROVED / FROZEN
- Staging / scenarios: TECHNICALLY READY
- Lifetime ECL: 5 / 5 governance gates PASS
- Monitoring / reporting: 3 / 3 governance gates PASS
- Python challenger: APPROVED as independent diagnostic layer

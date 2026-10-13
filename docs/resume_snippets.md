# Resume / Portfolio Snippets

## Finance / Credit Risk version

**IFRS 9 Credit Risk & ECL Engine | SAS, Python, PROC SQL, Power BI**
- Built an end-to-end IFRS 9 retail credit-risk engine across 14,970 reporting accounts and $129.5M of synthetic exposure, integrating calibrated PIT PD, secured/unsecured LGD, revolving CCF / term EAD, SICR staging, forward macro scenarios, and discounted 12-month / lifetime ECL.
- Validated model performance through leakage-safe temporal holdouts and governance gates, achieving 0.897 OOT PD AUC, 0.0294 calibrated Brier score, 9/9 EAD backtests, and 5/5 final ECL checks; identified out-of-support Auto LGD scoring and implemented a TRAIN-P99 production guardrail.
- Produced a $2.92M probability-weighted allowance (2.26% coverage), built an independent Python challenger explaining 97.8% of production ECL variance with +0.17% aggregate difference, and delivered a four-page Power BI risk-management dashboard.

## Data / Analytics version

**IFRS 9 Credit Risk Analytics Platform | SAS, Python, Power BI**
- Engineered a reproducible SAS-first analytics pipeline from synthetic customer/account generation through monthly performance history, model ABTs, PD/LGD/EAD scoring, staging, scenario ECL, validation, monitoring marts, and Power BI-ready exports.
- Built Python challenger and diagnostic workflows using pandas and scikit-learn to reproduce aggregate SAS ECL within 0.2%, rank production risk drivers, quantify scenario sensitivity, and identify concentration where the top 500 accounts generated ~59.7% of total ECL.
- Developed an executive Power BI layer spanning portfolio allowance, SICR and score migration, macro stress testing, model-risk guardrails, challenger reconciliation, and governance reporting.

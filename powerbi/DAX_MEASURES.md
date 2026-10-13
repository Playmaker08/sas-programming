# DAX Measures

```DAX
Total Exposure =
SUM(Fact_AccountRisk[gross_exposure])

Total ECL =
SUM(Fact_AccountRisk[weighted_ecl])

Allowance Rate =
DIVIDE([Total ECL], [Total Exposure])

Account Count =
DISTINCTCOUNT(Fact_AccountRisk[account_id])

Base ECL =
SUM(Fact_AccountRisk[ecl_base])

Upside ECL =
SUM(Fact_AccountRisk[ecl_upside])

Downside ECL =
SUM(Fact_AccountRisk[ecl_downside])

Downside vs Base =
[Downside ECL] - [Base ECL]

Downside Uplift % =
DIVIDE([Downside ECL] - [Base ECL], [Base ECL])

Average Current PD =
AVERAGE(Fact_AccountRisk[pd_current_cal])

Average Origination PD =
AVERAGE(Fact_AccountRisk[pd_orig_cal])

Stage 2 Exposure =
CALCULATE([Total Exposure], Fact_AccountRisk[stage] = 2)

Stage 2 Exposure Share =
DIVIDE([Stage 2 Exposure], [Total Exposure])

Stage 2 ECL =
CALCULATE([Total ECL], Fact_AccountRisk[stage] = 2)

Stage 2 ECL Share =
DIVIDE([Stage 2 ECL], [Total ECL])

Stage 2 Accounts =
CALCULATE([Account Count], Fact_AccountRisk[stage] = 2)

Stage 2 Avg Current PD =
CALCULATE(
    AVERAGE(Fact_AccountRisk[pd_current_cal]),
    Fact_AccountRisk[stage] = 2
)

Stage 2 Avg Orig PD =
CALCULATE(
    AVERAGE(Fact_AccountRisk[pd_orig_cal]),
    Fact_AccountRisk[stage] = 2
)

Stage 2 Avg PD Ratio =
CALCULATE(
    AVERAGE(Fact_AccountRisk[pd_ratio_raw]),
    Fact_AccountRisk[stage] = 2
)

Downside to Base Ratio =
DIVIDE([Downside ECL], [Base ECL])

Upside to Base Ratio =
DIVIDE([Upside ECL], [Base ECL])

Scenario ECL Spread =
[Downside ECL] - [Upside ECL]

Auto Guarded Accounts =
CALCULATE(
    [Account Count],
    Fact_AccountRisk[product_type] = "Auto Loan",
    Fact_AccountRisk[lgd_guardrail_flag] = 1
)

Auto Accounts =
CALCULATE(
    [Account Count],
    Fact_AccountRisk[product_type] = "Auto Loan"
)

Auto Guardrail Usage =
DIVIDE([Auto Guarded Accounts], [Auto Accounts])

Challenger R2 =
MAX(Challenger_Metrics[r2])

Challenger Aggregate Difference =
MAX(Challenger_Metrics[challenger_to_production]) - 1

ECL Governance Status =
"5 / 5"
```

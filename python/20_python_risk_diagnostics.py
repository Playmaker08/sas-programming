"""
IFRS 9 Credit Risk & ECL Engine
Phase 8D-2 V2 — Risk Driver / Scenario Diagnostics

V2 normalizes SAS-formatted currency / percent strings before calculations.
This script does not change any frozen SAS result.
"""

from pathlib import Path
import numpy as np
import pandas as pd

INPUT = Path("p8_powerbi_account_fact.csv")
OUT = Path("python_outputs")
OUT.mkdir(exist_ok=True)

df = pd.read_csv(INPUT, dtype=str)


def parse_sas_numeric(series: pd.Series) -> pd.Series:
    """
    Parse numeric columns exported by SAS PROC EXPORT when display formats are
    preserved, e.g. '$43.77', '$1,234.56', '2.255%', '1.486', '.', or blank.

    Percent strings are converted to decimal form:
        '2.255%' -> 0.02255
    """
    s = series.astype("string").str.strip()

    # SAS/display missing representations
    s = s.replace({
        "": pd.NA,
        ".": pd.NA,
        "NA": pd.NA,
        "N/A": pd.NA,
        "nan": pd.NA,
        "None": pd.NA
    })

    pct = s.str.endswith("%", na=False)

    # Accounting negatives: ($123.45) -> -123.45
    neg_paren = s.str.match(r"^\(.*\)$", na=False)
    s = s.str.replace(r"^\((.*)\)$", r"\1", regex=True)

    # Remove currency symbols, commas, percent signs and spaces
    s = (
        s.str.replace("$", "", regex=False)
         .str.replace(",", "", regex=False)
         .str.replace("%", "", regex=False)
         .str.replace(" ", "", regex=False)
    )

    out = pd.to_numeric(s, errors="coerce")
    out.loc[pct] = out.loc[pct] / 100.0
    out.loc[neg_paren] = -out.loc[neg_paren].abs()
    return out


numeric_cols_to_parse = [
    "stage", "current_score", "score_drop", "dpd",
    "pd_current_cal", "pd_orig_cal", "pd_ratio_raw",
    "pred_lgd_base", "gross_exposure",
    "ead_h3", "ead_h6", "ead_h12",
    "weighted_ecl", "ecl_base", "ecl_upside", "ecl_downside",
    "lgd_guardrail_flag"
]

missing = [c for c in numeric_cols_to_parse + ["account_id", "product_type"]
           if c not in df.columns]
if missing:
    raise ValueError(f"Missing required columns: {missing}")

for c in numeric_cols_to_parse:
    df[c] = parse_sas_numeric(df[c])

# Scenario stress contribution
df["downside_uplift"] = df["ecl_downside"] - df["ecl_base"]
df["upside_relief"] = df["ecl_base"] - df["ecl_upside"]
df["downside_uplift_pct"] = np.where(
    df["ecl_base"] > 0,
    df["downside_uplift"] / df["ecl_base"],
    np.nan
)

scenario = (
    df.groupby(["product_type", "stage"], as_index=False)
    .agg(
        accounts=("account_id", "count"),
        exposure=("gross_exposure", "sum"),
        weighted_ecl=("weighted_ecl", "sum"),
        base_ecl=("ecl_base", "sum"),
        downside_ecl=("ecl_downside", "sum"),
        downside_uplift=("downside_uplift", "sum"),
        upside_relief=("upside_relief", "sum")
    )
)
scenario["downside_to_base"] = (
    scenario["downside_ecl"] / scenario["base_ecl"]
)
scenario.to_csv(OUT / "python_scenario_diagnostics.csv", index=False)

# PD migration diagnostics
df["pd_abs_change"] = df["pd_current_cal"] - df["pd_orig_cal"]
migration = (
    df.groupby(["product_type", "stage"], as_index=False)
    .agg(
        accounts=("account_id", "count"),
        exposure=("gross_exposure", "sum"),
        avg_current_pd=("pd_current_cal", "mean"),
        avg_orig_pd=("pd_orig_cal", "mean"),
        avg_pd_ratio=("pd_ratio_raw", "mean"),
        avg_pd_abs_change=("pd_abs_change", "mean"),
        avg_score_drop=("score_drop", "mean")
    )
)
migration.to_csv(OUT / "python_pd_migration_diagnostics.csv", index=False)

# Auto guardrail diagnostics
auto = df[df["product_type"].eq("Auto Loan")].copy()
guardrail = (
    auto.groupby("stage", as_index=False)
    .agg(
        accounts=("account_id", "count"),
        guarded_accounts=("lgd_guardrail_flag", "sum"),
        avg_lgd=("pred_lgd_base", "mean"),
        exposure=("gross_exposure", "sum"),
        weighted_ecl=("weighted_ecl", "sum")
    )
)
guardrail["guarded_share"] = (
    guardrail["guarded_accounts"] / guardrail["accounts"]
)
guardrail.to_csv(
    OUT / "python_auto_guardrail_diagnostics.csv", index=False
)

# ECL concentration curve
ranked = df.sort_values("weighted_ecl", ascending=False).copy()
total_ecl = ranked["weighted_ecl"].sum()
total_exp = ranked["gross_exposure"].sum()

top_ns = [10, 25, 50, 100, 250, 500]
concentration = pd.DataFrame({
    "top_n": top_ns,
    "ecl_share": [
        ranked.head(n)["weighted_ecl"].sum() / total_ecl
        for n in top_ns
    ],
    "exposure_share": [
        ranked.head(n)["gross_exposure"].sum() / total_exp
        for n in top_ns
    ]
})
concentration.to_csv(
    OUT / "python_ecl_concentration_curve.csv", index=False
)

print("Phase 8D-2 V2 risk diagnostics complete.")
print("\nScenario diagnostics:")
print(scenario.to_string(index=False))
print("\nECL concentration curve:")
print(concentration.to_string(index=False))

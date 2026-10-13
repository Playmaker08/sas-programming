"""
IFRS 9 Credit Risk & ECL Engine
Phase 8D-1 V2 — Python Challenger & Explainability

V2 FIX
------
SAS PROC EXPORT preserves display formats for some numeric fields.  Therefore
values such as '$43.77' or '2.255%' arrive in CSV as strings.  V2 explicitly
normalizes SAS-formatted currency / percent / numeric fields before modeling.

This remains an independent analytics/challenger layer only.
It does NOT replace the frozen SAS production engine.
"""

from pathlib import Path
import numpy as np
import pandas as pd

from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.impute import SimpleImputer
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.inspection import permutation_importance
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

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


required = [
    "account_id", "product_type", "stage", "current_score", "score_drop",
    "dpd", "pd_current_cal", "pd_orig_cal", "pd_ratio_raw",
    "pred_lgd_base", "gross_exposure", "ead_h3", "ead_h6", "ead_h12",
    "weighted_ecl", "ecl_base", "ecl_upside", "ecl_downside",
    "lgd_guardrail_flag"
]
missing = [c for c in required if c not in df.columns]
if missing:
    raise ValueError(f"Missing required columns: {missing}")

numeric_cols_to_parse = [
    "stage", "current_score", "score_drop", "dpd",
    "pd_current_cal", "pd_orig_cal", "pd_ratio_raw",
    "pred_lgd_base", "gross_exposure",
    "ead_h3", "ead_h6", "ead_h12",
    "weighted_ecl", "ecl_base", "ecl_upside", "ecl_downside",
    "lgd_guardrail_flag"
]

for c in numeric_cols_to_parse:
    df[c] = parse_sas_numeric(df[c])

# Guardrail / input audit
audit = []
for c in numeric_cols_to_parse:
    audit.append({
        "column": c,
        "missing_after_parse": int(df[c].isna().sum()),
        "min": df[c].min(skipna=True),
        "max": df[c].max(skipna=True)
    })
pd.DataFrame(audit).to_csv(OUT / "python_input_parse_audit.csv", index=False)

# Required target must be fully numeric.
if df["weighted_ecl"].isna().any():
    bad = int(df["weighted_ecl"].isna().sum())
    raise ValueError(
        f"weighted_ecl still has {bad} missing/non-numeric values after SAS-format parsing."
    )

features = [
    "product_type", "stage", "current_score", "score_drop", "dpd",
    "pd_current_cal", "pd_orig_cal", "pd_ratio_raw", "pred_lgd_base",
    "gross_exposure", "ead_h3", "ead_h6", "ead_h12", "lgd_guardrail_flag"
]
target = "weighted_ecl"

X = df[features].copy()
y = df[target].astype(float)

cat_cols = ["product_type"]
num_cols = [c for c in features if c not in cat_cols]

pre = ColumnTransformer(
    transformers=[
        ("num", Pipeline([
            ("imp", SimpleImputer(strategy="median")),
            ("scale", StandardScaler())
        ]), num_cols),
        ("cat", Pipeline([
            ("imp", SimpleImputer(strategy="most_frequent")),
            ("oh", OneHotEncoder(handle_unknown="ignore"))
        ]), cat_cols)
    ],
    remainder="drop"
)

model = HistGradientBoostingRegressor(
    loss="squared_error",
    learning_rate=0.05,
    max_iter=300,
    max_leaf_nodes=31,
    l2_regularization=1.0,
    random_state=42
)

pipe = Pipeline([("prep", pre), ("model", model)])
pipe.fit(X, y)

pred = np.clip(pipe.predict(X), 0, None)

metrics = pd.DataFrame([{
    "n_accounts": len(df),
    "mae": mean_absolute_error(y, pred),
    "rmse": mean_squared_error(y, pred) ** 0.5,
    "r2": r2_score(y, pred),
    "production_total_ecl": y.sum(),
    "challenger_total_ecl": pred.sum(),
    "challenger_to_production": pred.sum() / y.sum()
}])
metrics.to_csv(OUT / "python_challenger_metrics.csv", index=False)

eval_df = df[
    ["account_id", "product_type", "stage", "gross_exposure", target]
].copy()
eval_df["challenger_ecl"] = pred
eval_df["residual"] = eval_df[target] - eval_df["challenger_ecl"]
eval_df["abs_residual"] = eval_df["residual"].abs()

stage = (
    eval_df.groupby("stage", as_index=False)
    .agg(
        accounts=("account_id", "count"),
        production_ecl=(target, "sum"),
        challenger_ecl=("challenger_ecl", "sum"),
        mae=("abs_residual", "mean")
    )
)
stage["challenger_to_production"] = (
    stage["challenger_ecl"] / stage["production_ecl"]
)
stage.to_csv(OUT / "python_stage_challenger.csv", index=False)

prod = (
    eval_df.groupby("product_type", as_index=False)
    .agg(
        accounts=("account_id", "count"),
        exposure=("gross_exposure", "sum"),
        production_ecl=(target, "sum"),
        challenger_ecl=("challenger_ecl", "sum"),
        mae=("abs_residual", "mean")
    )
)
prod["challenger_to_production"] = (
    prod["challenger_ecl"] / prod["production_ecl"]
)
prod.to_csv(OUT / "python_product_challenger.csv", index=False)

# Model-agnostic importance on the original business features.
perm = permutation_importance(
    pipe,
    X,
    y,
    scoring="neg_mean_absolute_error",
    n_repeats=5,
    random_state=42,
    n_jobs=-1
)

importance = (
    pd.DataFrame({
        "feature": features,
        "importance_mean": perm.importances_mean,
        "importance_std": perm.importances_std
    })
    .sort_values("importance_mean", ascending=False)
)
importance.to_csv(OUT / "python_feature_importance.csv", index=False)

eval_df.sort_values("abs_residual", ascending=False).head(100).to_csv(
    OUT / "python_top_residual_accounts.csv", index=False
)

print("Phase 8D-1 V2 challenger complete.")
print("\nInput parse audit:")
print(pd.DataFrame(audit).to_string(index=False))
print("\nChallenger metrics:")
print(metrics.to_string(index=False))
print("\nTop 10 permutation-importance features:")
print(importance.head(10).to_string(index=False))

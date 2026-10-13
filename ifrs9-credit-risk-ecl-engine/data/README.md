# Data

## `processed/`
Contains synthetic, reporting-level outputs used by Power BI and the Python challenger. The main account-level reporting fact contains 14,970 synthetic accounts.

## `external/`
Raw macroeconomic CSVs are not bundled in this package. The SAS pipeline expects:
- `UNRATE.csv`
- `FEDFUNDS.csv`
- `GDP_REAL_GROWTH.csv`

Use official public macroeconomic sources and preserve the expected column names documented in `01_build_foundation.sas`.

## Privacy
No real borrower or bank customer records are included.

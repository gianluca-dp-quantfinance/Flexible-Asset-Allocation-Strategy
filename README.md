# Flexible-Asset-Allocation-Strategy
Quantitative asset allocation framework combining momentum, volatility and correlation signals, with backtesting, risk metrics and strategy extensions.
# Flexible Asset Allocation (FAA): Multi-Factor Momentum Strategy

## Overview

This project implements and extends the Flexible Asset Allocation (FAA) framework originally proposed by Keller & Van Putten and popularized by Alpha Architect.

The strategy dynamically allocates capital across a diversified multi-asset universe by combining momentum, volatility, and correlation to improve risk-adjusted returns and portfolio resilience.

---

## Methodology

### Core Idea

Assets are ranked using a multi-factor scoring function, selecting the top-performing subset at each monthly rebalance.

$L_i = w_R \cdot \text{rank}(r_i) + w_V \cdot \text{rank}(v_i) + w_C \cdot \text{rank}(c_i)$

Lower score implies a better risk-return profile.

---

### Strategy Variants

* **R** → Relative Momentum
* **RA** → Relative + Absolute Momentum
* **RAV** → + Volatility
* **RAVC** → + Volatility + Correlation

---

### Portfolio Construction

* Top 7 assets selected each month
* Monthly rebalancing
* Allocation:

  * Equal-weight (baseline)
  * Momentum-weighted (enhanced version)

---

### Modified Strategy

Two extensions are introduced:

1. Momentum-weighted allocation:
  $w_i \propto \mathrm{MOM}_i$

2. Semi-standard deviation (downside risk):
   Focuses only on negative returns, improving risk measurement consistency.

---
## Repository Structure

- `FAA.m` — implements the original Flexible Asset Allocation (FAA) backtest, including momentum, volatility, and correlation-based ranking

- `FAA_modified.m` — implements the modified FAA strategy with momentum-weighted allocation and downside risk measures

- `RunBacktestStrategy.m` — runs the original FAA backtest and generates portfolio performance

- `RunBacktestStrategy_modified.m` — runs the modified FAA strategy

- `evaluateStrategy.m` — computes performance, risk, and robustness metrics

--- 
## Dataset

The strategy is designed to work with **daily price time series structured as MATLAB timetables**, with dates and asset prices aligned across columns.

---

### Required Data Format
The input data must follow this structure:

* First column: `Date` (datetime format)
* Remaining columns: asset prices (numeric), with column names corresponding to asset identifiers
* Each row: one daily observation

---

### Key Requirements

* Dates must be properly formatted and convertible to `datetime`
* Each column represents a different asset
* Missing values (`NaN`) are allowed to avoid survivorship bias but should be handled appropriately
* Prices must be **aligned across assets and time**
* The same asset universe must be used consistently across the dataset

---

### Note

Monthly data used for momentum and portfolio rebalancing are internally constructed from daily prices within the script.

---

## Backtesting Framework

The analysis is performed across three datasets:

* In-Sample (60%) → model calibration
* Out-of-Sample (40%) → robustness testing
* Full Sample → overall evaluation

---

## Performance Metrics

### Standard Metrics

* CAGR
* Volatility
* Sharpe Ratio

### Downside Risk

* Sortino Ratio
* Maximum Drawdown
* Calmar Ratio

### Tail Risk

* Value at Risk (VaR)
* Expected Shortfall (ES)

### Robustness

* Rolling returns
* Win probability
* Drawdown duration

---

## Omega Portfolio Rating (OPR)

A proprietary metric combining:

* Calmar Ratio
* Modified Sortino Ratio
* Validity Index

Used to evaluate overall performance relative to a benchmark.

---

## Key Results

* Multi-factor strategies (RAV, RAVC) outperform simpler momentum models in risk-adjusted terms

* Significant improvement in:

  * Drawdowns
  * Tail risk
  * Stability

* Trade-off:

  * Slightly lower raw returns vs pure momentum
  * Higher robustness and consistency

---

## Possible extensions

* Transaction costs inclusion
* Risk parity allocation
* Volatility targeting
* Dynamic factor weighting
* Machine learning-based ranking

---

## Implementation

* Language: MATLAB
* Structure:

  * Data preprocessing
  * Factor computation
  * Ranking model
  * Portfolio construction
  * Backtesting
  * Performance evaluation

---

## Key Takeaways

Combining momentum with volatility and correlation produces a more stable and robust asset allocation strategy, suitable for systematic portfolio management.

---

## References

* Keller & Van Putten (2012) – Generalized Momentum and Flexible Asset Allocation
* Alpha Architect – FAA implementation

---

## Authors
Francesco Melocchi, Gianluca De Pieri, Tommaso Rossini

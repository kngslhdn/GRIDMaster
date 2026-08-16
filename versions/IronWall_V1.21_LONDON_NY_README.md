# IronWall V1.21 — London + New York Session Gate

## Purpose

V1.21 is a controlled experiment from the proven IronWall V1.10 engine.

**Only change:** trading is allowed during London and New York server-time windows. The IronWall momentum wall, trigger handling, lot sizing, distance logic, and account-mode handling are preserved.

## Session defaults

| Session | Server time | Trading |
|---|---:|---|
| London | 08:00–16:00 | ON |
| New York | 13:00–21:00 | ON |
| Asia | Outside both windows | OFF |

London/New York overlap is allowed.

> **Important:** these hours use `TimeCurrent()` / broker server time. They are not automatically converted from UTC, WIB, London local time, or New York local time. Adjust the four hour inputs if the broker server offset requires it.

## Behaviour outside sessions

- All IronWall pending BUY STOP / SELL STOP orders are deleted.
- Existing active positions are **not** force-closed.
- No new wall is created until an allowed session is active.
- This prevents a pending wall created in London/New York from triggering during Asia.

## Core preserved from V1.10

- Fixed lot size.
- Fixed price distance.
- Two-sided pending wall when flat.
- BUY/SELL momentum trigger handling.
- Hedging-account normalization.
- Netting-account normalization.
- One active IronWall position.
- No EMA, RSI, ATR, ADX, spread, volatility, or trend filter.

## A/B test protocol

Do not compare this version using a different timeframe, lot, distance, or date range at the same time.

Recommended comparison:

- Symbol: same XAU symbol.
- Timeframe: same as V1.10 baseline.
- Model: Every tick based on real ticks.
- Deposit: same.
- Lot: `0.01`.
- Distance: `10.0`.
- Date range: identical.
- Only session setting changes.

Compare:

1. Net profit
2. Profit factor
3. Max equity drawdown
4. Total trades
5. Win rate
6. Daily P/L
7. London P/L
8. New York P/L
9. Number of losses during blocked Asia hours

V1.10 remains the baseline and is not modified by this version.

# IronWall V1.22 — Tier-A Session Control

## Purpose

This version keeps the IronWall V1 core behavior and adds only a trading-window controller based on the Tier-A hours identified from the provided backtest.

## Core preserved

- Fixed lot size
- Fixed pending distance
- BUY STOP + SELL STOP wall
- Opposite pending removal when a position is active
- Original IronWall order/rebuild concept
- No EMA / RSI / ATR / ADX filter

## Tier-A windows

All times use the MT5 broker/server clock. End time is exclusive.

| Window | Default | Time |
|---|---:|---:|
| Session 1 | ON | 00:00–01:00 |
| Session 2 | ON | 04:00–06:00 |
| Session 3 | ON | 10:00–12:00 |
| Session 4 | ON | 13:00–16:00 |

## Outside Tier-A

When the EA is outside all enabled windows:

- No new pending orders are allowed.
- Existing IronWall pending orders are deleted.
- Existing IronWall positions are closed.
- The EA remains idle until the next enabled window.

The cleanup is transition-aware, but an outside-session safety check also runs on every tick to prevent stale orders/positions from remaining active.

## Session transition

`ACTIVE -> OUTSIDE`

1. Close IronWall positions.
2. Delete IronWall pending orders.
3. Remain idle.

`OUTSIDE -> ACTIVE`

1. Resume the original IronWall engine.
2. If there is no active position, rebuild the BUY STOP + SELL STOP wall.

## Important test rule

For the first A/B test, do not change lot size, distance, timeframe, or other core parameters. The purpose is to isolate the effect of the Tier-A session control.

Recommended comparison:

- Baseline: IronWall V1 with original session behavior.
- Candidate: IronWall V1.22 Tier-A session control.

Use the same symbol, timeframe, dates, deposit, lot and distance.

## Version safety

This is a new version file. Existing IronWall versions are not overwritten.

# IronWall V1.20 - London + New York Session Build

## Baseline
This build preserves the IronWall V1.10 momentum moving-wall engine.

Source baseline: `IronWall.mq5` / V1.10.

## Only change
A session gate was added so new pending orders are allowed only during the configured London and New York windows.

Default broker/server-time windows:
- London: 08:00-16:00
- New York: 13:00-21:00
- Asia/outside: no new pending wall

## Core engine unchanged
- Same fixed lot
- Same distance
- Same BUY STOP / SELL STOP wall
- Same trigger handling
- Same position/reversal engine
- No EMA
- No RSI
- No ATR
- No spread filter
- No SL/TP

`InpClosePositionsOutside=false` by default, so an active position is preserved outside the trading windows; only pending orders are removed.

## Important
The session hours are **broker/server time**, not automatically UTC or WIB. Verify the Exness server clock before optimizing the two windows.

## Validation
Run the same V1.10 baseline backtest and compare daily results against V1.20. Do not optimize distance/lot yet; this build is intended to isolate the effect of skipping Asia.

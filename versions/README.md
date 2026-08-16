# IronWall Version Archive

## Frozen versions

- V1.10: original Momentum Moving Wall Engine.
- V1.22_TIER_A_SESSION: session-filter experiment.
- V2.00: Momentum Retention Engine.
- V3.00: Adaptive Trend Wall Engine.

## V3.10 — Session Edge + Loss Containment

Based on the long-term XAUUSDm M30 Strategy Tester report (2026.01.01–2026.08.14), V3.10 targets the two critical weaknesses found in V2:

- The tested 04:00–06:00 window produced a strongly negative result and is removed from the default trading window.
- The tested 10:00–11:00 window was the strongest observed session in that report and becomes the default session.
- Hard SL is enabled by default to prevent the large tail losses that caused the 100% drawdown.
- Break-even protection and profit trailing are added as a layered protection engine.
- The original two-sided BUY STOP / SELL STOP wall concept is retained.
- While a position is active, only the opposite reversal wall is maintained.
- Outside the session, pending orders are deleted and the active campaign is closed at session end by default.

### Default V3.10 parameters

- Lot: 0.05
- Wall distance: 10.0 price
- Session: 10:00–11:00 server time
- Hard SL: 12.0 price
- Break-even: +5.0 price, lock +0.5
- Profit trail: starts +8.0 price, distance 4.0

## Rule

Never overwrite a validated version. Every major engine change gets a new version file and a new archive entry.

**Important:** V3.10 is a corrective candidate, not yet a proven profitable version. It must be backtested on the same 100% real-tick period before live use.

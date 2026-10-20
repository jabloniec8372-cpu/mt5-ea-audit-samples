# Reject-Reason Audit - webhook/server records (sample)

Read-only audit of historical webhook and server records from a TradingView -> Python -> MT5 DEMO automation system. No code, strategy, alerts, EA or runtime data were changed. Local paths have been removed from this copy.

## Data and method

- Primary source: the server signal log, covering 2026-06-10 17:39 UTC to 2026-06-15 09:40 UTC; 310,020 lines parsed, 0 JSON parse errors.
- Secondary check: the signal queue database (CADJPY: 0 rows, AUDJPY: 0 rows). It only holds signals that Python accepted, so the rejection audit relies on the log.
- Counts were built from `signal_received`, `strategy_accepted` and `strategy_rejected` events. Rejected events do not log the timeframe, so each `signal_id` was mapped back to its `signal_received` payload to recover it.
- Targets: `CADJPY H2` and `AUDJPY H4`.

## Results

| Target | Alerts | Accepted | Rejected |
|---|---:|---:|---:|
| CADJPY H2 | 0 | 0 | 0 |
| AUDJPY H4 | 1 | 0 | 1 |

The single AUDJPY H4 alert (BUY, received 2026-06-12 21:01:02 UTC) was rejected with `outside_allowed_session`. It arrived one minute after the New York session gate closed at 21:00:00 UTC. The rejection was not caused by symbol, timeframe, JSON structure or tick-size validation; the strategy stopped at the session filter before reaching market-structure and risk checks.

## Interpretation and limits

- No CADJPY H2 alerts exist in the audited window, so the log shows no production impact for CADJPY. That does **not** prove CADJPY is safe.
- A separate local POST audit had already found a code-level defect: AUDJPY and CADJPY were missing from the JPY symbol set used for tick-size and stop-buffer validation, so they were validated with the wrong tick model.
- The session rejection may be intentional (it uses server receive time), so it needs review before any architectural change.

## Recommendation

`PATCH_REQUIRED = YES` for the latent tick-size classification defect. Minimal change:

```diff
-JPY_FOREX_SYMBOLS = {"USDJPY", "EURJPY", "GBPJPY"}
+JPY_FOREX_SYMBOLS = {"USDJPY", "EURJPY", "GBPJPY", "AUDJPY", "CADJPY"}
```

Regression tests to add:

- CADJPY H2 BUY/SELL with `0.001` tick prices and a `0.010` stop buffer
- AUDJPY H4 BUY/SELL with `0.001` tick prices and a `0.010` stop buffer
- existing EURJPY, GBPJPY and XAUUSD behavior unchanged

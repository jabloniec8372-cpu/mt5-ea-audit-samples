# MT5 EA audit samples

Work samples for MQL5 / MetaTrader 5 code review and debugging: the source of an Expert Advisor I maintain, plus two sanitized audit reports written about it.

## What is here

| File | What it shows |
|---|---|
| [`TVWebhookExecutorEA.mq5`](TVWebhookExecutorEA.mq5) | MQL5 Expert Advisor (v1.31, ~64 KB) that polls a local signal server and executes trades on a **DEMO** account |
| [`MT5_EA_Settings_Audit_sample.md`](MT5_EA_Settings_Audit_sample.md) | Read-only audit of the EA's defaults, inputs and safety behavior against the final DEMO configuration |
| [`Reject_Reason_Audit_sample.md`](Reject_Reason_Audit_sample.md) | Audit of ~310k server log lines: why alerts were rejected, and a latent tick-size classification defect with a minimal patch and regression tests |

## What the EA does

- Polls a local server for signals, validates them and sends orders with `CTrade`
- **DEMO-only guard:** `OnInit()` fails on any non-demo account
- Lot sizing and risk limits: per-symbol lot caps, estimated risk in USD and as a percentage of equity (`OrderCalcProfit`), EUR/USD account conversion
- SL/TP validation against the broker's stop level and freeze level, minimum projected reward/risk, tick-size rounding of TP
- Spread filters per symbol group, entry-distance filter, signal-age filter
- Duplicate-signal protection with a persisted outcome log, so replays are acknowledged consistently
- Position limits per account and per symbol family, daily loss limits (trade count and equity %), optional break-even
- Broker symbol resolution across suffixes (`.raw`, `m`, `GOLD` aliases)
- Structured log events for every accept/reject decision

## About the audits

The audits are the kind of deliverable I would write for a code review job: what was checked, what was found, what is *not* proven, and a minimal recommended change. Local paths and identifiers were removed from the copies in this repo.

## Notes

- The EA is **webhook/server driven**, so it is not designed to run in the MT5 Strategy Tester.
- The default `SecretKey` in the source is a placeholder, not a real secret.
- Demo use only. This is engineering work, not trading advice, and no profitability is claimed.
- Developed with AI-assisted tooling; every change is tested on a demo account and documented.

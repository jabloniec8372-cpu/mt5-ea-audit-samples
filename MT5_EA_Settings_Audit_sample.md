# MT5 Expert Advisor - Demo Settings Audit (sample)

Read-only audit of an MQL5 Expert Advisor (`TVWebhookExecutorEA.mq5`, declared version 1.30 at audit time) used for automated DEMO execution on MetaTrader 5. No EA files, profiles, inputs, templates, entry logic, SL, TP, RR or position handling were changed during the audit. Local paths and identifiers have been removed from this copy.

Final symbol list for the DEMO run:

```text
AUDJPY,CADJPY,GBPAUD,XAUUSD,EURJPY,GBPJPY
```

## 1. Source integrity check

- The project source and the source deployed to the MT5 terminal had identical SHA256 hashes, so the deployed `.mq5` matched the project.
- The deployed and project `.ex5` binaries had different hashes. A hash alone cannot show whether the difference is only compile metadata, so the recommendation was to confirm version `1.30` in the EA start-up log before running on DEMO.

## 2. Default parameters vs. what the final DEMO needed

| Parameter | Code default | Assessment |
|---|---|---|
| `ServerBaseUrl` | `http://127.0.0.1:18080` | Must be set to the correct local port in Inputs |
| `SecretKey` | placeholder value | Must be replaced by a secret identical to the server-side one |
| `DemoSafeMode` | `true` | Correct; the code also hard-blocks non-DEMO accounts |
| `FixedLot` | `0.01` | Correct |
| `AllowedSymbols` | 13 symbols including all 6 final ones | Allows the final six but does not restrict the EA to them |
| `MaxOpenPositionsTotal` | `5` | Unchanged |
| `MaxOpenPositionsPerSymbol` | `1` | Correct |
| `MoveToBreakEvenAtOneR` | `true` | Existing behavior, not changed |

## 3. Safety behavior verified in code

- **DEMO-only guard:** `OnInit()` returns `INIT_FAILED` if the account is not a DEMO account, which is stronger than the `DemoSafeMode` input alone.
- **Lot cap:** the effective fixed lot is limited to 0.01; a symbol is rejected if the broker does not allow that volume.
- **Position limits:** `MaxOpenPositionsPerSymbol=1` is enforced for the whole symbol family; a second signal is rejected as `REJECT_MAX_SYMBOL_POSITIONS`.
- **Secret check:** the secret returned inside a signal is compared with the local `SecretKey`; a mismatch is rejected as `REJECT_SECRET`.
- **Broker symbol resolution:** exact name, `.raw` variant, no-suffix variant, `m` variant and prefix-based variants are all handled.
- **No timeframe filter in the EA:** symbol/timeframe pairs are controlled upstream, not in the EA.

## 4. Findings

| Question | Answer |
|---|---|
| Does the EA code support the final six symbols? | Yes |
| Does it block any of them? | No |
| Does the EA code need changes? | No - Inputs are enough |
| Was the saved chart profile ready for the final six? | **No** - it still held an older 10-symbol `AllowedSymbols` list missing AUDJPY, CADJPY and GBPAUD, so a reloaded instance could reject those three |
| Recommended action | Save a dedicated template for the final DEMO configuration |

A template or profile can store the secret in plain text, so it must never be published or committed.

## 5. Required Inputs before the DEMO run

```text
ServerBaseUrl=<local server URL>
SecretKey=<identical to the server-side secret>
DemoSafeMode=true
FixedLot=0.01
AllowedSymbols=AUDJPY,CADJPY,GBPAUD,XAUUSD,EURJPY,GBPJPY
MaxOpenPositionsPerSymbol=1
```

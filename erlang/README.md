# twinpay

Venmo-like token payments orchestrated by agents, built on the finance-twin
banking framework. The commerce is **tokens**: the app gifts business tokens
(TWIN) to agents, and agents send them to each other with Venmo-style handles
and memos. Agents drive everything through an HTTP/JSON API.

```
agents --HTTP/JSON--> twinpay (Erlang/OTP 25)
                        |-- payment_fsm      supervised per-payment state machine
                        |-- treasury         gift (mint) / burn, token supply
                        |-- ledger           double-entry, integer minor units
                        |-- reversal         offsetting entries, never mutation
                        |-- idempotency      keys make retries safe
                        |-- worm             hash-chained audit (vendored C lib)
                        |-- plaid_client     read-only verification (fiat boundary)
                        |-- rails_ach        NACHA file builder (fiat off-ramp)
                        `-- rails_rtp        RTP-style instruction outbox
```

## Token model

- Unit: **TWIN**, counted in integer minor units (100 per TWIN). No floats
  anywhere in the money path.
- **Gifts**: the app treasury mints tokens to agents (onboarding, rewards).
  Minting is an authorized, WORM-anchored *issuance* event — never a transfer.
  Only actors in `treasury_issuers` may mint; the HTTP gift endpoint also
  requires the `x-treasury-key`.
- **Transfers**: debit sender / credit receiver, two balanced legs. Legs
  always sum to zero; `GET /v1/conservation` proves it live.
- **Reversals**: post a new balanced transfer in the opposite direction and
  flag the original. A second reversal attempt returns `already_reversed`.
  History is append-only; nothing is ever mutated or deleted.
- **Burn**: destroys tokens (used by redemption). Supply = issued − burned.

## Provenance: what came from the finance twin

The framework is `devflow-finance-twin`'s `finance/` layer, used under your
two rules — **no header, no extraction; no hallucinated math**:

- **Vendored verbatim** (license headers intact, never modified):
  `c_src/worm_block.h` + `c_src/worm_commit.c` — the WORM hash-chained
  append-only store (SL-AGPL3-001 / AGPL-3.0-or-later). Erlang talks to it
  through the fresh port driver `c_src/worm_port.c` (real SHA-256 via OpenSSL).
  Every gift, transfer, burn, and reversal is anchored in the chain, and
  `GET /v1/conservation` verifies the chain end to end.
- **Fresh implementations of source-verified patterns** (the twin's COBOL /
  RPGLE / C# banking files carry no license header, so they are reference
  only — nothing was copied):
  - idempotency keys on intake (twin: `RtpRailAdapter.cs`, `COBILT-ACH-TREASURY`)
  - reversal as balanced offsetting entry with an already-reversed guard
    (twin: `LEDREVSRV.rpgle` ALREADYREV)
  - double-entry debit/credit posting (twin: `LEDGER_POST.cbl`)
  - fail-closed hash-linked vault semantics (twin: `COBILT-VAULT.cbl`)
  - 128-byte canonical entry layout discipline (twin: `worm_block.h` offsets)
- **Deliberately not taken**: `docs/FILE_REFERENCE_finance.md` misdescribes
  `FNLIRTR.rpgle` as a payment rail router (it is a Funnel parser) — there is
  no verified rail-selection engine in the twin, so twinpay has none either.

## Honest boundaries

- **Plaid is read-only and optional for token commerce.** It cannot move money.
  It verifies linked bank accounts and balances at the *fiat boundary*:
  business onboarding and token redemption (ACH off-ramp) fail closed in
  `enforce` mode until a bank is linked. Token transfers never touch Plaid.
  Nothing here is financial advice; Plaid figures may lag the bank.
- **No live settlement network.** `rails_ach` builds spec-shaped NACHA CCD
  files (94-char records, blocked in tens, ABA check digits) for redemption;
  submitting them to an ODFI is outside this host. `rails_rtp` is an
  instruction builder + durable outbox with idempotency keys, not a network
  client.
- **TWIN is app-internal.** The redemption rate (`redemption_cents_per_token`,
  default 100 = 1 TWIN → $1.00) is a business policy constant, not a market.
- Balances, the payment journal, and idempotency keys live in ETS (in-memory);
  the WORM chain is the durable record. Restart persistence beyond the WORM
  file is future work.

## API

Base `http://127.0.0.1:8080`. Amounts are integer minor units.

```
POST /v1/agents                         {"handle":"@alice"}
POST /v1/gifts                          {"handle","amount","reason"} + x-treasury-key
POST /v1/transfers                      {"from","to","amount","memo","idempotency_key"[,"rail"]}
GET  /v1/transfers/:id
POST /v1/transfers/:id/reversal         {"reason"}
POST /v1/redemptions                    {"handle","token_amount","routing","bank_account"}
GET  /v1/agents/:handle/balance
GET  /v1/agents/:handle/feed?limit=N
GET  /v1/supply
GET  /v1/conservation                    ledger balance-of-legs + WORM chain verify
GET  /v1/health
```

Example agent flow:

```sh
curl -X POST localhost:8080/v1/agents -d '{"handle":"@alice"}'
curl -X POST localhost:8080/v1/agents -d '{"handle":"@bob"}'
curl -X POST localhost:8080/v1/gifts -H 'x-treasury-key: change-me' \
     -d '{"handle":"@alice","amount":10000,"reason":"onboarding gift"}'
curl -X POST localhost:8080/v1/transfers \
     -d '{"from":"@alice","to":"@bob","amount":2500,"memo":"coffee",
          "idempotency_key":"550e8400-e29b-41d4-a716-446655440000"}'
# same key again -> {"status":"already_processed"}, no double debit
curl -X POST localhost:8080/v1/transfers/pay-<id>/reversal -d '{"reason":"typo"}'
```

## Build, test, run

Requires Erlang/OTP 25 (`erl`, `erlc`), gcc, OpenSSL dev headers.

```sh
make          # builds priv/worm_port (vendored WORM + OpenSSL SHA-256) and ebin/
make test     # 11 self-contained tests, mock Plaid, throwaway WORM file
# run:
erl -noshell -pa ebin -eval 'application:ensure_all_started(twinpay), timer:sleep(infinity).'
```

Tests prove: gifts move supply, unauthorized mint fails, happy-path transfer,
double-submit with one key posts once, insufficient funds fail with no legs,
all legs net to zero, reversal restores balances exactly and refuses a second
reversal, the WORM chain verifies, NACHA records are 94 chars blocked in tens
with valid ABA check digits, RTP keys dedupe, JSON round-trips.

## Configuration (application env, `twinpay`)

`plaid_mode` (`enforce`|`permissive`|`mock`), `treasury_key`,
`treasury_issuers`, `token_scale`, `redemption_cents_per_token`, `http_port`,
`http_bind`, `worm_file`.

## License

MIT — see [LICENSE](LICENSE). Every fresh source file carries an SPDX
header. The vendored finance-twin files (`c_src/worm_block.h`,
`c_src/worm_commit.c`) keep their own original headers, verbatim and
unmodified.

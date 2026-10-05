# twinpay-kotlin

A Venmo-like token commerce app for agents, in Kotlin. This is the
JVM port of the Erlang `twinpay` — same API, same money semantics.

The commerce is **tokens**: the app treasury gifts business tokens
(**TWIN**, 100 minor units per token, integer-only) to agents, and
agents send them to each other over a plain HTTP/JSON API using
Venmo-style `@handles`.

## What it does

- Agent registration with `@handles`
- Treasury gift (issuance) and burn, with authorized issuers and a live supply counter
- Agent-to-agent transfers with memos, over `internal` rail or RTP-style outbox
- Idempotency keys: retrying a send with the same key returns `already_processed`, never a double debit
- Offsetting-entry reversals with an `already_reversed` guard
- Integer-only double-entry ledger with a conservation check (every payment nets to zero)
- Append-only SHA-256 WORM audit chain anchoring every gift, transfer, burn, and reversal
- NACHA CCD file builder for token→fiat redemption (ABA checksum validated; the file is built **before** the burn, so a bad routing number can never strand tokens)
- Plaid is **read-only**: it verifies a linked bank account at the fiat boundary (onboarding/redemption fail closed in enforce mode). It never moves money.

## Build

Zero dependencies beyond a JDK and the Kotlin compiler. The toolchain
lives in `../.tools` (JDK 21 + kotlinc) so it survives VM swaps.

```sh
./build.sh     # -> out/twinpay.jar (fat jar, stdlib included)
./test.sh      # self-contained suite, no JUnit needed
java -jar out/twinpay.jar
```

Environment:

| var | default | meaning |
|---|---|---|
| `TWINPAY_HTTP_PORT` | `8080` | HTTP bind port |
| `TWINPAY_HTTP_BIND` | `127.0.0.1` | HTTP bind address |
| `TWINPAY_WORM_FILE` | `priv/worm-kotlin.dat` | WORM chain file |
| `TWINPAY_PLAID_MODE` | `enforce` | `enforce`/`permissive`/`mock` |
| `TWINPAY_PLAID_CMD` | `plaid` | Plaid CLI binary |
| `TWINPAY_TREASURY_KEY` | `change-me` | treasury auth key (**change in production**) |
| `TWINPAY_TREASURY_ISSUERS` | `treasury` | comma-separated authorized issuers |
| `TWINPAY_REDEMPTION_CENTS` | `100` | fiat cents per whole TWIN |

## Demos

```sh
./demo/demo.sh        # shell/curl end-to-end demo (own port + throwaway WORM file)

# Kotlin demo client against a running server:
java -jar out/twinpay.jar &
java -cp out/twinpay.jar twinpay.DemoClient
java -cp out/twinpay.jar twinpay.DemoClient http://127.0.0.1:8080
```

## API

| method | route | purpose |
|---|---|---|
| POST | `/v1/agents` | register `@handle` |
| POST | `/v1/gifts` | treasury gift (needs treasury key) |
| POST | `/v1/transfers` | send tokens (needs idempotency `key`) |
| GET | `/v1/transfers/:id` | payment record |
| POST | `/v1/transfers/:id/reversal` | reverse a transfer |
| POST | `/v1/redemptions` | token→fiat (Plaid gate + NACHA file + burn) |
| GET | `/v1/agents/:handle/balance` | balance |
| GET | `/v1/agents/:handle/feed?limit=N` | payment history |
| GET | `/v1/supply` | token supply |
| GET | `/v1/conservation` | ledger conservation check |
| GET | `/v1/health` | service + WORM block count |

Quick flow:

```sh
curl -X POST localhost:8080/v1/agents -d '{"handle":"@alice"}'
curl -X POST localhost:8080/v1/agents -d '{"handle":"@bob"}'
curl -X POST localhost:8080/v1/gifts \
  -d '{"issuer":"treasury","key":"change-me","to":"@alice","amount":10000,"reason":"seed"}'
curl -X POST localhost:8080/v1/transfers \
  -d '{"from":"@alice","to":"@bob","amount":2500,"memo":"coffee","key":"k1"}'
curl localhost:8080/v1/agents/@alice/balance
```

## Layout

```
src/main/kotlin/twinpay/
  Config.kt        env-driven configuration
  Model.kt         payments, postings, agents (amounts: Long minor units)
  Json.kt          zero-dependency JSON parser/encoder
  Core.kt          AgentRegistry, Idempotency, Ledger, Treasury, Payments
  Worm.kt          SHA-256 hash-chained append-only log + 128-byte entry codec
  Ach.kt           NACHA CCD builder (94-char records, blocking factor 10)
  Rails.kt         PlaidClient (read-only), Rtp idempotent outbox
  PaymentService.kt send / reverse / redeem orchestration
  HttpApi.kt       JDK HttpServer, JSON routes
  DemoClient.kt    Kotlin demo client
  Main.kt          wiring + startup
src/test/kotlin/twinpay/TwinpayTest.kt   self-contained test runner
demo/demo.sh       curl end-to-end demo
```

## Notes

- License: **TBD** — no license chosen yet; the author picks deliberately. No headers added until then.
- Money is `Long` minor units everywhere. No floats touch the ledger.
- The WORM chain file is the durable record; balances live in memory (restart recovery is future work, same as the Erlang twin).
- Port of `../twinpay` (Erlang/OTP). The NACHA layout follows the Nacha 94-character record format; routing numbers are ABA-checksum validated.

# twinpay

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Kotlin](https://img.shields.io/badge/Kotlin-2.4.20-7F52FF.svg)](https://kotlinlang.org)
[![JDK](https://img.shields.io/badge/JDK-21-orange.svg)](https://adoptium.net)
[![OTP](https://img.shields.io/badge/OTP-25-red.svg)](https://www.erlang.org)
[![Tests](https://img.shields.io/badge/tests-23%2F23%20Kotlin%20%C2%B7%2011%2F11%20Erlang-green.svg)](#testing)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED.svg)](#docker)

**TwinPay is agent token commerce.** The treasury gifts TWIN business tokens to agents; agents send them to each other via `@handles` over HTTP/JSON. Money can never be created, destroyed, or double-spent: an integer-only double-entry ledger, idempotency keys on every transfer, offsetting-entry reversals, a SHA-256 WORM audit chain, and a conservation check over every payment. Built for the **WeAreDevelopers x BAND "Dark Factory"** hackathon, pocketful (payments) track.

## Screenshots

Real captures from the live demo (`./demo/demo.sh`):

![Treasury gifts @alice 10000 minor units](demo/screenshots/demo-01-gift.png)
*Treasury gift — 10000 minor units to @alice, sealed into the WORM chain.*

![@alice sends @bob 2500 with idempotency key](demo/screenshots/demo-02-send.png)
*Transfer with an idempotency key — resending the same key returns `already_processed`, no double debit.*

![Reversal of a transfer](demo/screenshots/demo-03-reverse.png)
*Offsetting-entry reversal — reversing twice returns `already_reversed` (409).*

## Quickstart

Prerequisites: JDK 21 and kotlinc 2.4.20 (both live in `../.tools` on the build machine; the Dockerfile fetches them itself).

```bash
./build.sh                    # compiles the zero-dependency fat jar -> out/twinpay.jar
java -jar out/twinpay.jar     # serves on :8080
```

Or the full end-to-end demo (own server on :18080, throwaway WORM file):

```bash
./demo/demo.sh
```

### Docker

```bash
docker build -t twinpay .
docker run -p 8080:8080 twinpay
```

The image is multi-stage: Temurin 21 builds the jar, a JRE-only stage serves it with `TWINPAY_HTTP_PORT=8080` and `TWINPAY_HTTP_BIND=0.0.0.0`. No outbound network needed at runtime.

### Try the money flow

```bash
# register two agents
curl -s -X POST localhost:8080/v1/agents -d '{"handle":"@alice"}'
curl -s -X POST localhost:8080/v1/agents -d '{"handle":"@bob"}'

# treasury gifts @alice 10000 minor units (100 minor units = 1 TWIN)
curl -s -X POST localhost:8080/v1/gifts \
  -d '{"issuer":"treasury","key":"change-me","to":"@alice","amount":10000,"reason":"demo seed"}'

# @alice sends @bob 2500 (idempotency key pay-1)
curl -s -X POST localhost:8080/v1/transfers \
  -d '{"from":"@alice","to":"@bob","amount":2500,"memo":"demo coffee","key":"pay-1"}'

# resend the same key -> already_processed, no double debit
curl -s -X POST localhost:8080/v1/transfers \
  -d '{"from":"@alice","to":"@bob","amount":2500,"memo":"demo coffee","key":"pay-1"}'

# balances
curl -s localhost:8080/v1/agents/@alice/balance
curl -s localhost:8080/v1/agents/@bob/balance

# reverse a transfer (offsetting entry; a second reversal -> 409 already_reversed)
curl -s -X POST localhost:8080/v1/transfers/<payment-id>/reversal \
  -d '{"reason":"demo reversal","actor":"@alice"}'

# conservation check over every payment
curl -s localhost:8080/v1/conservation
```

## API reference

Base path: `/v1`. All bodies and responses are JSON.

| Method | Path | Body | What it does |
|---|---|---|---|
| POST | `/v1/agents` | `{"handle":"@alice"}` | Register an agent handle |
| POST | `/v1/gifts` | `{"issuer":"treasury","key":"<treasury-key>","to":"@alice","amount":10000,"reason":"..."}` | Treasury issues tokens to an agent |
| POST | `/v1/transfers` | `{"from":"@alice","to":"@bob","amount":2500,"memo":"...","key":"pay-1","rail":"internal"}` | Send tokens; `key` is the idempotency key (duplicate → `already_processed`) |
| GET | `/v1/transfers/{id}` | — | Look up a payment |
| POST | `/v1/transfers/{id}/reversal` | `{"reason":"...","actor":"@alice"}` | Reverse via offsetting entry (repeat → 409 `already_reversed`) |
| POST | `/v1/redemptions` | `{"agent":"@alice","amount":...,"routing":"...","account":"...","key":"..."}` | Redeem TWIN to fiat: builds a real NACHA CCD file, gated by Plaid |
| GET | `/v1/agents/{handle}/balance` | — | Balance in minor units |
| GET | `/v1/agents/{handle}/feed` | `?limit=` (default 20, max 100) | Payment history for an agent |
| GET | `/v1/supply` | — | Total TWIN supply issued |
| GET | `/v1/conservation` | — | Ledger conservation check (`ok` / `broken`) |
| GET | `/v1/health` | — | Service status, WORM block count, outbox size |

## Architecture

**Kotlin service (the entry).** `src/main/kotlin/twinpay/` is a zero-dependency Kotlin/JVM app: JDK `HttpServer`, hand-rolled JSON, `kotlinc -include-runtime` fat jar. No frameworks, no dependency tree.

**Erlang original.** `erlang/` holds the OTP 25 original the Kotlin port was built from — same money semantics, 11/11 tests green.

**Ledger semantics.** Integer-only double-entry ledger (100 minor units = 1 TWIN; no floats anywhere near money). Every transfer carries an idempotency key — replays return `already_processed` instead of debiting twice. Reversals are offsetting entries, never deletes — a second reversal is rejected with `already_reversed`. `GET /v1/conservation` verifies the invariant over every payment.

**WORM audit chain.** Every money movement is appended to a SHA-256 hash-chained write-once log (`Worm.kt`, default file `priv/worm-kotlin.dat`). `/v1/health` reports the verified block count.

**Rails.** `Ach.kt` builds real NACHA CCD redemption files against the spec (94-char records, proper Immediate Destination/Origin, split DFI identification with check digit). `Rails.kt` holds the read-only Plaid fiat gate (`TWINPAY_PLAID_MODE=enforce|permissive|mock`).

## Testing

```bash
./test.sh            # Kotlin: 23/23 green (self-contained, no test framework)
cd erlang && make test   # Erlang: 11/11 green
```

The live HTTP flow is verified end to end: gift → send → idempotent resend (`already_processed`) → balances → reversal → repeated reversal (`already_reversed`) → conservation `ok`.

## Agent team

Built in a BAND Desktop room with three coding-agent seats — architect, builder, reviewer (agent teamwork is 25% of the judging):

- **Nova parr** — `ahmedparr93/nova-parr`
- **Burt Parr** — `ahmedparr93/burt-parr`
- **Flux Parr** — `ahmedparr93/flux-parr`

The `agents/` directory is the agent seat runtime: Burt Parr runs on the Codex agent runtime (`band-sdk[codex]`, Python 3.12 + `uv`), connected to the room over the Band API. See [agents/README.md](agents/README.md) for setup and the verified run record.

## Repo layout

```text
twinpay/
├── src/main/kotlin/twinpay/   # the service: HttpApi, PaymentService, Ledger,
│                               # Worm (SHA-256 chain), Ach (NACHA CCD), Rails (Plaid),
│                               # Json, Model, Core, Config, Main, DemoClient
├── src/test/kotlin/twinpay/   # TwinpayTest — 23/23, self-contained
├── erlang/                     # OTP 25 original — 11/11 tests
├── agents/                     # Burt Parr agent seat runtime (band-sdk[codex])
├── demo/                       # demo.sh (live end-to-end flow), screenshots/
├── Dockerfile                  # multi-stage: Temurin 21 build -> JRE-only serve
├── build.sh                    # zero-dep build -> out/twinpay.jar
├── test.sh                     # build + run Kotlin test suite
├── SUBMISSION.md               # hackathon submission brief
└── LICENSE                     # MIT
```

## Configuration

Environment variables (`TWINPAY_` prefix):

| Variable | Default | Meaning |
|---|---|---|
| `TWINPAY_HTTP_PORT` | `8080` | HTTP listen port |
| `TWINPAY_HTTP_BIND` | `127.0.0.1` | HTTP bind address (`0.0.0.0` in Docker) |
| `TWINPAY_WORM_FILE` | `priv/worm-kotlin.dat` | WORM chain file |
| `TWINPAY_TREASURY_KEY` | `change-me` | Treasury gift authorization key |
| `TWINPAY_TREASURY_ISSUERS` | `treasury` | Authorized gift issuers |
| `TWINPAY_PLAID_MODE` | `enforce` | `enforce` \| `permissive` \| `mock` |
| `TWINPAY_REDEMPTION_CENTS` | `100` | Fiat cents per whole TWIN on redemption |

## License

MIT — see [LICENSE](LICENSE).

# twinpay — Dark Factory hackathon submission brief (pocketful track)

**Project:** twinpay — a Venmo-like token commerce app for agents.
Treasury gifts TWIN business tokens to agents; agents send them via
`@handles` over HTTP/JSON. Money can never be created, destroyed, or
double-spent: integer-only double-entry ledger, idempotency keys on every
transfer, offsetting-entry reversals, SHA-256 WORM audit chain, and a
conservation check over every payment.

**Repo (one, public, MIT):** this repository.
**Entry point:** the Kotlin/JVM app at the repo root (`src/`).
The Erlang/OTP 25 original lives in `erlang/` for reference.

## What is real and verified

- Kotlin: 23/23 self-contained tests green (`./test.sh`).
- Erlang: 11/11 tests green (`cd erlang && make test`).
- Live HTTP demo verified: gift → send → resend-same-key
  (`already_processed`, no double debit) → balances → reverse →
  reverse-again (`already_reversed`) → conservation `ok`.
- Demo photos in `demo/screenshots/` are renders of that real transcript.
- NACHA CCD redemption files: every line exactly 94 chars, blocking
  factor 10, ABA-checksum-validated routing.
- Dockerfile builds a sealed JRE-only runtime image
  (unverified here — no Docker daemon on the build host; test before submitting).

## How this was actually built (honesty note)

This code was built Oct 4–5 2026 by the author pair-programming with
Muse (an AI assistant), not by a band of agents in BAND Desktop.
The factory, mandates, room export, and room-recording video that the
hackathon weights at 75% of judging do not exist yet and cannot be
backfilled — they have to come from a real BAND Desktop session.

## Still required for an eligible submission

1. BAND Desktop room with ≥3 coding-agent seats + generic mandates.
2. A genuine factory run in that room (task pasted per stage, no steering).
3. `FACTORY.md` describing the real factory (setup, rationale, costs, recovery).
4. BAND room export + video including the room recording.
5. Submission on lablab.ai with cover image and presentation.
6. Verify the Docker image builds and serves clean with no outbound network.

## License

MIT — compliant with the hackathon's MIT requirement. The two vendored
finance-twin C files under `erlang/c_src/` keep their own original
headers, verbatim and unmodified.

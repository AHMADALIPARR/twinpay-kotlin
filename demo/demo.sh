#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Ahmad Parr
# twinpay-kotlin end-to-end demo: register -> gift -> send -> idempotent
# resend -> balances -> reverse -> double-reverse guard -> conservation.
# Starts its own server on a demo port with a throwaway WORM file.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$HERE/../.tools"
JDKDIR="$(ls -d "$TOOLS"/jdk-21* 2>/dev/null | head -1)"
export JAVA_HOME="$JDKDIR"
export PATH="$JDKDIR/bin:$PATH"

PORT=18080
WORM="$(mktemp -d)/worm-demo.dat"
export TWINPAY_HTTP_PORT=$PORT
export TWINPAY_WORM_FILE="$WORM"
export TWINPAY_PLAID_MODE=permissive

"$HERE/build.sh" >/dev/null
java -jar "$HERE/out/twinpay.jar" >/tmp/twinpay-demo.log 2>&1 &
SRV=$!
trap "kill $SRV 2>/dev/null; rm -rf $(dirname "$WORM")" EXIT

for i in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 && break
  sleep 0.2
done

say() { echo; echo "== $1"; }
post() { curl -s -X POST "http://127.0.0.1:$PORT$1" -d "$2"; echo; }
get()  { curl -s "http://127.0.0.1:$PORT$1"; echo; }

say "register @alice and @bob"
post /v1/agents '{"handle":"@alice"}'
post /v1/agents '{"handle":"@bob"}'

say "treasury gifts @alice 10000 minor units"
post /v1/gifts '{"issuer":"treasury","key":"change-me","to":"@alice","amount":10000,"reason":"demo seed"}'

say "@alice sends @bob 2500 (key pay-1)"
post /v1/transfers '{"from":"@alice","to":"@bob","amount":2500,"memo":"demo coffee","key":"pay-1"}'

say "resend same key -> already_processed, no double debit"
post /v1/transfers '{"from":"@alice","to":"@bob","amount":2500,"memo":"demo coffee","key":"pay-1"}'

say "balances"
get /v1/agents/@alice/balance
get /v1/agents/@bob/balance

PAYID=$(post /v1/transfers '{"from":"@alice","to":"@bob","amount":100,"memo":"probe","key":"pay-2"}' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

say "reverse $PAYID"
post "/v1/transfers/$PAYID/reversal" '{"reason":"demo reversal","actor":"@alice"}'

say "reverse again -> already_reversed"
post "/v1/transfers/$PAYID/reversal" '{"reason":"demo reversal","actor":"@alice"}'

say "conservation + health"
get /v1/conservation
get /v1/health
echo
echo "demo complete"

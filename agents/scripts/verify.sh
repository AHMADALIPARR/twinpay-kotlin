#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
: "${BAND_USER_API_KEY:?Supply BAND_USER_API_KEY in the environment for this check only.}"
export VERIFY_AGENT_ID=${VERIFY_AGENT_ID:-088819fc-a27b-4a1a-a54f-fb244d34c98e}
export VERIFY_AGENT_NAME=${VERIFY_AGENT_NAME:-Burt Parr}
VERIFY_FILE=$(mktemp)
trap 'rm "$VERIFY_FILE"' EXIT
curl -fsSL https://raw.githubusercontent.com/band-ai/add-band/main/scripts/verify_agent_reply.py -o "$VERIFY_FILE"
uv run --locked python "$VERIFY_FILE"

# TwinPay

TwinPay's Band hackathon workspace. The current implementation runs **Burt Parr**,
a Codex engineering agent connected to Band. Product requirements and application
code can be added as the team defines them.

```text
src/twinpay_agents/   Agent runtime, settings, and role prompt
scripts/             Start, stop, status, logs, and real-reply verification
docs/                Architecture and verified run records
.env.example         Safe configuration template
pyproject.toml       Package and dependency definitions
uv.lock              Reproducible dependency versions
```

## Setup

Requires Python 3.12, uv, and an authenticated Codex CLI.

```bash
cp .env.example .env
# Fill BURT_API_KEY in .env with the agent-scoped Band key.
codex login
uv sync --locked
```

Exported variables take precedence over `.env`. Never put the Band **user** key in
`.env`; it is needed only temporarily for the verification script.

## Run

```bash
bash scripts/agent.sh start
bash scripts/agent.sh status
bash scripts/agent.sh logs
bash scripts/agent.sh stop
```

For foreground logs, use `uv run --locked twinpay-agent` instead of `start`.
Run only one process for this agent ID. In Band, mention **@Burt Parr** in a room
where it is a participant.

## Verify a reply

With `BAND_USER_API_KEY` temporarily supplied in your shell environment:

```bash
bash scripts/verify.sh
unset BAND_USER_API_KEY
```

The upstream checker creates a temporary room, sends a unique test mention,
waits for a real answer, and deletes the room. A connected WebSocket alone is
insufficient to verify the agent.

See [the run record](docs/runs/2026-10-06.md) and [architecture](docs/architecture.md).

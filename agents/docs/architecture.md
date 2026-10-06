# Current architecture

```text
Band room @mention
       ↓
Band SDK: room subscription, history, message lifecycle
       ↓
Codex adapter → authenticated Codex CLI → model and Band tools
       ↓
Reply posted to the Band room
```

`config.py` loads agent-scoped credentials from exported variables or the root
`.env`. `prompts.py` defines Burt's TwinPay role. `agent.py` creates the adapter and
runs the Band lifecycle. The SDK owns room workspaces and reconnect behavior.

Local runtime files go in ignored `.runtime/` and `.band-workspaces/` directories.
The default Band production endpoints are used unless overridden.

The first run exposed two host prerequisites: Codex must be able to write its
runtime state, and its ChatGPT login must remain valid. In this managed workspace,
the process requires network access and write access to its configured Codex home
at `/run/codex-environment/codex-home`. Login status alone does not establish that
the access token works; verify a real reply after startup or authentication changes.

Tom and Jerry were set up separately in the Claude workspace. Their files and
credentials are not available here and are not represented as locally running agents.

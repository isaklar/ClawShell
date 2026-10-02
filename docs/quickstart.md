# Quickstart

How to install ClawShell once, and the three ways to run a pentest.

**The core rule:** ClawShell only reads your target code and writes one markdown
report. The target is mounted read-only, so the filesystem itself rejects any
write to it. The only writable output is the report under `workspaces/reports/`.

**Scope:** ClawShell analyzes **source code**, it does not do live/dynamic web
testing (DAST). If a spec only lists URLs/hosts to probe with no code, that is
out of scope: provide the source instead, and the team will map those endpoints
to the code and analyze them there.

---

## Part 1, Install (one time)

### 1. Get the code onto the box

```bash
git clone <your-clawshell-repo> /opt/clawshell-src
cd /opt/clawshell-src
```

### 2. Install the GPU driver yourself

ClawShell does not install the GPU driver. Do this first:

- NVIDIA box: install the NVIDIA driver (`nvidia-smi` must work).
- AMD box: install amdgpu + ROCm (`rocm-smi` must work).

No GPU? You can run on a hosted AI provider instead, see `docs/credentials.md`.

### 3. Make your config

```bash
cp .env.example .env
```

Edit `.env`:

- NVIDIA (default): leave the model settings as-is. Set `LAN_ALLOW_CIDR` to your
  real subnet (e.g. `192.168.1.0/24`).
- AMD desktop: set these plus `LAN_ALLOW_CIDR`:
  ```
  MODEL_PROVIDER=local-gpu
  LOCAL_LLM_BACKEND=amd-rocm
  LOCAL_LLM_MODEL=qwen2.5-coder:14b
  ```

See [gpu.md](gpu.md) for model/VRAM guidance (a smaller card, say 24 GB, should
use a smaller model like `qwen2.5-coder:14b` rather than the larger default).

### 4. Stage the model once

The model server has no internet access, so pre-download the model into its
cache first.

- AMD:
  ```bash
  docker run --rm -v "$PWD/state/local-llm-amd:/root/.ollama" \
    ollama/ollama sh -lc 'ollama serve & sleep 3; ollama pull qwen2.5-coder:14b'
  ```
- NVIDIA: pre-populate `state/local-llm` with the Hugging Face weights for
  `LOCAL_LLM_MODEL` (see `docs/gpu.md`).

### 5. Run the installer

```bash
sudo ./scripts/install.sh
```

It sets up Docker, the firewall, the sandbox, the four-agent team, and starts
everything. It auto-generates the Gateway token (saved to `secrets/gateway_token`).
When it finishes it prints the command to point the AI at your model:

```bash
# AMD
docker compose -f compose/compose.yml exec openclaw-gateway \
  openclaw models set ollama/qwen2.5-coder:14b
# NVIDIA
docker compose -f compose/compose.yml exec openclaw-gateway \
  openclaw models set local/clawshell-local
```

The platform is now running and waiting for work.

---

## Part 2, Run a pentest

Every engagement gives the team a requirement spec (what to test, rules of
engagement, report format) plus the target code. The team reads the code against
the spec and writes one markdown report. The three ways below all do the same
thing, pick whichever is convenient.

The team: the Lead Pentester (`main`) is your single point of contact; it plans
the job and delegates to `recon` (maps the code), `exploit` (confirms findings
statically, no live attacks), and `reporter` (writes the report). All four share
the one on-box model.

### Way A, Conversational

1. Open the OpenClaw Control UI in a browser: `http://<box-ip>:18789`.
2. In the chat, attach your requirement spec (PDF, Markdown, or text).
3. Put the target code in the `engagement/target/` folder (mounted read-only).
4. Tell the Lead Pentester: "Analyze the code in `engagement/target/` against the
   attached spec and write your findings to `reports/report.md`."

### Way B, Headless (one command; good for CI/cron)

```bash
./scripts/pentest-task.sh \
  --spec ./my-requirement-spec.md \
  --target git@github.com:client/their-app.git
```

It stages the spec and target, runs the team, and writes the report to
`workspaces/reports/<task-id>.md`. Run `./scripts/pentest-task.sh --help` for
`--branch`, `--agent`, `--max-runtime`, and the other options.

### Way C, API, from another computer on the same network

The Gateway exposes an OpenAI-compatible HTTP API on port `18789`, so any machine
on your LAN can start an engagement. Two things gate access:

- Network: the port is firewalled to `LAN_ALLOW_CIDR` (set in `.env`), so only
  your subnet can reach it.
- Auth: every request needs the Gateway token as a bearer header. Read it on the
  box:
  ```bash
  cat /opt/clawshell-src/secrets/gateway_token
  ```

You address an agent as the model `openclaw/<agentId>`, use `openclaw/main` for
the Lead Pentester. Stage the target into `engagement/target/` (and the spec into
`engagement/spec/`, or paste the spec text into the message), then from the other
computer:

```bash
curl -sS http://<box-ip>:18789/v1/chat/completions \
  -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openclaw/main",
    "messages": [
      { "role": "user",
        "content": "Analyze the code in engagement/target/ against the spec in engagement/spec/ and write your findings to reports/report.md. Read-only: do not modify the target." }
    ]
  }'
```

Notes:

- List the available agents with
  `curl -H "Authorization: Bearer $GATEWAY_TOKEN" http://<box-ip>:18789/v1/models`
  (returns `openclaw/main`, `openclaw/recon`, `openclaw/exploit`,
  `openclaw/reporter`).
- An engagement can run for a while; the call returns the Lead Pentester's reply
  when the turn completes (add `"stream": true` to watch progress). The report
  lands in `workspaces/reports/` either way.
- Because it is OpenAI-compatible, you can also point existing chat UIs (Open
  WebUI, LibreChat) at `http://<box-ip>:18789/v1` with the token.

### What you get back

A single markdown report containing findings mapped to the requirement spec with
severity, evidence from static analysis (nothing is attacked, run, or changed),
and suggested fixes as code snippets (examples only, never applied to your code).
Read it under `workspaces/reports/`.

---

More detail: `docs/gpu.md` (GPU/model), `docs/credentials.md` (secrets),
`docs/pentest-team.md` (the agents), `docs/networking.md` (firewall/ports),
`docs/architecture.md` (the full picture).

---

## See also

* [Main README](../README.md): project overview and documentation map
* [Architecture](architecture.md): trust boundaries, decisions, the diagram
* [GPU](gpu.md): on-box inference (NVIDIA/vLLM, AMD/ROCm), model/VRAM guidance
* [Pentest team](pentest-team.md): the 4 agents, delegation, per-agent models
* [Security](security.md): host hardening, credentials, full threat model
* [Networking](networking.md): Docker topology, egress allowlist, nftables
* [Black-box live testing](blackbox-live-testing.md): scoped egress, target-gateway, approval flow
* [Quota protection](quota-protection.md): circuit breaker, per-task limits
* [Caveman integration](caveman-integration.md): token-reduction skill and proxy
* [Credentials](credentials.md): the model-provider decision
* [Operations](operations.md): install/update/backup/restore/uninstall
* [Testing](testing.md): the regression suite (static, unit, live, manual)
* [Roadmap](roadmap.md): planned, not-yet-built work

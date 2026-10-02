# GPU inference (the default brain)

ClawShell's default provider, `MODEL_PROVIDER=local-gpu`, runs the model
**entirely on the box** so that engagement data, the target code, the
requirement spec, and the findings, never leaves the machine for a third-party
provider. This page covers the hardware, host prerequisites, how the `local-llm`
service works, the tuning knobs, model/VRAM guidance, verification, and how to
switch to a hosted provider instead.

If you don't want local inference at all (e.g. a laptop with no supported GPU),
set `MODEL_PROVIDER` to a hosted provider, see `docs/credentials.md`, and none
of this applies.

## Choosing a backend (`LOCAL_LLM_BACKEND`)

`local-gpu` supports two on-box GPU backends, selected by `LOCAL_LLM_BACKEND`
in `.env`:

| Backend | `LOCAL_LLM_BACKEND` | Engine | Compose service / profile | OpenClaw provider | GPU access |
|---|---|---|---|---|---|
| **NVIDIA** (default) | `nvidia` | vLLM | `local-llm` / `local-gpu` | `local` (OpenAI `/v1`) | NVIDIA Container Toolkit |
| **AMD / ROCm** | `amd-rocm` | Ollama (ROCm) | `local-llm-amd` / `local-gpu-amd` | `ollama` (native `/api`, **no `/v1`**) | `/dev/kfd` + `/dev/dri` passthrough |

Everything else (the hardened cage, the read-only target mount, the 4-agent
team, the `reports/` output) is identical between backends, only the model
server differs. The sections below cover NVIDIA first, then the AMD backend.

## Target hardware

Designed and tuned for a single **NVIDIA RTX 6000 Ada Generation, 96 GB
VRAM**. Anything with comparable or larger VRAM works; smaller cards work too if
you pick a smaller model and/or a shorter context (see
[Model & VRAM guidance](#model--vram-guidance)). For **AMD** cards see
[AMD GPU (ROCm) backend](#amd-gpu-rocm-backend).

## Host prerequisites

1. A recent **NVIDIA driver** for your card (so `nvidia-smi` works on the host).
2. The **NVIDIA Container Toolkit** (the `nvidia` container runtime), so Docker
   can expose the GPU to a container.

`scripts/install.sh` **auto-installs the NVIDIA Container Toolkit** when
`MODEL_PROVIDER=local-gpu` and `LOCAL_LLM_BACKEND=nvidia` (Phase 2) on supported
Ubuntu/Debian hosts. The GPU driver itself is not installed by ClawShell, install the vendor driver first. Verify the host sees the GPU before deploying:

```bash
nvidia-smi
```

## How the `local-llm` service works

The `local-llm` service (`compose/compose.yml`, container
`clawshell-local-llm`) runs **vLLM** (`vllm/vllm-openai:v0.30.0`) and serves an
**OpenAI-compatible API** at `http://local-llm:8000/v1`.

- **Network isolation.** It is attached **only** to the internal
  `clawshell-inference` network, with **no `ports:`**, it is reachable solely
  by `openclaw-gateway`, never published to the host or LAN, and has no internet
  route. Because tokens are local, it is **not** proxied through quota-guard
  (there is no external spend to circuit-break; per-task `MAX_*` ceilings still
  bound GPU time).
- **Profile-gated.** It is behind the `local-gpu` Compose profile and only
  started when `MODEL_PROVIDER=local-gpu`, so a host without an NVIDIA GPU never
  has to pull or run it.
- **GPU reservation.** `deploy.resources.reservations.devices` reserves the
  NVIDIA GPU(s) (`driver: nvidia`, `count: all`, `capabilities: [gpu]`), which
  requires the NVIDIA Container Toolkit.
- **Weight cache.** The model cache is persisted on the host at
  `state/local-llm` (mounted to `/root/.cache/huggingface`), so a restart does
  not re-download the model.
- **Healthcheck.** Polls vLLM's `/health` with a 300s `start_period` to allow
  for first-time weight download + load.
- **Privacy.** `DO_NOT_TRACK=1`, and `HF_HUB_OFFLINE` can forbid any runtime
  download (see below).

OpenClaw reaches it as the `local` provider; `config/openclaw.json5.example`
points that provider's `baseUrl` at `LOCAL_LLM_BASE_URL`. vLLM ignores the API
key, but OpenClaw requires one to be present, so a fixed dummy value
(`clawshell-local`) is used, you manage no secret.

## Configuration knobs (`.env`)

All non-secret, all read by the `local-llm` service:

| Variable | Default | What it does |
|----------|---------|--------------|
| `LOCAL_LLM_IMAGE` | `vllm/vllm-openai:v0.30.0` | Inference server image (OpenAI-compatible); pin to a tag matching your CUDA/driver, not `latest` |
| `LOCAL_LLM_MODEL` | `Qwen/Qwen2.5-Coder-32B-Instruct` | HF model id, or a path under `state/local-llm` |
| `LOCAL_LLM_SERVED_NAME` | `clawshell-local` | The served model id clients address |
| `LOCAL_LLM_BASE_URL` | `http://local-llm:8000/v1` | Internal URL the Gateway calls |
| `LOCAL_LLM_MAX_MODEL_LEN` | `32768` | Max context length (prompt + output) |
| `LOCAL_LLM_GPU_MEM_UTIL` | `0.92` | Fraction of VRAM vLLM may use |
| `HUGGING_FACE_HUB_TOKEN` | *(blank)* | Only for gated/private HF models |
| `HF_HUB_OFFLINE` | `0` | Set `1` once weights are cached to forbid any runtime download (air-gapped) |

After changing any of these, re-sync and restart the service (or re-run
`scripts/update.sh`):

```bash
docker compose --env-file .env -f compose/compose.yml --profile local-gpu up -d local-llm
```

## Model & VRAM guidance

With **96 GB** of VRAM you have a lot of headroom:

- **Default, `Qwen/Qwen2.5-Coder-32B-Instruct`.** A strong code-analysis model
  that fits comfortably at full precision, leaving plenty of room for a large
  KV cache (long context over big codebases). A good default for pentest review.
- **Larger / longer context.** You can raise `LOCAL_LLM_MAX_MODEL_LEN` (e.g.
  65536+) to fit bigger specs and more files in one pass, as long as VRAM holds.
  Model + KV-cache both consume VRAM; if load fails for OOM, lower
  `LOCAL_LLM_MAX_MODEL_LEN` first, then `LOCAL_LLM_GPU_MEM_UTIL`.
- **Even bigger models.** 70B-class models or quantized larger models also fit
  on 96 GB; set `LOCAL_LLM_MODEL` to its HF id. Match any model-specific vLLM
  flags if required (edit the `command:` in `compose.yml`).
- **Smaller cards.** On less VRAM, choose a smaller model (e.g. a 7B/14B coder)
  and reduce `LOCAL_LLM_MAX_MODEL_LEN`.

`LOCAL_LLM_GPU_MEM_UTIL=0.92` deliberately leaves a little VRAM free for
stability; raise cautiously, lower if you see out-of-memory at load.

## Gated or private models

Public models (including the default) need no token. For a **gated or private**
Hugging Face model, set `HUGGING_FACE_HUB_TOKEN` in `.env`; it is passed to the
`local-llm` service only to authenticate the download. Once weights are cached
under `state/local-llm`, set `HF_HUB_OFFLINE=1` to forbid all further network
access for fully air-gapped inference.

## Verifying it works

```bash
# Host sees the GPU
nvidia-smi

# Service is up and healthy
docker compose -f compose/compose.yml ps local-llm

# The model answers (from the Gateway, which shares the internal network)
docker compose -f compose/compose.yml exec openclaw-gateway \
  curl -s http://local-llm:8000/v1/models

# OpenClaw is pointed at the local model
docker compose -f compose/compose.yml exec openclaw-gateway \
  openclaw models set local/clawshell-local
```

First startup downloads the weights, so the service can take several minutes to
pass its healthcheck (hence the 300s `start_period`). Watch progress with
`docker compose -f compose/compose.yml logs -f local-llm`.

## AMD GPU (ROCm) backend

Set `LOCAL_LLM_BACKEND=amd-rocm` to run on an **AMD Radeon** card (developed
against an **RX 7900 XTX, 24 GB**). This swaps the vLLM `local-llm` service for
the **`local-llm-amd`** service, which runs **Ollama's ROCm build** and serves
models on the AMD GPU via ROCm/HIP, no CUDA, no NVIDIA Container Toolkit.

### How it differs from NVIDIA

- **Native Ollama API, not `/v1`.** OpenClaw talks to Ollama's native
  `/api/chat` endpoint via its first-class `ollama` provider (defined in
  `config/openclaw.json5.example`, `baseUrl: http://local-llm-amd:11434` with
  **no `/v1`**). The OpenAI-compatible `/v1` shim is deliberately avoided, it
  **breaks tool calling**, which every agent depends on.
- **Model is an Ollama tag, not an HF id.** Set `LOCAL_LLM_MODEL` to a tag like
  `qwen2.5-coder:14b`. The service pulls it on first start (persisted in
  `state/local-llm-amd`) and OpenClaw addresses it as `ollama/<tag>`.
- **GPU via device passthrough.** The container gets `/dev/kfd` + `/dev/dri`
  and joins the host's `video`/`render` groups, the ROCm equivalent of the
  NVIDIA device reservation. No toolkit install; `install.sh` just sanity-checks
  the devices.
- **vLLM-only knobs are ignored** (`LOCAL_LLM_IMAGE`, `LOCAL_LLM_SERVED_NAME`,
  `LOCAL_LLM_BASE_URL`, `LOCAL_LLM_MAX_MODEL_LEN`, `LOCAL_LLM_GPU_MEM_UTIL`).

### Host prerequisites (AMD)

1. The **amdgpu** kernel driver + **ROCm** so `/dev/kfd` and `/dev/dri` exist
   (`rocminfo` / `rocm-smi` work on the host).
2. Your user able to access the render nodes (the container uses `group_add:
   [video, render]`).

### Model & VRAM guidance (24 GB, e.g. RX 7900 XTX)

Ollama serves **quantized GGUF** by default, so pick a tag that fits 24 GB:

| Tag | Approx. VRAM (Q4) | Notes |
|---|---|---|
| `qwen2.5-coder:7b` | ~6 GB | Fast fallback |
| `qwen2.5-coder:14b` | ~9 GB | **Recommended default** for 24 GB, comfortable headroom for context |
| `qwen2.5-coder:32b` | ~20 GB | Tight but usually fits; less room for long context |

The 96 GB NVIDIA default (`Qwen/Qwen2.5-Coder-32B-Instruct` at full precision)
will **not** fit 24 GB, use one of the quantized tags above. All 4 agents still
share this one model (see `docs/pentest-team.md`).

### Enabling it

```bash
# in .env
MODEL_PROVIDER=local-gpu
LOCAL_LLM_BACKEND=amd-rocm
LOCAL_LLM_MODEL=qwen2.5-coder:14b
```

Then run `scripts/install.sh` (or `scripts/update.sh` on an existing box) and
point OpenClaw at the model:

```bash
docker compose -f compose/compose.yml exec openclaw-gateway \
  openclaw models set ollama/qwen2.5-coder:14b
```

### Verifying (AMD)

```bash
# Host sees the AMD GPU
rocm-smi

# Service up + model present
docker compose -f compose/compose.yml --profile local-gpu-amd ps local-llm-amd
docker compose -f compose/compose.yml exec local-llm-amd ollama list

# Watch first-pull progress
docker compose -f compose/compose.yml --profile local-gpu-amd logs -f local-llm-amd
```

### Troubleshooting (AMD)

- **"no compatible GPUs"**, some cards need an LLVM-target override. Set
  `HSA_OVERRIDE_GFX_VERSION` in `.env` (e.g. `11.0.0`). The 7900 XTX (gfx1100)
  is natively supported and usually needs nothing.
- **Permission denied on `/dev/dri/renderD*`**, the container's `group_add`
  names (`video`, `render`) must match host groups. If they don't resolve,
  replace them in `compose/compose.yml` with the **numeric** GIDs from
  `getent group render` / `getent group video` on the host.

### Pre-staging the model (the inference network has no egress)

The `clawshell-inference` network is `internal: true`, the model container has
**no internet route** (so engagement data can't leave). That means the model
must be present in `state/local-llm-amd` **before** the service can serve it; the
in-container `ollama pull` only succeeds if the weights are already cached. Pull
once, host-side, into the persistent volume using a throwaway container that
*does* have network access:

```bash
docker run --rm -v "$PWD/state/local-llm-amd:/root/.ollama" \
  ollama/ollama sh -lc 'ollama serve & sleep 3; ollama pull qwen2.5-coder:14b'
```

(The NVIDIA/vLLM backend has the same constraint, pre-populate
`state/local-llm` with the Hugging Face weights.) Once staged, the
`local-llm-amd` service loads from the volume on every start.

## Switching to a hosted provider instead

Set `MODEL_PROVIDER` to `github-copilot`, `anthropic`, `openai`, or `custom`,
provide the relevant credential, and uncomment the matching host in
`config/allowlist.conf`, full details in `docs/credentials.md`. In that mode
neither GPU profile is started, so no model server runs and no GPU runtime
(NVIDIA toolkit or ROCm) is required.

---

## See also

* [Main README](../README.md): project overview and documentation map
* [Quickstart](quickstart.md): install once, then the three ways to run a pentest
* [Architecture](architecture.md): trust boundaries, decisions, the diagram
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

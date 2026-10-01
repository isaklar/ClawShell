# Credentials, what (if anything) you need to provide

**Most ClawShell setups need no credentials at all.** The default provider runs
the model entirely on the on-box GPU, and a local target path needs no account.
This page explains the one default (zero-credential) path, the optional hosted
providers, the optional GitHub token for private git targets, and how every
secret is stored.

## TL;DR

| Secret | When you need it | Where it lives |
|--------|------------------|----------------|
| *(none)* | `MODEL_PROVIDER=local-gpu` + a local `--target` path (the default) |, |
| `MODEL_PROVIDER_API_KEY` | only if you switch to a **hosted** provider (anthropic/openai/custom) | Docker secret `secrets/model_provider_api_key` |
| `COPILOT_GITHUB_TOKEN` | only for headless `github-copilot` auth | OpenClaw's internal token store (`state/openclaw`) |
| `GITHUB_AGENT_TOKEN` | only to clone a **private** git `--target` | Docker secret `secrets/github_agent_token` |
| `HUGGING_FACE_HUB_TOKEN` | only to pull a **gated/private** model from Hugging Face | `.env` → passed to the `local-llm` service |
| `OPENCLAW_GATEWAY_TOKEN` | always (auth for the Control UI/API) | **auto-generated** by `install.sh` |

Secrets are **never** stored in `config/openclaw.json5` (which is mounted
read-only) and, except where noted, never in `.env` beyond install time, they
live in `secrets/` as Docker secrets or inside OpenClaw's protected state
volume.

---

## 1. `MODEL_PROVIDER=local-gpu` (default, on-box GPU, no credentials)

This is the headline mode. Inference runs **entirely on this machine** on the
NVIDIA RTX 6000 Ada 96 GB GPU via the `local-llm` vLLM service, which exposes an
OpenAI-compatible API on the internal `clawshell-inference` network. The
engagement data, target code, requirement spec, findings, **never leaves the
box** for a third-party provider.

- **No API key.** vLLM ignores the API key, but OpenClaw still requires a value
  to be present, so `config/openclaw.json5.example` uses a fixed dummy value
  (`clawshell-local`). You do not set or manage anything.
- **No external account, no allowlist host.** `config/allowlist.conf` keeps
  **zero** external model-provider hosts active in this mode, there's nothing
  to reach.
- **No GitHub login** for the model.

The only knobs are the (non-secret) `LOCAL_LLM_*` variables in `.env` that pick
the model and tune VRAM/context, see **`docs/gpu.md`** for the full setup,
model selection, and verification steps.

`HUGGING_FACE_HUB_TOKEN` is only needed if you choose a **gated or private**
Hugging Face model. The default `Qwen/Qwen2.5-Coder-32B-Instruct` is public, so
you can leave it blank. When set, it is passed to the `local-llm` service at
pull time only. (The **AMD/ROCm** backend, `LOCAL_LLM_BACKEND=amd-rocm`, pulls
models from Ollama and needs no token at all, see `docs/gpu.md`.)

---

The options below are only relevant if you deliberately switch `MODEL_PROVIDER`
away from `local-gpu`, for example to run on a host without the GPU, or to
A/B a hosted model. ClawShell runs on **any** of these; local-gpu is simply the
default.

## 2. `MODEL_PROVIDER=github-copilot` (existing Copilot subscription)

OpenClaw's built-in provider (`docs.openclaw.ai/providers/github-copilot`)
authenticates as *you* using your normal Copilot entitlement, no separate API
key.

* **Interactive device-login (default, one manual step)**, leave
  `COPILOT_GITHUB_TOKEN` blank. If no Copilot auth profile exists yet,
  `install.sh` prints the exact command and stops. Run it once:

  ```bash
  docker compose -f compose/compose.yml exec openclaw-gateway \
    openclaw models auth login-github-copilot
  ```

  Then set a default model (use a model id your plan exposes):

  ```bash
  docker compose -f compose/compose.yml exec openclaw-gateway \
    openclaw models set github-copilot/claude-opus-4.6
  ```

* **Headless**, set `COPILOT_GITHUB_TOKEN` in `.env` to a GitHub OAuth access
  token with Copilot access; `install.sh` completes onboarding non-interactively.
  The token is read once at install time and retained only in OpenClaw's
  internal token store under the `state/openclaw` volume, not copied into a
  separate secrets file or any image.

**Network:** uncomment `*.githubcopilot.com:443` in `config/allowlist.conf`
(inference), `github.com`/`api.github.com` are already allowlisted.

## 3. `MODEL_PROVIDER=anthropic` or `openai` (standalone API key)

Set `MODEL_PROVIDER=anthropic` (or `openai`) and put the key in
`secrets/model_provider_api_key` (install reads `MODEL_PROVIDER_API_KEY` from
`.env` once and writes it there as a Docker secret). Uncomment the matching
host (`api.anthropic.com:443` / `api.openai.com:443`) in
`config/allowlist.conf`. These are also the providers the caveman-proxy
integration targets most directly (`docs/caveman-integration.md`).

## 4. `MODEL_PROVIDER=custom` (any OpenAI-compatible endpoint)

For a self-hosted or third-party OpenAI-API-compatible endpoint. Set
`MODEL_PROVIDER_BASE_URL` and `MODEL_PROVIDER_API_KEY`; see
`config/openclaw.json5.example` for the `models.providers` block. (This is also
what the optional caveman input-token proxy requires, it only supports
`custom`.)

---

## GitHub credentials (optional, private git targets only)

If you point `--target` at a **private** GitHub repository, ClawShell clones it
host-side using a dedicated bot identity:

- `GITHUB_AGENT_USERNAME` / `GITHUB_AGENT_TOKEN`, the bot identity + a
  **read-only** fine-grained PAT or GitHub App token (see
  `github/PROVISIONING.md`). The token is stored as the Docker secret
  `secrets/github_agent_token`.
- `GITHUB_ALLOWED_REPOS`, a comma-separated `owner/repo` allowlist that
  quota-guard **enforces** on clone/fetch (see
  `docs/networking.md#github-repo-scope-enforcement`).

For **local** `--target` paths and the default local-gpu provider, no GitHub
credential is involved at all, leave all of these blank.

ClawShell is read-only and **never pushes, branches, or opens PRs**, so the
token only ever needs read scope.

---

## How secrets are stored

- **Docker secrets** (`secrets/`, mode `0700`, owned by the `clawshell` user):
  `gateway_token`, `model_provider_api_key`, `github_agent_token`. Mounted into
  containers at `/run/secrets/*`, never
  baked into images, never in `config/openclaw.json5`.
- **OpenClaw internal token store** (inside the `state/openclaw` volume): holds
  the Copilot OAuth reference after device-login / headless onboarding.
- **`.env`**: holds non-secret config plus, at most, *install-time-only* inputs
  (`COPILOT_GITHUB_TOKEN`, `HUGGING_FACE_HUB_TOKEN`) that are consumed during
  install and not re-read at runtime. Keep `.env` out of version control (it is
  `.gitignore`d).

Whatever you choose, keep at most **one** external model-provider host active in
`config/allowlist.conf`, resist allowlisting every provider "just in case";
that widens the SSRF/exfiltration surface for no benefit. Under the default
`local-gpu`, keep **zero** active (inference is on-box).

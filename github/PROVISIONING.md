# GitHub credential provisioning

The agent needs its own GitHub identity, never your personal token, never an
admin-scoped token.

## Option A, Fine-grained personal access token (simplest)

1. Create (or reuse) a dedicated bot GitHub account, e.g. `yourorg-agent-bot`,
   or use a fine-grained PAT scoped to specific repos under your own account
   if a separate bot account isn't practical for you.
2. GitHub → Settings → Developer settings → Fine-grained tokens → Generate new.
3. **Repository access**: "Only select repositories", pick exactly the repos
   in `GITHUB_ALLOWED_REPOS` in your `.env`. Never "All repositories."
   `GITHUB_ALLOWED_REPOS` is also actively enforced at the network layer:
   `quota-guard` inspects git-over-HTTPS and GitHub API paths and blocks
   clone/fetch/push/PR calls to any repo not on the list (see
   `docs/networking.md#github-repo-scope-enforcement`). Token scoping and
   this list should always match, the list is defense-in-depth, not a
   substitute for scoping the token itself.
4. **Permissions**:
   - Contents: Read and write
   - Pull requests: Read and write
   - Metadata: Read-only (mandatory, auto-selected)
   - Everything else: No access
5. Set an expiration (90 days recommended) and put a calendar reminder to
   rotate it, `update.sh` does not rotate tokens for you.
6. Paste the token into `.env` as `GITHUB_AGENT_TOKEN`.

## Option B, GitHub App (better for multiple repos / orgs, revocable per-repo)

1. Create a GitHub App (org or personal account → Settings → Developer
   settings → GitHub Apps → New GitHub App).
2. Permissions: Contents (read/write), Pull requests (read/write), Metadata
   (read). No other permissions, no webhook needed for this use case.
3. Install the App only on the repos you want the agent to touch.
4. Generate a private key for the App; the Gateway/CLI needs an installation
   access token, which is short-lived (~1h) and must be refreshed, either
   use OpenClaw's own GitHub App auth support if/when configured as a
   provider, or run a small token-refresh sidecar. This repo ships the
   simpler Option A by default; treat Option B as a documented upgrade path
   if your fleet of repos grows.

## Branch protection (do this on GitHub, not in this repo)

For every repo in `GITHUB_ALLOWED_REPOS`:

* Settings → Branches → Branch protection rule for `main` (and any other
  protected branch):
  * Require a pull request before merging
  * Require at least 1 approval
  * Do not allow the bot account/token to bypass these rules
* This is what actually enforces "the agent never pushes directly to main", the agent's own workflow (clone → branch → PR) is a convention we build in,
  but GitHub's branch protection is the real, unbypassable control.

## Normal agent workflow

```
clone (via GITHUB_AGENT_TOKEN) → create branch → edit/test → commit
  → push branch (never main) → open PR → (you review and merge)
```

## Rotating the token

```bash
$EDITOR .env                     # paste the new token
sudo ./scripts/install.sh         # re-run; it only rewrites the secret file, nothing destructive
```

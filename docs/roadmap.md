# Roadmap

Planned, not-yet-built work. Nothing here is implemented. Each item is written
so it can be picked up later without re-deriving the design. The guiding
constraint never changes: everything stays **read-only** against the target and
**static** (the target is never executed), and nothing weakens the sandbox or
egress rules.

## Integrating open-source SCA / CVE scanners

Goal: complement the agents' AI-assisted reasoning with deterministic,
ground-truth tooling for dependency and vulnerability data. The agents are good
at explaining impact and remediation; established scanners are better at
exhaustively mapping dependencies to known CVEs. Running both and letting the
`recon` agent correlate the results gives the strongest coverage.

All of these are static and read-only, they parse manifests, lockfiles, and
source; none of them execute the target, so they fit the existing scope without
any new trust-boundary changes.

### Candidate tools

| Tool | Purpose | Notes |
|------|---------|-------|
| [OSV-Scanner](https://github.com/google/osv-scanner) | Lockfile → CVE via the OSV database | Lightweight, clean JSON output; good first tool |
| [Trivy](https://github.com/aquasecurity/trivy) | SCA + CVE for code, lockfiles, images | Fast, broad ecosystem coverage, JSON output |
| [Grype](https://github.com/anchore/grype) | CVE scanning for dependencies/images | Pairs with Syft for SBOM generation |
| [OWASP Dependency-Check](https://owasp.org/www-project-dependency-check/) | Manifest → CVE via the NVD feed | Heavier (JVM + large NVD cache); most "classic" |
| [Semgrep](https://semgrep.dev/) | Rule-based SAST | Deterministic backbone to complement LLM reasoning |
| [gitleaks](https://github.com/gitleaks/gitleaks) / [trufflehog](https://github.com/trufflesecurity/trufflehog) | Secret scanning | Finds committed credentials in the target |

Start with a single tool (OSV-Scanner or Trivy) to prove the integration
pattern, then add others.

### Integration design

1. **Expose each scanner as a tool the `recon` agent can invoke.** The scanner
   produces deterministic findings; the agent triages, de-duplicates, and
   explains impact. Keep the division of labor clear: the tool asserts "CVE-X
   affects dep-Y@version-Z", the agent reasons about whether that path is
   actually reachable in the target code.
2. **Stay in the sandbox, read-only.** Scanners only read the `:ro` target
   mount. No writes to the target, ever, same rule as the agents.
3. **Normalize output to JSON** and feed it to the `reporter` so scanner findings
   land in the same report format as agent findings, including a remediation
   line (typically "upgrade dep-Y to >= safe-version").
4. **Severity reconciliation.** When a scanner and an agent both flag the same
   component, merge them into one finding rather than double-reporting.

### The offline / vuln-database catch

The `clawshell-inference` network is `internal: true` (no egress), and the
sandbox egress is allowlisted. CVE databases (NVD, OSV) need periodic updates,
which means:

- **Pre-stage the vulnerability database** into a state volume, the same pattern
  used for pre-staging local models. Analysis-time runs then read the cached DB
  with no network access.
- **Refresh on a deliberate, allowlisted maintenance step**, not during an
  engagement. This keeps the analysis path fully offline and reproducible.
- Dependency-Check's NVD cache is large and slow to seed; OSV-Scanner and Trivy
  have smaller, quicker-to-stage databases, which is another reason to start
  with one of them.

### Rough effort

- One lightweight scanner (OSV-Scanner or Trivy): small, a tool wrapper
  (Dockerfile + the tool entry the `recon` agent calls), a DB pre-stage recipe,
  and report-merge logic in the `reporter`.
- OWASP Dependency-Check: heavier, JVM dependency plus a larger NVD cache to
  pre-stage and refresh.

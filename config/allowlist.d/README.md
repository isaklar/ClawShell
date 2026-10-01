# allowlist.d/

Host-specific, hot-reloadable egress allowlist entries. Populated by
`./scripts/allowlist.sh add <host:port>` (e.g. an internal service on your LAN).
Files here are git-ignored on purpose, they reflect *your* LAN, not a shareable
default.

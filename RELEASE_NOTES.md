# FWMgr v0.3.0

This release reduces CPU load from frequent online blacklist/whitelist timers, especially on single-vCPU Ubuntu servers.

- Compare normalized downloaded lists against the last-known-good cache; skip firewall reloads when content is unchanged.
- Avoid building large in-memory IP arrays during unchanged timer polls.
- Replace per-IP Python subprocesses and quadratic duplicate scans with efficient cache loading and hash-based deduplication.
- Detect IPv4/IPv6 addresses without spawning Python for every generated rule.
- Retry failed firewall applications using a durable pending marker, and recover a missing managed nftables table or UFW chain.
- Continue using last-known-good caches if online downloads fail.

The CLI, configuration format and installation layout remain compatible with v0.2.0. Existing installations can upgrade with \`sudo fwmgr --update\` once the v0.3.0 GitHub Release assets have been published.

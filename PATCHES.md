# Local patches on Codex Pooler

This fork carries a small stack of patches on top of an upstream
`icoretech/codex-pooler` release. Branch layout:

| Branch    | Contents |
|-----------|----------|
| `main`    | Exact mirror of upstream `main`. Never commit here. |
| `patches` | Upstream release tag + the patch commits below + this file. This is what gets built and deployed. |

Tags `deployed/<upstream-version>-<sha>` mark the exact commit running on the seedbox.

Current base: **`codex-pooler-v0.13.14`** (moved from v0.13.6 on 2026-10-24).

## The patches

Each patch is one commit, listed in order. When you rebase onto a new release,
first check whether upstream already solved the problem. If it did, drop the
commit instead of carrying it.

| # | Commit subject | Why | Regression tests |
|---|----------------|-----|------------------|
| 1 | fix: keep native HTTP compaction streams alive during collection | Long remote compactions sent nothing downstream, so Codex hit its idle timeout. Sends `event: keepalive` while the result is collected. | `test/codex_pooler/gateway/transports/stream_relay_test.exs`, `test/codex_pooler_web/controllers/runtime/backend_codex_compaction_keepalive_test.exs` |
| 2 | feat: retain saved reset summaries for the deployed MCP integration | The OpenUsage app reads saved-reset summaries over MCP. | `test/codex_pooler/mcp/privacy_matrix_test.exs`, `test/codex_pooler/mcp/quota_metadata_test.exs` |
| 3 | fix: keep native websocket compaction alive while collecting | Same as #1 for WebSocket compactions. No code dependency on #1, but both edit `docs-site/.../reference/runtime-routes.mdx`, so keep the order. | `test/codex_pooler_web/controllers/runtime/backend_codex_websocket_compaction_keepalive_test.exs` |
| 4 | fix: allow a bounded provider clock skew in provider-proof checks | The seedbox clock runs about 6 s slow (time sync broken). Strict "provider time must not be in the future" checks rejected every usage report, freezing idle accounts' quota. Adds `quota_provider_clock_skew_seconds` (default 0). | `test/codex_pooler/upstreams/quota/windows/evidence_store_weekly_restart_test.exs` |
| 5 | feat: stop routing account windows below a configurable remaining percent | Stops new turns going to an account with less than N% left on its 5h or weekly window, so turns don't hit the provider's limit mid-stream. Adds `quota_routing_min_remaining_percent` (default 0). | `test/codex_pooler/gateway/routing/quota_window_routing_test.exs` |

Patches 4 and 5 each add a setting function next to each other in
`lib/codex_pooler/quotas/evidence.ex`. Expect a small, mechanical conflict
there when rebasing. Keep both functions.

Patch 4 is a good candidate to send upstream. If upstream accepts it, drop it here.

### Notes from the v0.13.6 → v0.13.14 rebase

- Patch 1 conflicted in `stream_relay.ex`: upstream added a `handlers` argument and
  `observe_termination/5` to `stream_keepalive_result`. The patch's extra
  `{:error, reason, state}` clause now uses the same signature and also records the termination.
- Patch 3 conflicted in `codex_responses_socket.ex`: upstream now pings on the first
  delivered frame and skips pings on closing sockets (`outbound_ping_allowed?/0`).
  The compaction keepalive was kept as an extra case in the tick, behind that same guard,
  and the patch's 10-second cap on the tick interval still applies.
- Patches 2, 4 and 5 applied cleanly; upstream did not touch their files.

## Deployment-only settings (not in this branch)

These live in the seedbox deploy scripts (`~/privatenotes-pooler/pooler-*-qualify.py`)
and systemd config, not in code:

- `runtime.exs` overrides: bind `127.0.0.1`, admin `check_origin`,
  `quota_provider_clock_skew_seconds: 30`, `quota_routing_min_remaining_percent: 2`.
- `~/.config/systemd/user/privatenotes-pooler.service.d/memory.conf`:
  `MemoryHigh=3G`, `MemoryMax=4G`. At the original 768M the pooler was throttled into hangs.

## Updating to a new upstream release

Remotes in the local clone: `origin` is upstream (`icoretech/codex-pooler`) and
`fork` is `DevsNate/codex-pooler`.

```bash
# 1. Refresh upstream and mirror it into the fork's main
git fetch origin --tags
git push fork origin/main:refs/heads/main

# 2. Read what changed upstream in the areas the patches touch
OLD=codex-pooler-v0.13.6 NEW=codex-pooler-v0.13.14   # example versions
git log --oneline $OLD..$NEW -- \
  lib/codex_pooler/gateway lib/codex_pooler_web/codex_responses_socket.ex \
  lib/codex_pooler/mcp lib/codex_pooler/quotas lib/codex_pooler/upstreams/quota

# 3. Move the patches onto the new release (drop any upstream fixed: git rebase -i)
git switch patches
git branch patches-$OLD          # keep the old stack until the new one is deployed
git rebase --onto $NEW $OLD patches

# 4. Check each patch survived intact
git range-diff $OLD..patches-$OLD $NEW..patches

# 5. Run the regression tests listed above, then the full suites for the touched areas.
#    Then build, qualify and activate on the seedbox with the backup-and-rollback scripts.

# 6. After it's live, record it and publish
TAG=deployed/${NEW#codex-pooler-v}-$(git rev-parse --short patches)
git tag $TAG
git push --force-with-lease fork patches
git push fork $TAG
```

Turning on `git config rerere.enabled true` makes git remember conflict
resolutions, such as the `evidence.ex` one, and replay them on the next rebase.

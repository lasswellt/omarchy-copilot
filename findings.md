# Findings

Research notes, written before any real widget logic. Read this first in a
fresh session. Same exercise as
[`omarchy-antigravity`](../omarchy-antigravity) ran for Antigravity — read
that project's `findings.md`/`roadmap.md` too, since the record contract and
plugin mechanics documented there apply here unchanged.

## Answer to "could Copilot use the Agents panel instead of a standalone widget?"

**Yes, and Copilot's local data is a better fit for that panel than
Antigravity's ever was.** Where Antigravity's usage data is locked in
undocumented protobuf blobs, Copilot's is plain JSON and plain SQLite,
already shaped almost exactly like the record contract the Agents panel
(`omarchy.agents`) expects. No reverse engineering needed.

**Confirmed empirically**, same method the antigravity roadmap used: wrote a
schema-valid synthetic `copilot.json` into
`~/.local/state/omarchy/agents/usage/`, ran
`omarchy-shell omarchy.agents refresh`. Traced the adoption path in
`agents/Main.qml` to confirm it's real, not just "didn't crash":

- `Main.qml:24-28` (`listProcess`) runs `find <usageDir> -maxdepth 1 -name
  '*.json'` — no allowlist, the filename is the id.
- `Main.qml:129-132` — the update `Process`'s `onExited` handler calls
  `root.rescanAgents()` *after every refresh*, so a third-party file sitting
  in the directory gets picked up on the very next refresh, not just at
  shell startup.
- `Main.qml:212-215` (`providerEnabled`) defaults to `true` for any id not
  explicitly disabled in settings.
- `Main.qml:219-224` (`providerHasData`) requires at least one of
  `totalPrompts`/`totalSessions`/`activeDays`/`todayPrompts`/`todaySessions`/
  non-empty `limits`/a `balance` — our synthetic record had several of
  these, so it passes.

I did **not** get the visual confirmation the antigravity roadmap got (a
`Cannot open .../assets/copilot.svg` warning proving the tab actually
rendered) — that warning only fires from `Panel.qml:422`
(`heroMarkImage`), which only evaluates for `root.provider`, i.e. whichever
tab is currently *selected*, not just present. I opened the panel via
`omarchy-shell omarchy.agents open` but didn't drive the UI to switch to the
copilot tab (no click automation available), so the mark-load code path was
never exercised. The discovery/adoption path above is confirmed by reading
the code and by the record surviving a refresh cycle untouched; the "it
actually draws a tab" part is inferred, not eyeballed. **Next session:
`omarchy default agent` aside, open the panel and manually switch to the
Copilot chip to confirm it renders (or use `h`/`l` panel keys — see
`agents/README.md`, "Panel" section, in the Omarchy source), then screenshot
before removing the test record again.**

Test record removed afterward (`rm .../usage/copilot.json` +
`omarchy-shell omarchy.agents refresh`); the usage dir is back to
claude/codex/fireworks only.

## What's installed

Two separate Copilot CLI installs currently on this machine, same binary:

- `~/.local/bin/copilot` — Omarchy's own mise-backed wrapper
  (`omarchy-mise-install copilot`, already present before this project
  started; `~/.config/mise/config.toml` has `copilot = "latest"`).
- `~/.local/share/gh/copilot` — downloaded by `gh copilot` (native `gh` CLI
  command as of gh 2.101.0, not a separate extension).

Both are GitHub Copilot CLI 1.0.86 as of this writing. Only one local state
directory either way (see below) — they share it.

## Where it keeps data

- **`~/.copilot/`** — the main one:
  - `config.json` — CLI settings.
  - `session-store.db` — SQLite. See schema below. **This is the rich one.**
  - `session-state/<uuid>/events.jsonl` — plain JSONL, one event per line
    (`session.start`, `session.model_change`, `session.info`, etc.), plus
    `checkpoints/`, `rewind-file-snapshots/`, `research/`, `files/` per
    session, and a `workspace.yaml`.
  - `sidebar-sessions-state/`, `open-sessions-state.json`,
    `command-history-state.json` — UI state, not usage data.
  - `logs/process-*.log` — process logs, one file per run.
- **`~/.cache/copilot/`**:
  - `copilot-user-cache.json` — **has real numeric quota data**, see below.
    Explicitly marked `// Disposable cache ... safe to delete. Managed
    automatically.` — so it's a cache of a real API response, refreshed
    periodically as the CLI runs (multiple timestamped entries observed in
    one file, `retrievedAt` field), not something we write to.
  - `exp-cache.json`, `mcp-tools/`, `marketplaces/`, `pkg/` — experiment
    flags, MCP tool cache, plugin marketplace cache, downloaded binary
    cache. Not usage data.

## Quota data (`~/.cache/copilot/copilot-user-cache.json`)

Plain JSON, keyed by a cache key, each entry a full snapshot of GitHub's
Copilot user/quota API response. Real example (values current as of this
research):

```json
{
  "login": "lasswellt",
  "copilot_plan": "individual",
  "quota_reset_date": "2026-10-01",
  "quota_reset_date_utc": "2026-10-01T00:00:00.000Z",
  "quota_snapshots": {
    "chat": { "unlimited": true, "percent_remaining": 100, "...": "..." },
    "completions": { "unlimited": true, "percent_remaining": 100, "...": "..." },
    "premium_interactions": {
      "entitlement": 1500,
      "quota_remaining": 1500,
      "remaining": 1500,
      "percent_remaining": 100,
      "unlimited": false,
      "quota_id": "premium_interactions",
      "has_quota": true
    }
  }
}
```

This maps almost directly onto the Agents record contract's `limits` array
(`{label, percent, resetsAt}`, see `omarchy-antigravity/roadmap.md` §2):
`premium_interactions` is Copilot's one real capped quota (individual plan:
1500/month as configured on this account) — `chat` and `completions` are
`unlimited: true` here and probably always are, for any individual-plan
account; only worth showing if a non-unlimited value is ever observed on an
org/enterprise plan.

The file holds multiple timestamped entries (cache keys change per some
input, maybe workspace or auth scope) — take the one with the newest
`retrievedAt`.

**Open question:** haven't confirmed how often this cache refreshes on its
own (is it only updated when the CLI runs a request, or does it poll?) or
whether there's a `copilot` subcommand that forces a refresh without
spending a request. Worth checking `copilot --help` output further and/or
strace-ing one invocation.

## Session/token data (`~/.copilot/session-store.db`)

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT,
  branch TEXT, summary TEXT, created_at TEXT, updated_at TEXT
);

CREATE TABLE turns (
  id INTEGER PRIMARY KEY, session_id TEXT REFERENCES sessions(id),
  turn_index INTEGER, user_message TEXT, assistant_response TEXT,
  timestamp TEXT
);

CREATE TABLE assistant_usage_events (
  id INTEGER PRIMARY KEY, session_id TEXT REFERENCES sessions(id),
  turn_index INTEGER, model TEXT NOT NULL,
  input_tokens INTEGER, output_tokens INTEGER,
  cache_read_tokens INTEGER, cache_write_tokens INTEGER,
  reasoning_tokens INTEGER, total_nano_aiu INTEGER,
  request_multiplier REAL, duration_ms INTEGER,
  finish_reason TEXT, created_at TEXT, ...
);
```

(Plus `checkpoints`, `search_index*`, `forge_*`, `dynamic_context_items`,
`session_files`, `session_refs` — not investigated, not obviously
usage-relevant.)

`assistant_usage_events` is the direct equivalent of Claude's per-model
token buckets: `input_tokens`/`output_tokens`/`cache_read_tokens`/
`cache_write_tokens` map one-to-one onto the record contract's `modelUsage`
shape (`inputTokens`/`outputTokens`/`cacheCreationInputTokens`/
`cacheReadInputTokens` — note `cache_write_tokens` ↔
`cacheCreationInputTokens`, `cache_read_tokens` ↔ `cacheReadInputTokens`).
One row per model call, joinable to `sessions` for per-day/per-session
rollups via `created_at`.

`total_nano_aiu` and `token_details_json` (a per-token-type cost breakdown,
`costPerBatch` in some internal billing unit) look like real cost/billing
data too — not needed for the record contract's token counts, but could
back a cost estimate later the way the built-in Fireworks collector
estimates spend.

## Sign-in detection

Unlike Antigravity (where `~/.gemini/google_accounts.json` turned out to
belong to a *different* product's login — see
`omarchy-antigravity/roadmap.md` §6), Copilot's cache file is unambiguous:
`copilot-user-cache.json`'s presence plus a `response.login` field is
Copilot's own confirmed identity, current on this machine (`"login":
"lasswellt"`). Absence of the file (or of any entry with a `login`) is the
signed-out state. Much simpler than Antigravity's situation — no separate
RPC probe needed, just read the cache Copilot already writes for itself.

## Scope recommendation

Given how directly this data maps onto the record contract, and given the
antigravity roadmap's "Route C" conclusion (collector first, standalone
panel later, same data both places) — that applies here even more strongly
since there's no unresolved unknown blocking the collector (Antigravity's
plan was gated on "does `RetrieveUserQuotaSummary` return usable numbers?";
Copilot's answer is already sitting in a cache file, answered, at rest):

1. Write `bin/copilot-usage` against `copilot-user-cache.json` (quota +
   sign-in) and `session-store.db` (sessions/turns/tokens) now — no
   unresolved research blocker, unlike Antigravity's quota question.
2. Ship it as a collector into the Agents panel first (confirmed to work,
   see above) — free UI, and Copilot shows up next to Claude/Codex/Fireworks
   for anyone using that panel already.
3. Build the standalone `Panel.qml` (already stubbed in this repo) as a
   presentation layer over the same collector output, same as the
   antigravity plan.

## Reference: Omarchy plugin mechanics

See `omarchy-antigravity/roadmap.md`, "1. The architecture decision" and
the appendix — the discovery mechanism, record contract, and dev loop
documented there apply verbatim to this plugin; not re-copied here to avoid
drift between the two copies.

## Next steps

1. Confirm the copilot tab actually *renders* in the Agents panel (see
   "Confirmed empirically" above — the render path itself wasn't visually
   checked, only the discovery/adoption path).
2. Write `bin/copilot-usage`: read `copilot-user-cache.json` (newest
   `retrievedAt` entry) for quota/sign-in, `session-store.db` for
   sessions/turns/`assistant_usage_events` for token rollups, emit the §2
   record contract from `omarchy-antigravity/roadmap.md`.
3. Add fixtures (fake `copilot-user-cache.json` + fake `session-store.db`)
   and a smoke test, same shape as `omarchy-antigravity/tests/`.
4. Ship the collector as Route C: drop the record into the Agents usage dir
   *and* feed this repo's own `Panel.qml`.

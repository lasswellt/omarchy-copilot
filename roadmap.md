# Roadmap: stub → fully fledged plugin

Research run, 2026-09-18, after `findings.md`. That file describes *where
Copilot keeps data on disk*; this describes *what shape the plugin should
take and what's left to build*. It also corrects `findings.md`, which aimed
the collector at the wrong data source.

**Status, 2026-09-18 evening: built.** Everything in §8 below is checked off
except the assets and a screenshot, and the Agents-panel tab was confirmed
rendering on this machine (see §9). What follows is kept as the derivation —
why each field is read the way it is — not as a plan.

The headline: **Copilot ships its own JSON-RPC server, its own JSON Schema
for it, and a `account.getQuota` method that answers the limits question
directly.** No file scraping for quota, no reverse engineering at all. The
one blocker Antigravity still has (nobody signed in, server not running) does
not exist here — everything below was probed live against this machine.

## What changed since `findings.md`

| `findings.md` said | Now |
|---|---|
| Read quota from `~/.cache/copilot/copilot-user-cache.json` | **Superseded.** `account.getQuota` over the CLI's own stdio RPC is live and authoritative. At the moment I compared them the cache file was stale by 5 premium requests (§2) |
| "Open question: haven't confirmed how often this cache refreshes" | **Answered.** It refreshes when the CLI runs, and not otherwise. A passive collector reading it reports whatever the last interactive session left behind |
| The cache file is "plain JSON" | **Wrong.** It is JSONC — two `//` lines before the object — and the payload is nested under a `copilotUserCache` key the notes omit. `json.loads` on the raw bytes fails (§2) |
| `input_tokens`/`cache_write_tokens` map "one-to-one" onto the record contract | **Wrong, and it double-counts.** `input_tokens` is the *total* prompt tokens, cache included. Derive the buckets from `token_details_json` (§4) |
| Sign-in = the cache file exists and has a `login` | **Superseded** by `account.getCurrentAuth`, which returns the live auth type, login, and the whole user payload (§3) |
| "no protobuf blobs to decode" | **True, and it gets better.** The shipped binary is a launcher; the real app unpacks to readable JS plus a 1.7 MB JSON Schema of the entire RPC surface (§1) |
| `premium_interactions` is the one real capped quota | **Holds.** `chat` and `completions` are `unlimited: true` on this plan |

Net effect: the collector gets smaller and more correct than planned. The
disk files stay in the design, but as the *offline fallback*, not the
primary source.

## 1. The CLI is a Node app you can read

`~/.local/bin/copilot` is a mise wrapper around
`~/.local/share/mise/installs/copilot/1.0.86/copilot`, a 167 MB Node
single-executable. That binary is a **launcher**: on first run it unpacks the
real application to

```
~/.cache/copilot/pkg/linux-x64/1.0.86/
```

which is plain, unobfuscated (if minified) JavaScript plus, more usefully:

- `schemas/api.schema.json` — 1.7 MB. The complete JSON-RPC surface:
  namespaces, method names, stability, and a `definitions` block with every
  request and result type, each field documented.
- `copilot-sdk/types.d.ts`, `copilot-sdk/generated/rpc.d.ts` — the same
  contract as TypeScript, with prose comments.
- `schemas/session-events.schema.json` — the `events.jsonl` event schema.
- `package.json` → `github.com/github/copilot-cli`.

`findings.md` filed `~/.cache/copilot/pkg/` under "downloaded binary cache,
not usage data". It is the application, and it is the documentation.

**Caveat:** it is versioned (`.../1.0.86/`) and it is a *cache* — it can be
deleted and re-fetched. Nothing should read it at runtime. It is a research
artifact, the way `tools/carve.py` output is for Antigravity, except nothing
had to be carved.

## 2. The RPC server, and how to talk to it

The SDK starts the runtime as a subprocess. From `copilot-sdk/index.js`,
`startCLIServer()`:

```
copilot --headless --no-auto-update --stdio
```

(`--port N` swaps stdio for TCP; `--auth-token-env`, `--no-auto-login`,
`--session-idle-timeout`, `--embedded-host` are the other hidden flags. None
appear in `copilot --help`.)

The framing is `vscode-jsonrpc`: LSP-style `Content-Length: N\r\n\r\n` headers
around each JSON-RPC 2.0 message. The handshake is `connect`, and its
`clientInfo` takes `editorName` / `editorVersion` / `extensionName` /
`extensionVersion` — *not* `name`/`version`, which is rejected. The handshake
is optional unless the server was started with `COPILOT_CONNECTION_TOKEN`:
a malformed `connect` errored and the following calls still answered.
`runtime.shutdown` exits cleanly.

**Probed live, this machine, just now:**

```jsonc
// → connect
{"ok":true,"protocolVersion":3,"version":"1.0.86","taskKinds":["agent","shell"]}

// → account.getQuota {}
{"quotaSnapshots":{
  "chat":                 {"isUnlimitedEntitlement":true,  "entitlementRequests":0,    "usedRequests":0, "remainingPercentage":100,  ...},
  "completions":          {"isUnlimitedEntitlement":true,  "entitlementRequests":0,    "usedRequests":0, "remainingPercentage":100,  ...},
  "premium_interactions": {"isUnlimitedEntitlement":false, "entitlementRequests":1500, "usedRequests":5, "remainingPercentage":99.7,
                           "overage":0,"overageAllowedWithExhaustedQuota":false,"usageAllowedWithExhaustedQuota":false,
                           "hasQuota":true,"tokenBasedBilling":true,"overageEntitlement":0,
                           "resetDate":"2026-09-18T20:32:32.698Z"}}}
```

Cost of the whole cycle — spawn, connect, getQuota, shutdown, exit:
**1.41 s**, no new rows in `session-store.db`, no session directory created.
That is the same weight class as the Codex collector's `codex app-server`
spawn, and it is the sanctioned interface rather than a scraped file.

**Two traps in that response, both load-bearing:**

1. **`resetDate` is not the reset date.** It is the snapshot timestamp — it
   came back as "now" on two calls 33 seconds apart. The real value is
   `quota_reset_date_utc` (`2026-10-01T00:00:00.000Z`) from
   `account.getCurrentAuth`. Mapping `resetDate` into the record contract's
   `resetsAt` would draw a countdown that always reads zero.
2. **`usedRequests` is account-wide, not machine-local.** It said 5 while
   `session-store.db` on this machine holds exactly one usage event. That is
   correct behavior — premium interactions are billed per account across the
   IDE, the web, and every machine — but it means limits and local token
   stats are two different scopes, and only the limits are account-scoped.

The stale-cache comparison: `copilot-user-cache.json` claimed
`quota_remaining: 1500`, `percent_remaining: 100` while the RPC said 5 used
and 99.7% remaining. The cache is a snapshot from the last interactive run,
exactly as its own `// Disposable cache` header implies.

## 3. Sign-in and tier

`account.getCurrentAuth` (no params) returns:

```jsonc
{"authInfo":{
  "type":"gh-cli",                      // credential source
  "host":"https://github.com",
  "login":"lasswellt",
  "copilotUser":{                       // the whole user payload, live
    "login":"lasswellt","copilot_plan":"individual",
    "access_type_sku":"monthly_subscriber_quota",
    "quota_reset_date_utc":"2026-10-01T00:00:00.000Z",
    "quota_snapshots":{...},"token_based_billing":true, ...}}}
```

So one call answers sign-in (`authInfo` present, `copilotUser.login` set),
tier (`copilot_plan`), and reset date. Signed out, this is where the record's
`usageStatusText` / `authHelpText` come from; `authHelpText` should be
`Run \`copilot login\` to authenticate.`

`copilot_plan` values seen in the CLI's own UI gallery: `individual`, `pro`,
`pro_plus`, `edu`, plus free/business/enterprise paths in the same code.
`tierLabel` wants a display form — "Individual", "Pro", "Pro+" — not the raw
slug.

`account.getAllUsers` exists for multi-account setups; out of scope for v1
but worth knowing before someone files the bug.

## 4. Tokens: the mapping in `findings.md` double-counts

The one real usage row on this machine:

```jsonc
{"model":"gpt-5.6-terra","input_tokens":15805,"output_tokens":6,
 "cache_read_tokens":0,"cache_write_tokens":15802,"reasoning_tokens":0,
 "total_nano_aiu":3958300000,"request_multiplier":1.0,
 "token_details_json":"[{\"tokenType\":\"input\",\"tokenCount\":3,...},
                        {\"tokenType\":\"cache_read\",\"tokenCount\":0,...},
                        {\"tokenType\":\"cache_write\",\"tokenCount\":15802,...},
                        {\"tokenType\":\"output\",\"tokenCount\":6,...}]"}
```

`input_tokens` is 15805. `token_details_json` says the *uncached* input was
3, and 3 + 15802 = 15805. So `input_tokens` is the **total** prompt size with
cache included, and `findings.md`'s one-to-one mapping would report
15805 + 15802 input tokens for a request that sent 3.

This is the same shape as the Fireworks collector's
`uncachedPromptTokens = promptTokens - cachedPromptTokens`
(`omarchy-agent-usage-fireworks:row handling`). Map it the same way:

| Record contract | Copilot |
|---|---|
| `inputTokens` | `token_details_json` `input`, else `max(0, input_tokens - cache_read_tokens - cache_write_tokens)` |
| `outputTokens` | `output_tokens` (+ `reasoning_tokens`, see below) |
| `cacheReadInputTokens` | `cache_read_tokens` |
| `cacheCreationInputTokens` | `cache_write_tokens` |

Prefer `token_details_json`: it is the authority, it is per-token-type, and
it already carries the model id. Keep the arithmetic as the fallback for rows
where it is null.

**Confidence:** two samples now, both exact, from independent sessions. That
check is no longer a suggestion — `tests/run` asserts
`input_tokens == Σ(details where type in input, cache_read, cache_write)`
over every row of the real database on every run, so a change in Copilot's
reporting surfaces as a test failure rather than as quietly wrong numbers.

**Open, same reason:** whether `output_tokens` already includes
`reasoning_tokens`. `reasoning_tokens` was 0 here so the row cannot tell.
The opencode path in the Codex collector adds reasoning to output explicitly
("opencode keeps thinking tokens out of output"), so the same question has
gone both ways before. Settle it with one `--reasoning-effort high` run.

### AI credits — a real, native cost unit

`total_nano_aiu / 1e9` is what the CLI calls **AI credits** (`app.js`
divides by `1e9` and labels the result "credits"; the subagent limit dialog
calls its cap `maxAiCredits`). Our row: 3.9583 credits. The figure is
reconstructible from `token_details_json` — `Σ tokenCount / batchSize ×
costPerBatch` gives exactly 3,958,300,000 — so it is a genuine rated cost,
not an opaque counter.

This is the thing Copilot has that Claude and Codex don't. It is *not* a good
fit for the record contract's `balance` (that renders as money with a
currency prefix, so `"AIU"` would draw `AIU 3.96`). Save it for our own
`Panel.qml`, or leave it out of v1.

### Premium requests, locally

`session.usage_checkpoint` in `events.jsonl` carries
`{"totalNanoAiu":3958300000,"totalPremiumRequests":1}` for the same session,
against one row with `request_multiplier: 1.0`. So `Σ request_multiplier`
over user-initiated rows is the local premium-request count — useful for
"how much of my 1500 did *this machine* spend", which the account-wide
`usedRequests` can never tell you. Nice-to-have, not v1.

## 5. Reading the database safely

`session-store.db` is **WAL** (`PRAGMA journal_mode` → `wal`), and Copilot may
be running. Use the Codex collector's pattern verbatim
(`omarchy-agent-usage-codex:219`):

```python
conn = sqlite3.connect(db.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
conn.execute("PRAGMA query_only = ON")
```

Verified against a copy with no `-shm`/`-wal` sidecars: it opens and reads.
Note it *creates* `session-store.db-shm` and `-wal` next to the database —
SQLite needs the shared-memory file to read a WAL database. Same user, same
directory, harmless, but it means the collector is not strictly read-only at
the filesystem level. On a read-only `~/.copilot` it would fail; copy to a
temp file if that ever matters.

**Dates are UTC — confirmed in the wild.** While this was being built the
clock crossed UTC midnight: at `2026-09-19T01:56Z`, local time was
`2026-09-18 21:56 EDT`, and the published record correctly reported today as
`2026-09-18` with 2 prompts and 31,629 tokens. A naive `date('now')` would
have reported the 19th, with nothing on it. The detail below is why.

`created_at` is written as ISO-8601 with a `Z`
(`2026-09-18T20:14:42.409Z`) even though the column default is
`datetime('now')`. SQLite's `date()` parses both, but returns UTC — and
`date('now')` is UTC too, so a naive `WHERE date(created_at) = date('now')`
files evening work under tomorrow west of Greenwich. Bucket in Python against
local time, the way `local_day()` does in the Codex collector, or use
`datetime(created_at, 'localtime')`.

**Env overrides exist**, which is what makes fixtures possible:
`COPILOT_HOME` (default `~/.copilot`) and `COPILOT_CACHE_HOME` (default
`~/.cache/copilot`). Honor both, the way the Claude collector honors
`CLAUDE_CONFIG_DIR` and Codex honors `CODEX_HOME`.

Table roles, confirmed against live rows:

| Table | Gives |
|---|---|
| `sessions` | `totalSessions`, `todaySessions`, plus `cwd`/`repository`/`branch`/`summary` for a recent-activity list in our own panel |
| `turns` | one row per user message → `totalPrompts`, `todayPrompts`. **Copilot has real prompt counts**, so `hasPromptStats` stays `true` |
| `assistant_usage_events` | `modelUsage`, `todayTokensByModel`, `recentDays`, `activeDates` |

## 6. The record contract, filled in

The contract itself is §2 of `../omarchy-antigravity/roadmap.md`; it is
unchanged. What Copilot puts in it:

```jsonc
{
  "schemaVersion": 1, "id": "copilot", "name": "Copilot",
  "updatedAt": "<now, ISO>",
  "ready": true, "hasLocalStats": true,
  "hasPromptStats": true,          // turns gives real prompt counts
  // no "scope": stats are machine-local (device). Limits are account-wide
  // but never travel between machines anyway — Main.qml:207 blanks them.

  "tierLabel": "Individual",       // from copilot_plan, display-cased
  "limits": [                      // one per non-unlimited quota snapshot
    { "label": "Premium interactions",
      "percent": 1 - remainingPercentage/100,
      "resetsAt": copilotUser.quota_reset_date_utc }   // NOT snapshot.resetDate
  ],

  "todayPrompts": …, "todaySessions": …,
  "todayTotalTokens": …, "todayTokensByModel": { "<model>": n },
  "recentDays": [{ "date": "YYYY-MM-DD", "messageCount": tokens }],
  "totalPrompts": …, "totalSessions": …,
  "activeDays": …, "activeDates": [ … ],
  "modelUsage": { "<model>": { inputTokens, outputTokens,
                               cacheCreationInputTokens, cacheReadInputTokens } },

  "usageStatusText": "",           // "Copilot unavailable" when the RPC fails
  "authHelpText": "Run `copilot login` to authenticate.",
  "retryAdvised": false            // true when the RPC could not reach GitHub
}
```

Skip any snapshot with `isUnlimitedEntitlement: true` — that is `chat` and
`completions` on every plan seen so far, and a meter pinned at 0% is noise.
If every snapshot is unlimited the record carries no `limits`, and
`providerHasData()` (`agents/Main.qml:219`) then depends on the session and
prompt counts, which is the right outcome.

## 7. Architecture: Route C, unchanged, and now unblocked

`findings.md` already landed on the Antigravity roadmap's Route C —
collector first, Agents-panel record second, standalone panel third — and
nothing here argues against it. Two things firm it up:

- The collector no longer has an unresolved data source. Every field above
  came back from a live call or a live row today.
- The collector is small: one RPC round trip and three SQL queries.

The panel-side mechanics are confirmed and unchanged from `findings.md`:
`agents/Main.qml:28` discovers by filename with no allowlist,
`Main.qml:212` defaults unknown ids to enabled, `Main.qml:129` rescans after
every refresh. And `omarchy-agent-usage-update:55` only globs
`$OMARCHY_PATH/bin/omarchy-agent-usage-*`, so it will never run our
collector *and* never delete our record — the plugin owns its own schedule.

That schedule is a `service` kind. `nixfred.infomarchy` is the third-party
proof: `"kinds": ["service", "overlay"]`, `"keepLoaded": true`,
`"entryPoints": { "service": "Infomarchy.qml" }`, and inside it plain
QML `Timer` + `Process` pairs. `omarchy-plugin-validate` accepts `service`
as a kind as long as `entryPoints.service` exists.

**One cosmetic cost stands, unchanged:** `assets/<id>.svg` resolves with
`Qt.resolvedUrl` *relative to the agents plugin directory*
(`agents/Panel.qml:288-294`), which is root-owned under
`/usr/share/omarchy/shell/plugins/agents/`. A third-party plugin cannot
install a mark there. The panel falls back to the bar glyph. That is the
reason our own `Panel.qml` exists.

## 8. Gap analysis

Measured against `omarchy.agents` and `nixfred.infomarchy`.

### Manifest
- [x] Add `"service"` to `kinds` + `entryPoints.service` + `keepLoaded: true`
- [~] `activation: "on-demand"` — **dropped.** `grep -rn activation` over the
      whole shell and `bin/` finds no reader; the agents manifest is the only
      thing in the tree that declares it. Inert metadata, deliberately left out
- [x] `barWidget.aliases`: `["copilot", "gh-copilot"]`
- [x] `barWidget.defaults` / `schema` — `refreshIntervalSec` (`integer`, min
      60, max 3600, default 900). Live schema types across first-party
      manifests: `string`, `integer`, `enum`, `path`
- [x] Drop "Stub: no real data wired up yet" from both description fields;
      bump `version` (0.2.0)

### Collector — `bin/copilot-usage`
- [x] Spawn `copilot --headless --no-auto-update --stdio`, `connect`,
      `account.getCurrentAuth`, `account.getQuota`, `runtime.shutdown`
- [x] Find `copilot` the way the Codex collector does (`runtime_env()` — PATH
      plus `~/.local/bin`, `~/.npm-global/bin`, mise shims)
- [x] Hard timeout on the whole RPC exchange, and kill the child in a
      `finally`. 1.4 s observed; budget is 12 s
- [x] SQL rollups against `COPILOT_HOME/session-store.db`, read-only,
      bucketed in local time
- [x] Emit the §6 record; `--force` / `--limits-only` accepted for parity
      with every other collector
- [x] Offline / signed-out → `ready` stays true (local stats still count),
      `limits` empty, `usageStatusText` + `authHelpText` set,
      `retryAdvised: true` when the failure looks transient
- [x] Scan cache under `~/.cache/omarchy/agent-usage/` with the Codex
      collector's `flock` + versioned-envelope + `scanDate` discipline
- [x] **Fallback path:** when the RPC cannot start, read
      `COPILOT_CACHE_HOME/copilot-user-cache.json` for a stale-but-real
      quota, and say so (`usageStatusText: "Quota from cache"`)
- [x] `aiCredits` beyond the contract, rated from `total_nano_aiu` (§4)

### Service — `Service.qml`
- [x] `Timer` (interval from `refreshIntervalSec`, `triggeredOnStart`) driving
      a `Process` that runs `bin/copilot-usage-update`
- [x] Write the record to
      `${XDG_STATE_HOME:-~/.local/state}/omarchy/agents/usage/copilot.json`
      via temp-file + rename, matching `omarchy-agent-usage-update:collect()`
- [x] Honor `retryAdvised` with one 30 s retry, mirroring
      `agents/Main.qml:96-104`

A service is injected `omarchyPath`, `shell`, `manifest`, `barWidgetRegistry`
and `pluginRegistry` (`shell.qml:928-932`) — **but not `settings`**, which
only bar widgets get. So the interval is read out of `shell.barConfig` by
finding our own entry in the bar layout, with the manifest default behind it.
One setting, honored by both surfaces.

### Panel (`Panel.qml`)
`Ui/Panel.qml` already gives `open`/`close`/`toggle`/`switchPanel`,
`setting()`, and an `IpcHandler` bound to `ipcTarget`.
- [x] Hero: mark, "Copilot", tier line, today's prompts and sessions
- [x] Premium-interactions meter with reset countdown
- [x] Tokens by day / by model, over the same record the Agents panel reads
- [x] AI credits row — the thing the Agents panel can't show (§4)
- [x] Signed-out / error card
- [x] Self-hide with no data
- [x] Keys: `j`/`k`, `r`/Enter, `o`, Tab, Esc
- [x] Bar icon: left toggles, right launches `copilot`

It reads the *published record*, not the collector — the same file the Agents
panel reads — so the two views cannot disagree. Opening it asks for
`--limits-only` (fresh quota, reused disk scan); `r` forces a full rescan.

### Assets — still open
- [ ] An SVG mark + `-light` twin. Only this plugin's own panel could use
      one; the Agents panel resolves marks inside its own root-owned
      directory. The current panel uses a Nerd Font GitHub glyph, which needs
      no vendoring and no trademark question. An SVG is an improvement, not a
      gap
- [ ] `preview.png` for the README

### Tests
- [x] Record-contract assertion over collector output, in every case
- [x] Fixtures via `COPILOT_HOME` / `COPILOT_CACHE_HOME`: no DB, empty DB,
      signed out, RPC absent, RPC erroring, malformed `token_details_json`,
      JSONC cache with a stale second entry, unrated rows, all-unlimited
      quotas, an exhausted quota, unknown plan slugs, the local-midnight
      boundary
- [x] The `input_tokens == Σ details` assertion from §4, run against the real
      database on every test run
- [x] `omarchy-plugin-validate .` in `tests/lint`
- [x] `qmllint` in `tests/lint`, with the three warning categories the
      Omarchy plugin idiom produces by construction switched off and
      everything else fatal — calibrated against
      `/usr/share/omarchy/shell/plugins/agents/Panel.qml`, which produces
      exactly those three and nothing else
- [ ] A DB genuinely locked mid-write. The read-only + `query_only` open is
      the Codex collector's, and a `sqlite3.Error` degrades to an incomplete
      uncached scan, but nothing forces that path in a test yet

### Docs
- [x] README from "scaffold" to what it shows, how it works, settings,
      commands, tests, and known limits
- [x] `CHANGELOG.md`. No `THIRD_PARTY_NOTICES.md`: nothing is vendored
- [ ] Push to the declared homepage so `omarchy plugin add <git url>` works.
      The installed clone's `origin` is this directory, not GitHub, so the
      local dev loop never needed it — but the README's install line does

## 9. What was built, in order

1. [x] `bin/copilot-usage`, RPC half first.
2. [x] SQL half, with the `token_details_json` mapping and local-time
   bucketing.
3. [x] Fixtures and the contract tests, before any QML.
4. [x] `bin/copilot-usage-update` + `Service.qml`. **Copilot appears in the
   built-in Agents panel here.**
5. [x] Manifest, then `Panel.qml` over the same record.
6. [x] Docs. Assets and distribution still open (§8).
7. [x] AI credits. Local premium-request counts and per-repo activity remain
   available and unbuilt — `Σ request_multiplier` and the `sessions` table's
   `repository` / `branch` columns respectively.

### Installing over a running shell

`omarchy plugin update` pulls the files and the registry re-reads the
manifest — `omarchy-plugin-list --json` shows the new `kinds` at once — but
already-loaded QML is not reloaded, and `omarchy-shell shell rescanPlugins`
does not change that. The bar kept running the 0.1.0 stub and never started
the newly declared service until `omarchy restart shell`.

The registry's watcher is not the missing piece. `PluginRegistry.qml:665-680`
runs `inotifywait -m -r` over the whole plugins directory and does emit
`localPluginChanged`; the shell logs `Local plugin changed, reloading:
lasswellt.copilot` on every update. It still does not re-read the QML.
Tested head-on rather than inferred: an IPC method added to `Panel.qml`,
committed, and pulled with `omarchy plugin update` was still "Function not
found." eight seconds later, and answered immediately after a restart.

The symptom is indistinguishable from a broken plugin, so test with a method
only the new code has rather than one both versions share: `lasswellt.copilot
toggle` answered fine from the *old* stub, while `lasswellt.copilot refresh`
returned "Function not found." and `lasswellt.copilot.data refresh` returned
"Target not found." — which is what a stale load looks like.

### The render question, answered

`findings.md` left one thing unconfirmed: the Agents panel's *discovery* of a
third-party record was proven, but nobody had watched it draw the tab. Done
now, by the method that was missing last time — `agents/Panel.qml` exposes an
IPC `next()` that advances the selected provider, which is the click
automation that did not seem to exist:

```bash
omarchy-shell omarchy.agents refresh
omarchy-shell omarchy.agents open
omarchy-shell omarchy.agents next        # repeat until Copilot is selected
quickshell log --id <instance> -t 40
```

The log then carries

```
WARN scene: QML QQuickImage at .../agents/Panel.qml[423:17]:
  Cannot open: .../agents/assets/copilot.svg
```

which only fires from `heroMarkImage`, and `heroMarkImage` only evaluates for
`root.provider` — the tab that is *selected*, not merely present. So the
record was adopted, the tab was built, it was selected, it rendered, and the
panel went looking for our mark in the one directory we cannot write to.
Cosmetic, and exactly as predicted in §7.

## Appendix: how to redo this research

```bash
APP=~/.cache/copilot/pkg/linux-x64/1.0.86        # version-pinned, re-created on demand

# the whole RPC surface, one line per method
jq -r '.server | to_entries[] | .value | objects
       | select(.rpcMethod) | "\(.rpcMethod) — \(.description)"' $APP/schemas/api.schema.json
jq -r '.server.account | to_entries[] | "\(.value.rpcMethod) — \(.value.description)"' \
   $APP/schemas/api.schema.json

# any type, fully documented
jq '.definitions.AccountQuotaSnapshot' $APP/schemas/api.schema.json

# how the SDK starts the runtime
grep -o 'startCLIServer.\{0,600\}' $APP/copilot-sdk/index.js

# talk to it: Content-Length framed JSON-RPC 2.0 over stdio
copilot --headless --no-auto-update --stdio

# what the CLI itself displays (slash commands, quota UI, the credit unit)
grep -o 'usageCommand.\{0,400\}' $APP/app.js

# local rows
sqlite3 -json ~/.copilot/session-store.db \
  'select * from assistant_usage_events order by id desc limit 5;'
jq -c 'select(.type=="session.usage_checkpoint")' \
  ~/.copilot/session-state/*/events.jsonl
```

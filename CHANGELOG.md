# Changelog

## 0.2.0 — 2026-09-18

First working version. The 0.1.0 scaffold drew a placeholder "GH" label and
carried no data.

### Added

- `bin/copilot-usage` — prints the Agents record contract. Quota, plan, and
  sign-in come from the Copilot CLI's own JSON-RPC runtime
  (`account.getQuota`, `account.getCurrentAuth`); tokens, prompts, and
  sessions from a read-only scan of `session-store.db`.
- `bin/copilot-usage-update` — publishes the record to
  `~/.local/state/omarchy/agents/usage/copilot.json`, atomically. Copilot
  gains a tab in the built-in Agents panel at this point; confirmed rendering
  on this machine.
- `Service.qml` — a `service`-kind entry point that runs the publisher on a
  timer, honors `retryAdvised` with one sooner retry, and exposes
  `omarchy-shell lasswellt.copilot.data refresh`.
- `Panel.qml` — a real bar widget over the published record: premium-request
  meter with reset countdown, AI credits, tokens by day and by model,
  an auth/error card, keyboard navigation, and self-hiding when there is
  nothing to report.
- AI credits in the record (`aiCredits`), rated from `total_nano_aiu`. Beyond
  the contract and ignored by the built-in panel; shown in ours.
- `tests/run` (1199 checks) and `tests/lint`. The tests speak the real
  JSON-RPC framing through `tests/fake-copilot` rather than mocking the
  client, and assert the token identity the mapping rests on against the real
  database when one is present.
- `refreshIntervalSec` setting, read by both surfaces from one place.
- `omarchy-shell lasswellt.copilot status` — the headline numbers as JSON,
  off the record already in memory, for prompt segments and polling scripts.

### Measured

- `output_tokens` already includes `reasoning_tokens`, so reasoning is never
  added to the output bucket. A `--reasoning-effort high` run produced 13
  reasoning tokens inside an `output_tokens` of 17, with no `reasoning` entry
  in `token_details_json` and the CLI's own footer reading `↓ 17 (13
  reasoning)`. The first draft would have double-counted them. `tests/run`
  now asserts this against the real database on every run.

### Fixed, versus the plan in `findings.md`

- Quota no longer comes from `copilot-user-cache.json`. That file is only
  refreshed when the CLI runs, and was measurably stale — it read 100%
  remaining while the live RPC reported 5 premium requests spent. It survives
  as the fallback for when the runtime will not start, labelled as cached.
- `resetsAt` comes from `quota_reset_date_utc`, not from the quota snapshot's
  own `resetDate` — that field carries the moment the snapshot was taken, so
  a countdown built on it always reads zero.
- Token buckets are derived from `token_details_json`, not from the flat
  columns. `input_tokens` is the inclusive prompt total, so reading it as
  uncached input counted the cache twice.
- Day bucketing happens in local time. SQLite's `date()` and `date('now')`
  are both UTC, which files an evening's work under the wrong day.

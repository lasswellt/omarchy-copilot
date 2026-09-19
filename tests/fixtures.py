"""Fixture builders: a Copilot home and cache directory made from scratch.

Everything is generated rather than checked in — session-store.db is a real
SQLite file, and a binary blob in git would drift from the schema it is
supposed to stand for without anyone noticing.
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

# The subset of the real schema this collector reads, copied from a live
# session-store.db (schema_version 8). Trimmed to the columns under test:
# the collector names every column it selects, so the absent ones would only
# be noise here.
SCHEMA = """
CREATE TABLE sessions (
  id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT,
  branch TEXT, summary TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);
CREATE TABLE turns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  turn_index INTEGER NOT NULL, user_message TEXT, assistant_response TEXT,
  timestamp TEXT DEFAULT (datetime('now')),
  UNIQUE(session_id, turn_index)
);
CREATE TABLE assistant_usage_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  turn_index INTEGER, agent_id TEXT, parent_tool_call_id TEXT,
  model TEXT NOT NULL, copilot_usage_model TEXT,
  input_tokens INTEGER, output_tokens INTEGER,
  cache_read_tokens INTEGER, cache_write_tokens INTEGER,
  reasoning_tokens INTEGER, total_nano_aiu INTEGER,
  request_multiplier REAL, duration_ms INTEGER,
  time_to_first_token_ms INTEGER, output_ttft_ms REAL,
  inter_token_latency_ms INTEGER, initiator TEXT, api_endpoint TEXT,
  reasoning_effort TEXT, finish_reason TEXT, content_filter_triggered INTEGER,
  token_details_json TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
"""


def utc_stamp(local: datetime) -> str:
  """A local wall-clock time, written the way Copilot writes it.

  The CLI stores ISO-8601 with a trailing Z regardless of the column
  default, so the tests must too — and building from a local datetime is
  what makes the local-day assertions hold in any timezone.
  """
  return local.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def token_details(model: str, inp: int, cache_read: int, cache_write: int,
                  output: int, extra_type: str | None = None,
                  extra_count: int = 0) -> str:
  """The four token types Copilot actually reports, in its own shape.

  There is deliberately no `reasoning` entry: a `--reasoning-effort high` run
  that burned 13 reasoning tokens still reported one `output` entry of 17,
  matching `output_tokens`, with reasoning already inside it. extra_type is
  for asserting that a type the collector has never seen is ignored rather
  than folded into a bucket it does not belong in.
  """
  entries = [
    {"batchSize": 1000000, "costPerBatch": 200000000000, "tokenCount": inp, "tokenType": "input", "model": model},
    {"batchSize": 1000000, "costPerBatch": 20000000000, "tokenCount": cache_read, "tokenType": "cache_read", "model": model},
    {"batchSize": 1000000, "costPerBatch": 250000000000, "tokenCount": cache_write, "tokenType": "cache_write", "model": model},
    {"batchSize": 1000000, "costPerBatch": 1200000000000, "tokenCount": output, "tokenType": "output", "model": model},
  ]
  if extra_type is not None:
    entries.append({"batchSize": 1000000, "costPerBatch": 1200000000000,
                    "tokenCount": extra_count, "tokenType": extra_type, "model": model})
  return json.dumps(entries)


def build_home(root: Path, sessions=(), turns=(), events=(), with_db: bool = True) -> Path:
  """A COPILOT_HOME. Pass with_db=False for a machine that never ran the CLI."""
  root.mkdir(parents=True, exist_ok=True)
  if not with_db:
    return root
  conn = sqlite3.connect(root / "session-store.db")
  try:
    conn.executescript(SCHEMA)
    conn.executemany(
      "INSERT INTO sessions (id, summary, created_at, updated_at) VALUES (?, ?, ?, ?)", sessions)
    conn.executemany(
      "INSERT INTO turns (session_id, turn_index, user_message, timestamp) VALUES (?, ?, ?, ?)", turns)
    conn.executemany(
      "INSERT INTO assistant_usage_events"
      " (session_id, model, input_tokens, output_tokens, cache_read_tokens,"
      "  cache_write_tokens, reasoning_tokens, token_details_json, created_at,"
      "  total_nano_aiu)"
      " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      # total_nano_aiu is optional in the fixtures: a row that omits it is a
      # row Copilot did not rate, and the collector must survive that.
      [tuple(row) + (None,) * (10 - len(row)) for row in events])
    conn.commit()
  finally:
    conn.close()
  return root


def build_cache(root: Path, login: str = "octocat", plan: str = "individual",
                entitlement: int = 1500, percent_remaining: float = 80.0,
                reset: str = "2026-10-01T00:00:00.000Z",
                retrieved: str = "2026-09-18T19:33:40.657Z",
                extra_entry: bool = False) -> Path:
  """A COPILOT_CACHE_HOME holding the CLI's disposable user cache.

  Written as the real one is: two `//` lines in front of the object, the
  payload under a copilotUserCache key, and the raw API's snake_case
  snapshot shape rather than the RPC's normalized one.
  """
  root.mkdir(parents=True, exist_ok=True)

  def entry(retrieved_at: str, remaining: float) -> dict:
    return {
      "schemaVersion": 1,
      "retrievedAt": retrieved_at,
      "response": {
        "login": login,
        "copilot_plan": plan,
        "quota_reset_date_utc": reset,
        "quota_snapshots": {
          "chat": {"unlimited": True, "entitlement": 0, "percent_remaining": 100},
          "completions": {"unlimited": True, "entitlement": 0, "percent_remaining": 100},
          "premium_interactions": {
            "unlimited": False, "entitlement": entitlement,
            "percent_remaining": remaining, "quota_id": "premium_interactions",
          },
        },
      },
    }

  payload: dict = {"copilotUserCache": {"v1:aaa": entry(retrieved, percent_remaining)}}
  if extra_entry:
    # An older key that must lose to the newer retrievedAt.
    payload["copilotUserCache"]["v1:bbb"] = entry("2026-09-01T00:00:00.000Z", 5.0)

  text = ("// Disposable cache for Copilot user responses, safe to delete. Managed automatically.\n"
          "// User settings belong in settings.json.\n" + json.dumps(payload, indent=2) + "\n")
  (root / "copilot-user-cache.json").write_text(text, encoding="utf-8")
  return root


def rpc_scenario(path: Path, login: str = "octocat", plan: str = "individual",
                 reset: str = "2026-10-01T00:00:00.000Z",
                 snapshots: dict | None = None, auth_error: str | None = None,
                 quota_error: str | None = None, signed_out: bool = False) -> Path:
  """A scenario file for tests/fake-copilot.

  The default snapshots mirror a live account.getQuota response, including
  the resetDate trap: the runtime reports the moment the snapshot was taken
  there, not the date the quota resets.
  """
  if snapshots is None:
    snapshots = {
      "chat": {"isUnlimitedEntitlement": True, "entitlementRequests": 0, "usedRequests": 0,
               "remainingPercentage": 100, "overage": 0, "resetDate": "2026-09-18T20:32:32.698Z",
               "usageAllowedWithExhaustedQuota": False, "overageAllowedWithExhaustedQuota": False},
      "completions": {"isUnlimitedEntitlement": True, "entitlementRequests": 0, "usedRequests": 0,
                      "remainingPercentage": 100, "overage": 0, "resetDate": "2026-09-18T20:32:32.698Z",
                      "usageAllowedWithExhaustedQuota": False, "overageAllowedWithExhaustedQuota": False},
      "premium_interactions": {"isUnlimitedEntitlement": False, "entitlementRequests": 1500,
                               "usedRequests": 375, "remainingPercentage": 75.0, "overage": 0,
                               "resetDate": "2026-09-18T20:32:32.698Z",
                               "usageAllowedWithExhaustedQuota": False,
                               "overageAllowedWithExhaustedQuota": False},
    }

  auth: dict = {"authInfo": {"type": "gh-cli", "host": "https://github.com", "login": login,
                             "copilotUser": {"login": login, "copilot_plan": plan,
                                             "quota_reset_date_utc": reset}}}
  if signed_out:
    auth = {}

  scenario: dict = {
    "connect": {"ok": True, "protocolVersion": 3, "version": "1.0.86", "taskKinds": ["agent", "shell"]},
    "account.getCurrentAuth": {"__error__": auth_error} if auth_error else auth,
    "account.getQuota": {"__error__": quota_error} if quota_error else {"quotaSnapshots": snapshots},
  }
  path.write_text(json.dumps(scenario), encoding="utf-8")
  return path

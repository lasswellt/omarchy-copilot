# Copilot (Omarchy plugin) — scaffold

An [Omarchy](https://omarchy.org) bar widget for the GitHub Copilot CLI,
modeled on the structure of
[omarchy-tesla](https://github.com/nixfred/omarchy-tesla) and on
[omarchy-antigravity](../omarchy-antigravity) (same author, same pattern).

**Read [`findings.md`](findings.md) first.** Short version: yes, Copilot's
local data (`~/.cache/copilot/copilot-user-cache.json` for quota,
`~/.copilot/session-store.db` for sessions/tokens) fits the built-in Agents
panel's record contract almost exactly, confirmed by dropping a synthetic
record into its usage dir and tracing the adoption path in
`agents/Main.qml` — same method `omarchy-antigravity/roadmap.md` used, and
it worked here too, with less uncertainty than Antigravity's case (no
protobuf blobs, no unconfirmed quota RPC — the numbers are just sitting in
plain JSON already).

Right now `Panel.qml` only shows a placeholder "GH" bar icon. No real data
collector yet — see `findings.md`, "Next steps".

## Dev loop

This directory is the source of truth. The installed copy at
`~/.config/omarchy/plugins/lasswellt.copilot` is a separate git clone
pulling from this repo (or its remote, once pushed).

```bash
# after editing here
cd ~/Projects/omarchy-copilot
git add -A && git commit -m "..."
omarchy plugin update lasswellt.copilot --yes
```

## Install

```bash
omarchy plugin add ~/Projects/omarchy-copilot --enable
```

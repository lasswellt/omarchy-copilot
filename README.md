# Copilot (Omarchy plugin) — scaffold

An [Omarchy](https://omarchy.org) bar widget for the GitHub Copilot CLI,
modeled on the structure of
[omarchy-tesla](https://github.com/nixfred/omarchy-tesla).

**Read [`findings.md`](findings.md) first.** Short version: Copilot's local
data — `~/.cache/copilot/copilot-user-cache.json` for quota,
`~/.copilot/session-store.db` for sessions and tokens — fits the built-in
Agents panel's record contract almost exactly. Confirmed empirically by
dropping a synthetic record into the panel's usage dir and tracing the
adoption path in `agents/Main.qml`. The numbers are sitting in plain JSON
already: no protobuf blobs to decode, no unconfirmed quota RPC.

Right now `Panel.qml` only shows a placeholder "GH" bar icon. No real data
collector yet — see `findings.md`, "Next steps".

## Dev loop

This directory is the source of truth. The installed copy at
`~/.config/omarchy/plugins/lasswellt.copilot` is a separate git clone
pulling from this repo's remote,
<https://github.com/lasswellt/omarchy-copilot>.

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

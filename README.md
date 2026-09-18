# Copilot (Omarchy plugin) — stub

An early scaffold for an [Omarchy](https://omarchy.org) bar widget for the
GitHub Copilot CLI, modeled on the structure of
[omarchy-tesla](https://github.com/nixfred/omarchy-tesla) and on
[omarchy-antigravity](../omarchy-antigravity) (same author, same pattern —
see that project's `findings.md`/`roadmap.md` for the research process this
one will likely repeat).

Right now this only proves the plugin loads and shows a placeholder "GH"
icon in the bar. No real data yet.

## Open questions before building the real thing

- Does the Copilot CLI (`~/.local/share/gh/copilot`, or the mise-managed
  `copilot` wrapper — see `omarchy-antigravity`'s sibling install notes,
  both installed on this machine) write any local session/usage state to
  disk, and where?
- Is there a usage/rate-limit API comparable to Anthropic's OAuth usage
  endpoint, or to what Antigravity's `RetrieveUserQuotaSummary` RPC turned
  out to expose (see `omarchy-antigravity/roadmap.md`)?
- **Worth checking first, before building a standalone widget at all:**
  `omarchy-antigravity/roadmap.md` found that the built-in Agents bar plugin
  (`omarchy.agents`, the one that already shows Claude Code/Codex/Fireworks)
  accepts *any* provider — it just watches
  `~/.local/state/omarchy/agents/usage/*.json` and has no allowlist. Dropping
  a `copilot.json` record there and writing a small
  `omarchy-agent-usage-copilot`-shaped collector might get Copilot a tab in
  that existing panel for less work than a whole separate plugin. Confirm
  this still holds before committing to the standalone-plugin path this repo
  currently assumes.

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

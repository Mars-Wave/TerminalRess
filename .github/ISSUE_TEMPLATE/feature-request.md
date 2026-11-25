---
name: Support for my tool
about: Ask TerminalRess to resume a program (CLI agent, REPL, editor...) instead of just pre-typing it
title: "Support <tool> resume"
labels: enhancement
---

**Tool**
Name, version (`<tool> --version`), install method:

**How do you resume it by hand?**
The exact command, e.g. `mytool resume --last` or `mytool --session <id>`:

**Where does it keep the session id?**
State file, env var, command-line flag, or "it doesn't":

**Reproduction**
1. Open a Windows Terminal tab and run: `...`
2. Close every Windows Terminal window.
3. Reopen Windows Terminal.

Expected: the tab comes back running `...`
Actual: (e.g. command pre-typed, wrong session, nothing)

**Did a `resumeHandlers` entry in `config.json` work?**
Paste what you tried:
```json
```

**Diagnostics**
- `Get-TerminalRessStatus | Select-Object -ExpandProperty TrackedTabs | Format-List` (before closing):
- The tab's `%LOCALAPPDATA%\TerminalRess\live\<pid>.run.json` (remove secrets):
- Windows / Windows Terminal / PowerShell / TerminalRess versions:

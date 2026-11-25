# TerminalRess

[![CI](https://github.com/Mars-Wave/TerminalRess/actions/workflows/ci.yml/badge.svg)](https://github.com/Mars-Wave/TerminalRess/actions/workflows/ci.yml)
[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/TerminalRess)](https://www.powershellgallery.com/packages/TerminalRess)
![Platform: Windows only](https://img.shields.io/badge/platform-Windows%20only-0078D6)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

Brings your Windows Terminal tabs back after the terminal goes away: close-all, crash, force-kill, logoff, reboot or power loss.
Windows only (Windows Terminal + Windows PowerShell 5.1 or PowerShell 7).

Each tab comes back, in order, with its directory and the environment variables you set in it, plus:

- **Claude Code** resumed on the session the tab is on *now* (after `/resume` or `/clear` too), with its original flags.
  Sessions moved to Claude's background daemon are followed: the tab reattaches with `claude attach` while the session
  still runs, and resumes it otherwise.
- Interactive programs on a short allowlist (`nvim`, `ssh`, `less`, `htop`, ...) started again.
- Anything else that was running (`git push`, a build, a deploy) **pre-typed, not run**. Press Enter if you still want it.

Tabs you closed yourself, or left with `exit`, stay closed.

## Install

```powershell
Install-Module TerminalRess -Scope CurrentUser
Install-TerminalRess          # once per PowerShell edition; -NoLogonRestore, -NoLaunchRestore, -ProfileScope AllHosts
```

This adds two marked blocks to your profile (backed up first), a hidden background process (the guardian) and an optional
logon shortcut for reboots. `Uninstall-TerminalRess [-Purge]` removes everything. Updates from `Update-Module` apply on their
own, at the latest within 5 minutes; tabs already open pick them up when reopened.

| Command | |
|---|---|
| `Get-TerminalRessStatus` | tracked tabs, what each is running, guardian state, versions |
| `Restore-TerminalRess [-DryRun]` | restore the saved tabs now, in a new window |
| `Register-TerminalRessExisting` | track tabs opened before installing (run by `Install-TerminalRess`) |
| `Start-TerminalRessGuardian` / `Stop-TerminalRessGuardian` | manage the guardian |

## How it works

- A profile hook records each tab's directory, environment changes and the command being run at every prompt.
- The guardian notices what each tab is running and works out how to resume it. When a tab's shell dies, it decides
  whether you closed the tab (forgotten) or the whole terminal ended (kept in `last\`).
- The next time a terminal opens, its first tab reopens every saved tab in that window and closes itself.

State lives in `%LOCALAPPDATA%\TerminalRess`.

## Configuration

`%LOCALAPPDATA%\TerminalRess\config.json`:

| Key | Default | |
|---|---|---|
| `replayAllowlist` | `nvim`, `vim`, `ssh`, `less`, `htop`, ... | programs started again instead of pre-typed |
| `resumeHandlers` | `[]` | how to resume other tools, e.g. `{ "exe": "codex.exe", "command": ["{exe}", "resume", "--last"] }` (`{argv}` = original arguments) |
| `envDenylist` | `WT_*`, `CLAUDE*`, `PSModulePath`, ... | variables never saved |
| `profileArgs` | `[]` | text appended to restored tabs' command line as a trailing comment (`# --skip-vcvars`), visible to your profile in `[Environment]::GetCommandLineArgs()` |
| `profileEnv` | `{}` | variables set only while your profile runs in a restored tab |
| `restoreOnLaunch` / `restoreOnLogon` | `true` | when to restore |
| `graceSeconds` | `5` | how long a dead tab waits before it is judged |
| `wtPath` | `null` | path to `wt.exe` if it is not found |

Restored tabs also set `TERMINALRESS_RESTORING=1` while your profile runs, so a profile can skip questions it asks at start-up.

## Limitations

- Only PowerShell tabs are tracked. A PowerShell started inside a `cmd` or WSL tab counts as a tab.
- Window layout, panes (they come back as tabs), titles and scrollback are not restored.
- Background work running *inside* a program (for example a workflow inside a foreground Claude Code session) is not:
  the program is restarted, not the work. Move long work to a background session first.
- Environment variables are stored in plain text under your profile. Add secrets to `envDenylist`.
  Lines that look like they hold passwords or tokens are never recorded.
- Claude Code support relies on files Claude keeps in `~/.claude`, which are not a public interface.

Want your own tool resumed properly? [Open a request](https://github.com/Mars-Wave/TerminalRess/issues/new?template=feature-request.md).

## Development

`powershell -File tests\Run-Tests.ps1` runs the tests without touching your terminal. `tests\E2E.ps1` is a destructive
end-to-end test and `tests\Bench-Guardian.ps1` measures the guardian. Pushing a `v<version>` tag that matches the manifest
publishes to the PowerShell Gallery.

## License

[Apache-2.0](LICENSE). If you redistribute TerminalRess or build on it, keep the [NOTICE](NOTICE) file.
If it saves you time, you can [sponsor its development](https://github.com/sponsors/Mars-Wave).

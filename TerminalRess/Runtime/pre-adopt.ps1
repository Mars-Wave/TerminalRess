# TerminalRess pre-adopt. Dot-sourced by the pre-hook at the TOP of the profile, but only when state\last\ holds tab files
# (or a dead tab is waiting to be swept into it).
# This shell is only a LAUNCHER: it opens ALL saved tabs as new tabs of its own window (wt -w 0 new-tab ..., original order,
# exactly like Restore-TerminalRess does), then ends the process with code 0 so Windows Terminal closes the launcher tab. The rest of the
# profile never runs here; every restored tab runs it itself through restore-tab.ps1.

if (-not $env:WT_SESSION) { return }
if ($env:CLAUDECODE) { return }
if ($env:TERMINALRESS_RESTORING -eq '1') { return }

$trSpawned = 0
try {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $trOwner = Get-TROwnerWt $PID
    if ($env:TERMINALRESS_FORCE -ne '1' -and $trOwner.ParentName -notin 'OpenConsole', 'WindowsTerminal') { return }
    if (-not (Get-TRConfig).restoreOnLaunch) { return }
    $trSpawned = Invoke-TRSpawnAll $trOwner
} catch { $trSpawned = 0 }
Remove-Variable trOwner -ErrorAction SilentlyContinue
# `exit` would only leave this dot-sourced script (and the profile), not the shell, so end the process itself.
if ($trSpawned -gt 0) { [Environment]::Exit(0) }
Remove-Variable trSpawned -ErrorAction SilentlyContinue

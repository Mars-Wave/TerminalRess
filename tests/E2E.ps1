# DESTRUCTIVE end-to-end test. Requires: TerminalRess installed (Install-TerminalRess), Windows Terminal NOT running.
# It opens a throw-away WT with 4 tabs, kills WindowsTerminal.exe, checks last\, launches plain wt (as a user would),
# checks the restore, and closes only what it created.  Usage: powershell -File tests\E2E.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TerminalRess\TerminalRess.psd1') -Force
$sid = (Get-Process -Id $PID).SessionId
if (@([Diagnostics.Process]::GetProcessesByName('WindowsTerminal') | Where-Object SessionId -eq $sid).Count) { throw 'Windows Terminal is running: refusing to run the destructive test.' }
foreach ($n in 'CLAUDECODE', 'NO_COLOR', 'GIT_TERMINAL_PROMPT', 'WT_SESSION') { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
$wt = & (Get-Module TerminalRess) { Get-TRWtPath }
$dir = Join-Path $env:LOCALAPPDATA ("Temp\TR-e2e-dir $([char]0xe1)")
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$psx = 'powershell.exe'
$t1 = "new-tab $psx -NoExit -Command `"# --skip-vcvars`" ; "
# tab commands are typed through -Command so the hook (profile) loads normally
$cmd = @(
    "-w new new-tab -d `"$dir`" $psx -NoExit -Command `"`$env:E2E_VAR='custom-value'; Set-Location '$dir'; # --skip-vcvars`"",
    "new-tab $psx -NoExit -Command `"# --vcvars 64`"",
    "new-tab $psx -NoExit -Command `"# --skip-vcvars`"",
    "new-tab $psx -NoExit -Command `"# --skip-vcvars`""
) -join ' ; '
Write-Host 'Launching throw-away WT (4 tabs). Type in the tabs: tab2 `ping -t 127.0.0.1`, tab3 `nvim`, tab4 `echo hi`.'
Write-Host 'Press Enter here when the tabs are ready, then the script kills WT, relaunches plain wt and prints the result.'
Start-Process $wt $cmd
[void](Read-Host)
Get-TerminalRessStatus | Select-Object -ExpandProperty TrackedTabs | Format-Table ShellPid, Alive, Cwd, Running, Pending, LastCommand -AutoSize
Get-Process WindowsTerminal | Where-Object SessionId -eq $sid | Stop-Process -Force
Start-Sleep 9
"last generation: " + (Get-TerminalRessStatus).LastGeneration.Count
Start-Process $wt
Start-Sleep 12
Get-TerminalRessStatus | Select-Object -ExpandProperty TrackedTabs | Format-Table ShellPid, Alive, Cwd, Running, Pending, LastCommand -AutoSize
Write-Host 'Check the new window visually (4 tabs, E2E_VAR, ping running, nvim open, echo hi pre-typed). Close it yourself.'

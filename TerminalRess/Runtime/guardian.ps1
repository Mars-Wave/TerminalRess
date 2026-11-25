# TerminalRess guardian: single hidden instance per state dir. Every ~3 s it records each tab's foreground child
# (live\<pid>.run.json) and, when a tab shell dies, decides whether the user closed the tab or Windows Terminal ended.
param([int]$IntervalSec = 3, [switch]$Once)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Initialize-TRDirs

$created = $false
$mutex = New-Object Threading.Mutex($false, (Get-TRMutexName 'Guardian'), [ref]$created)
if (-not $created -or (Test-TRLegacyGuardian)) { exit 0 }
[IO.File]::WriteAllText((Join-Path $TR_State 'guardian.pid'), [string]$PID, $TR_Utf8)

$cfg = Get-TRConfig
$grace = [int]$cfg.graceSeconds
$mySession = Get-TRSessionId
$deadSince = @{}     # shellPid -> first seen dead
$noChild   = @{}     # shellPid -> consecutive loops without a foreground child
$runSig    = @{}     # shellPid -> last written signature
$ignoreNames = 'conhost.exe', 'OpenConsole.exe'
Write-TRLog "guardian started pid=$PID session=$mySession state=$TR_State"

function Get-RunInfo($child, $shellPid) {
    $argv = @()
    try { if ($child.CommandLine) { $argv = Get-TRArgv $child.CommandLine } } catch { }
    $info = [ordered]@{ shellPid = $shellPid; childPid = [int]$child.ProcessId; name = $child.Name; exe = $child.ExecutablePath; commandLine = $child.CommandLine; argv = $argv }
    $resume = Get-TRResumeCommand $child $argv
    if ($resume) { $info['resume'] = $resume }
    $info
}

function Invoke-Tick {
    $files = @(Get-TRTabFiles $TR_Live)
    if ($files.Count -eq 0) { return }
    $snap = $null; $byId = @{}
    foreach ($f in $files) {
        $tab = Read-TRJson $f.FullName
        if (-not $tab) { continue }
        if (-not $snap) {          # one CIM query per loop, only when there is something to look at
            $snap = Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CommandLine,ExecutablePath,CreationDate
            foreach ($p in $snap) { $byId[[uint32]$p.ProcessId] = $p }
        }
        $spid = [int]$tab.shellPid
        if (Test-TRShellAlive $tab $byId) {
            $deadSince.Remove($spid)
            if ((Get-TRTabSession $tab) -ne $mySession) { continue }
            $shell = $byId[[uint32]$spid]
            $kids = @($snap | Where-Object { $_.ParentProcessId -eq $spid -and $_.Name -notin $ignoreNames -and $_.CreationDate -ge $shell.CreationDate -and $_.CommandLine -notlike '*guardian.ps1*' })   # the guardian itself is spawned by the first tab: not a foreground program
            $runPath = Get-TRRunPath $f.FullName
            if ($kids.Count -eq 0) {
                $noChild[$spid] = 1 + [int]$noChild[$spid]
                # two consecutive empty loops: avoids deleting the run file while a dying WT takes children first
                if ($noChild[$spid] -ge 2 -and (Test-Path -LiteralPath $runPath)) { Remove-Item -LiteralPath $runPath -Force -ErrorAction SilentlyContinue; $runSig.Remove($spid) }
                continue
            }
            $noChild[$spid] = 0
            $child = @($kids | Where-Object { $_.Name -ieq 'claude.exe' } | Select-Object -First 1)[0]
            if (-not $child) { $child = @($kids | Sort-Object CreationDate -Descending | Select-Object -First 1)[0] }
            $info = Get-RunInfo $child $spid
            $sig = $info | ConvertTo-Json -Depth 6 -Compress
            if ($runSig[$spid] -ne $sig -or -not (Test-Path -LiteralPath $runPath)) {
                $info['updatedAt'] = [DateTime]::UtcNow.ToString('o')
                Write-TRJson $runPath $info
                $runSig[$spid] = $sig
            }
        } else {
            if (-not $deadSince.ContainsKey($spid)) { $deadSince[$spid] = Get-Date }
            if (((Get-Date) - $deadSince[$spid]).TotalSeconds -ge $grace) {
                $r = Resolve-TRDeadTab $f $tab
                Write-TRLog "shell $spid dead -> $r"
                $deadSince.Remove($spid); $noChild.Remove($spid); $runSig.Remove($spid)
            }
        }
    }
}

try {
    do {
        try { Invoke-Tick } catch { Write-TRLog "tick error: $($_.Exception.Message)" }
        if ($Once) { break }
        Start-Sleep -Seconds $IntervalSec
    } while ($true)
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    Remove-Item -LiteralPath (Join-Path $TR_State 'guardian.pid') -Force -ErrorAction SilentlyContinue
}

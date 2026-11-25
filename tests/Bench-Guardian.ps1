# Guardian cost benchmark. Isolated: own state dir, own runtime path, throw-away shells it starts and kills itself.
#   powershell -File tests\Bench-Guardian.ps1 [-RuntimeDir <Runtime folder>] [-Tabs 13] [-Ticks 40] [-LiveSeconds 60]
# Tick mode times the guardian's per-loop work in this process; -LiveSeconds also runs the real guardian.ps1 against the
# same state and reports its CPU use. -RuntimeDir may point at an older Runtime\ (e.g. extracted with git archive).
param([string]$RuntimeDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'TerminalRess\Runtime'), [int]$Tabs = 13, [int]$Ticks = 40, [int]$LiveSeconds = 0)
$ErrorActionPreference = 'Stop'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work = Join-Path $env:LOCALAPPDATA ('Temp\TerminalRessBench\' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:TERMINALRESS_STATE = Join-Path $work 'state'
$env:TERMINALRESS_RUNTIME = Join-Path $work 'no-runtime'        # never the installed runtime
$env:TERMINALRESS_MODULEROOTS = Join-Path $work 'no-modules'
$env:TERMINALRESS_DRYRUN = '1'
$env:CLAUDE_CONFIG_DIR = Join-Path $work 'claude'
$live = Join-Path $env:TERMINALRESS_STATE 'live'
foreach ($d in $live, (Join-Path $env:CLAUDE_CONFIG_DIR 'sessions')) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') (Join-Path $work 'claude.exe')

$mine = @(); $guardian = $null
try {
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    for ($i = 0; $i -lt $Tabs; $i++) {
        $kind = $i % 4      # 0 idle, 1 ping, 2 claude, 3 idle
        $cmd = switch ($kind) { 1 { 'ping -n 900 127.0.0.1 | Out-Null' } 2 { "& '$work\claude.exe' /c ping -n 900 127.0.0.1 | Out-Null" } default { 'Start-Sleep 900' } }
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $p = Start-Process $psExe -ArgumentList "-NoProfile -EncodedCommand $enc" -WindowStyle Hidden -PassThru
        $mine += $p
        $tab = [ordered]@{ shellPid = $p.Id; shellStart = $p.StartTime.Ticks; shellExe = $psExe; session = $session; wtSession = "bench-$i"; cwd = $work; envDiff = @{ A = 'b' }; lastCommand = 'dir'; pendingCommand = $cmd; updatedAt = 'now' }
        [IO.File]::WriteAllText((Join-Path $live "$($p.Id).json"), ($tab | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    }
    Start-Sleep 3     # children up
    foreach ($c in Get-CimInstance Win32_Process -Filter "Name='claude.exe'") {
        if ($mine.Id -contains [int]$c.ParentProcessId) {
            [IO.File]::WriteAllText((Join-Path $env:CLAUDE_CONFIG_DIR "sessions\$($c.ProcessId).json"), '{"pid":' + $c.ProcessId + ',"sessionId":"44444444-4444-4444-4444-444444444444","cwd":"C:\\"}')
        }
    }

    . (Join-Path $RuntimeDir 'Common.ps1')
    Initialize-TRDirs
    $new = [bool](Get-Command Invoke-TRGuardianTick -ErrorAction SilentlyContinue)
    if ($new) { $G = New-TRGuardianState; $tick = { Invoke-TRGuardianTick $G } }
    else {
        # pre-change guardian: its tick functions and the script variables they use
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RuntimeDir 'guardian.ps1'), [ref]$null, [ref]$null)
        foreach ($f in $ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            if ($f.Name -in 'Get-RunInfo', 'Invoke-Tick') { . ([scriptblock]::Create($f.Extent.Text)) }
        }
        $grace = 5; $mySession = Get-TRSessionId; $deadSince = @{}; $noChild = @{}; $runSig = @{}; $ignoreNames = 'conhost.exe', 'OpenConsole.exe'
        $tick = { Invoke-Tick; $true }
    }
    $me = [Diagnostics.Process]::GetCurrentProcess()
    $acts = @(); for ($i = 0; $i -lt 3; $i++) { $acts += [bool](& $tick) }      # warm-up (first-use loads, run files written)
    $ms = New-Object 'Collections.Generic.List[double]'
    $me.Refresh(); $cpu0 = $me.TotalProcessorTime
    for ($i = 0; $i -lt $Ticks; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew(); $acts += [bool](& $tick); $sw.Stop(); $ms.Add($sw.Elapsed.TotalMilliseconds)
    }
    $me.Refresh(); $cpu = ($me.TotalProcessorTime - $cpu0).TotalMilliseconds / $Ticks
    $sorted = @($ms | Sort-Object)
    $runs = @(Get-ChildItem $live -Filter '*.run.json' | ForEach-Object { $r = Read-TRJson $_.FullName; $r.name + $(if ($r.resume.sessionId) { '+session' }) })
    "runtime    : $RuntimeDir ($(if ($new) { 'new' } else { 'old' }) tick)"
    "tabs       : $Tabs live shells, run files: $($runs -join ', ')"
    "tick wall  : mean {0:N1} ms, median {1:N1} ms, max {2:N1} ms over $Ticks ticks" -f ($ms | Measure-Object -Average).Average, $sorted[[int]($sorted.Count / 2)], $sorted[-1]
    "tick cpu   : {0:N1} ms" -f $cpu
    if ($new) { "activity   : " + (($acts | ForEach-Object { if ($_) { 'A' } else { '.' } }) -join '') + "  (A = active tick; $($G.IdleAfter) idle ticks in a row switch to the idle interval)" }

    if ($LiveSeconds -gt 0) {
        $guardian = Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $RuntimeDir 'guardian.ps1')`"" -WindowStyle Hidden -PassThru
        Start-Sleep 20      # startup, first ticks, idle back-off
        $guardian.Refresh(); $c0 = $guardian.TotalProcessorTime; $t0 = [DateTime]::UtcNow
        Start-Sleep $LiveSeconds
        $guardian.Refresh(); $c1 = $guardian.TotalProcessorTime
        "live       : guardian.ps1 used {0:N2}% of one core over {1} s (steady state), working set {2:N0} MB" -f (100 * ($c1 - $c0).TotalMilliseconds / ([DateTime]::UtcNow - $t0).TotalMilliseconds), $LiveSeconds, ($guardian.WorkingSet64 / 1MB)
    }
} finally {
    if ($guardian -and -not $guardian.HasExited) { $guardian.Kill() }
    # only what this script started: its shells and their descendants
    $all = @(Get-CimInstance Win32_Process); $front = @($mine.Id); $kill = @($front)
    while ($front.Count) { $front = @($all | Where-Object { $front -contains $_.ParentProcessId -and $_.Name -ne 'conhost.exe' } | ForEach-Object { [int]$_.ProcessId }); $kill += $front }
    Stop-Process -Id $kill -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

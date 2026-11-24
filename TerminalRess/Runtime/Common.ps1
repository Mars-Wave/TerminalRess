# TerminalRess shared library.
# Dot-sourced by the module, by the hook (inside a user's profile), by the guardian,
# by restore-tab and by startup.ps1. Keep it dependency free and Windows PowerShell 5.1 compatible.
# ASCII only: PowerShell 5.1 reads BOM-less files as ANSI.

$script:TR_Runtime = $PSScriptRoot
$script:TR_Home    = if ($env:TERMINALRESS_STATE) { $env:TERMINALRESS_STATE } else { Join-Path $env:LOCALAPPDATA 'TerminalRess' }
$script:TR_State   = $script:TR_Home
$script:TR_Live    = Join-Path $script:TR_State 'live'
$script:TR_Last    = Join-Path $script:TR_State 'last'
$script:TR_Archive = Join-Path $script:TR_State 'archive'
$script:TR_Utf8    = New-Object Text.UTF8Encoding $false
$script:TR_InstalledRuntime = Join-Path $env:LOCALAPPDATA 'TerminalRess\runtime'
$script:TR_ScrubRegex = '^(CLAUDE|NO_COLOR$|GIT_TERMINAL_PROMPT$|WT_SESSION$|WT_PROFILE_ID$|POSH_|TERMINALRESS_RESTORING$|TERMINALRESS_FORCE$)'
$script:TR_ConfigCache = $null

# ---------------------------------------------------------------- config
function Get-TRDefaultConfig {
    [ordered]@{
        envDenylist     = @('WT_*', 'POSH_*', 'CLAUDE*', 'CLAUDECODE', 'NO_COLOR', 'GIT_TERMINAL_PROMPT', 'TERMINALRESS_*',
                            'PSModulePath', '_', 'PROMPT', 'PWD', 'OLDPWD', 'COLUMNS', 'LINES', 'TERM_*', 'SESSIONNAME',
                            'PSExecutionPolicyPreference', '__*')
        # Programs that are re-executed on restore (matched on the guardian's child exe name, not the typed text).
        # Everything else that was running is only PRE-TYPED. Resume handlers (claude, ...) always resume.
        replayAllowlist = @('nvim', 'vim', 'vi', 'nano', 'less', 'more', 'man', 'ssh', 'htop', 'btop', 'top', 'lazygit')
        restoreOnLaunch = $true
        restoreOnLogon  = $true
        graceSeconds    = 5
        wtPath          = $null
        resumeHandlers  = @()
        # Strings appended to every restored tab's shell command line (as a trailing comment, so the profile sees them in
        # [Environment]::GetCommandLineArgs()), e.g. @('--skip-vcvars').
        profileArgs     = @()
        # Environment variables set BEFORE the profile runs in every restored tab and removed afterwards (unless the saved
        # tab has that variable in its environment, which then wins and stays), e.g. @{ PROFILE_VCVARS = 'skip' }.
        profileEnv      = @{}
    }
}
function Get-TRConfig {
    param([switch]$Fresh)
    if ($script:TR_ConfigCache -and -not $Fresh) { return $script:TR_ConfigCache }
    $cfg = Get-TRDefaultConfig
    $p = Join-Path $script:TR_State 'config.json'
    if (Test-Path -LiteralPath $p) {
        $u = Read-TRJson $p
        if ($u) { foreach ($k in @($cfg.Keys)) { if ($u.PSObject.Properties[$k] -and $null -ne $u.$k) { $cfg[$k] = $u.$k } } }
    }
    $script:TR_ConfigCache = [pscustomobject]$cfg
    $script:TR_ConfigCache
}
function ConvertTo-TRWildcardRegex([string[]]$Patterns) {
    $alts = foreach ($p in $Patterns) { if ($p) { ([regex]::Escape($p)).Replace('\*', '.*').Replace('\?', '.') } }
    New-Object Text.RegularExpressions.Regex ('^(?:' + ($alts -join '|') + ')$'), 'IgnoreCase'
}

# ---------------------------------------------------------------- io
function Initialize-TRDirs { foreach ($d in $script:TR_State, $script:TR_Live, $script:TR_Last, $script:TR_Archive) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } } }
function Read-TRJson([string]$Path) { try { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null } }
function Write-TRJson([string]$Path, $Obj) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 6 -Compress), $script:TR_Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Write-TRLog([string]$Message) {
    try {
        $log = Join-Path $script:TR_State 'guardian.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 200KB) { Move-Item -LiteralPath $log "$log.old" -Force }
        [IO.File]::AppendAllText($log, ("{0:s} {1}`r`n" -f (Get-Date), $Message), $script:TR_Utf8)
    } catch { }
}
function Get-TRHash([string]$s) {
    $md5 = [Security.Cryptography.MD5]::Create()
    (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLowerInvariant())) | Select-Object -First 4 | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Get-TRMutexName([string]$Kind) { "Local\TerminalRess-$Kind-" + (Get-TRHash $script:TR_State) }
function Get-TRSessionId { [Diagnostics.Process]::GetCurrentProcess().SessionId }
function Get-TRRuntimeDir {
    if (Test-Path -LiteralPath (Join-Path $script:TR_InstalledRuntime 'guardian.ps1')) { $script:TR_InstalledRuntime } else { $script:TR_Runtime }
}

# ---------------------------------------------------------------- tab files
function Get-TRTabFiles([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File | Where-Object { $_.Name -notlike '*.run.json' })
}
function Get-TRRunPath([string]$TabPath) { $TabPath -replace '\.json$', '.run.json' }
function Remove-TRTabFiles([string]$TabPath) {
    foreach ($p in @($TabPath, (Get-TRRunPath $TabPath))) { if (Test-Path -LiteralPath $p) { [IO.File]::Delete($p) } }
}
function Move-TRTabFiles([string]$TabPath, [string]$DestDir) {
    foreach ($p in @($TabPath, (Get-TRRunPath $TabPath))) {
        if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination $DestDir -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- liveness
# $ById: optional CIM snapshot map (guardian). Without it, .NET Get-Process is used (cheap, no CIM).
function Test-TRShellAlive($Tab, $ById) {
    $ticks = [int64]$Tab.shellStart
    if ($ById) {
        $p = $ById[[uint32]$Tab.shellPid]
        if (-not $p -or -not $p.CreationDate) { return $false }
        return ([math]::Abs($p.CreationDate.Ticks - $ticks) -lt 30000000)
    }
    try { $p = [Diagnostics.Process]::GetProcessById([int]$Tab.shellPid); return ([math]::Abs($p.StartTime.Ticks - $ticks) -lt 30000000) } catch { return $false }
}
function Get-TRWtProcesses($SessionId) {
    @([Diagnostics.Process]::GetProcessesByName('WindowsTerminal') | Where-Object { $null -eq $SessionId -or $_.SessionId -eq $SessionId })
}
function Get-TRTabSession($Tab) { if ($null -ne $Tab.session) { [int]$Tab.session } else { Get-TRSessionId } }

# The WT that owns a tab is recorded in the tab file (wtPid + wtStart, walked shell -> OpenConsole -> WindowsTerminal).
# $true/$false = owner alive/gone, $null = owner unknown.
function Test-TROwnerAlive($Tab) {
    if (-not $Tab.wtPid -or -not $Tab.wtStart) { return $null }
    try { $p = [Diagnostics.Process]::GetProcessById([int]$Tab.wtPid); return ([math]::Abs($p.StartTime.Ticks - [int64]$Tab.wtStart) -lt 30000000) } catch { return $false }
}
# A dead tab shell: owning WT still alive -> the user closed the tab ('closed'); owner gone -> 'ended' (previous generation).
# Owner unknown: any WT that was already running when the shell started counts as the owner.
function Get-TRDeadTabVerdict($Tab) {
    $o = Test-TROwnerAlive $Tab
    if ($o -eq $true) { return 'closed' }
    if ($o -eq $false) { return 'ended' }
    $started = [datetime]::new([int64]$Tab.shellStart)
    foreach ($w in (Get-TRWtProcesses (Get-TRTabSession $Tab))) {
        try { if ($w.StartTime -le $started.AddSeconds(1)) { return 'closed' } } catch { }
    }
    'ended'
}
function Resolve-TRDeadTab($TabFile, $Tab) {
    # a typed `exit` is a deliberate close, even when it ends the last tab and WT with it
    if ($Tab.exiting -or (Get-TRDeadTabVerdict $Tab) -eq 'closed') { Remove-TRTabFiles $TabFile.FullName; return 'deleted' }
    Move-TRTabFiles $TabFile.FullName $script:TR_Last; 'moved'
}
# Moves dead tabs of an ended generation into last\ (typed-exit tabs are dropped). Other deletions need the guardian grace period.
function Invoke-TRSweep {
    Initialize-TRDirs
    foreach ($f in Get-TRTabFiles $script:TR_Live) {
        $tab = Read-TRJson $f.FullName
        if (-not $tab -or (Test-TRShellAlive $tab $null)) { continue }
        if ($tab.exiting) { Remove-TRTabFiles $f.FullName; continue }
        if ((Get-TRDeadTabVerdict $tab) -eq 'ended') { Move-TRTabFiles $f.FullName $script:TR_Last }
    }
}
# shell -> OpenConsole -> WindowsTerminal. Returns @{ ParentName; Pid; Start; Path } (Pid/Start/Path null when not found).
function Get-TROwnerWt([int]$ShellPid = $PID) {
    $r = [ordered]@{ ParentName = $null; Pid = $null; Start = $null; Path = $null }
    try {
        $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$ShellPid" -Property ParentProcessId -ErrorAction Stop).ParentProcessId
        $parent = [Diagnostics.Process]::GetProcessById([int]$ppid)
        $r.ParentName = $parent.ProcessName
        $wtp = $null
        if ($parent.ProcessName -eq 'WindowsTerminal') { $wtp = $parent }
        elseif ($parent.ProcessName -eq 'OpenConsole') {
            $gp = (Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -Property ParentProcessId -ErrorAction Stop).ParentProcessId
            $c = [Diagnostics.Process]::GetProcessById([int]$gp)
            if ($c.ProcessName -eq 'WindowsTerminal') { $wtp = $c }
        }
        if ($wtp) {
            $r.Pid = $wtp.Id; $r.Start = $wtp.StartTime.Ticks
            try { $r.Path = $wtp.MainModule.FileName } catch { }
        }
    } catch { }
    [pscustomobject]$r
}
function Get-TRLiveAliveTabs([int]$ExceptPid = 0) {
    foreach ($f in Get-TRTabFiles $script:TR_Live) {
        $t = Read-TRJson $f.FullName
        if ($t -and [int]$t.shellPid -ne $ExceptPid -and (Test-TRShellAlive $t $null)) { $t }
    }
}

# ---------------------------------------------------------------- processes
function Start-TRProcess {
    # Launches a process with the Claude-Code / tool-shell environment removed (so tabs render with colour).
    param([string]$FilePath, [string]$Arguments, [switch]$Hidden)
    if ($env:TERMINALRESS_DRYRUN -eq '1') {
        [IO.File]::AppendAllText((Join-Path $script:TR_State 'dryrun.log'), "$FilePath $Arguments`r`n", $script:TR_Utf8); return
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath; $psi.Arguments = $Arguments; $psi.UseShellExecute = $false
    if ($Hidden) { $psi.CreateNoWindow = $true }
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -match $script:TR_ScrubRegex) { $psi.EnvironmentVariables.Remove($k) } }
    [void][Diagnostics.Process]::Start($psi)
}
function Get-TRWtPath($Owner) {
    # the wt.exe that sits next to the WindowsTerminal.exe that owns the current tab comes first, so a second
    # install (portable copy, preview) restores into ITS OWN terminal
    if ($Owner -and $Owner.Path) {
        $own = Join-Path (Split-Path $Owner.Path) 'wt.exe'
        if (Test-Path -LiteralPath $own) { return $own }
    }
    $cfg = Get-TRConfig
    if ($cfg.wtPath -and (Test-Path -LiteralPath $cfg.wtPath)) { return [string]$cfg.wtPath }
    $c = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\WindowsTerminal\wt.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Windows Terminal\wt.exe'),
        (Join-Path $env:ProgramFiles 'WindowsTerminal\wt.exe'),
        (Join-Path $HOME 'scoop\apps\windows-terminal\current\wt.exe'),
        (Join-Path $HOME 'scoop\apps\windows-terminal-preview\current\wt.exe'))
    foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
    foreach ($w in (Get-TRWtProcesses (Get-TRSessionId))) {
        try { $p = Join-Path (Split-Path $w.MainModule.FileName) 'wt.exe'; if (Test-Path -LiteralPath $p) { return $p } } catch { }
    }
    $null
}
function Test-TRGuardianRunning {
    $m = $null
    $r = [Threading.Mutex]::TryOpenExisting((Get-TRMutexName 'Guardian'), [ref]$m)
    if ($m) { $m.Dispose() }
    $r
}
function Start-TRGuardianProcess {
    if (Test-TRGuardianRunning) { return $false }
    Initialize-TRDirs
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path (Get-TRRuntimeDir) 'guardian.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
    # a test/alternate state dir must be inherited by the guardian: it is, through the environment.
    Start-TRProcess $psExe $arguments -Hidden
    $true
}

# ---------------------------------------------------------------- argv / resume handlers
function Get-TRArgv([string]$CommandLine) {
    if (-not ('TRNative.Args' -as [type])) {
        Add-Type -Namespace TRNative -Name Args -MemberDefinition @'
[DllImport("shell32.dll", SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cl, out int n);
[DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);
public static string[] Split(string cl) {
  int n; IntPtr p = CommandLineToArgvW(cl, out n);
  if (p == IntPtr.Zero) return new string[0];
  try { var r = new string[n]; for (int i = 0; i < n; i++) r[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size)); return r; }
  finally { LocalFree(p); }
}
'@
    }
    [string[]][TRNative.Args]::Split($CommandLine)
}

# Claude Code: keep the original flags, drop session selection / print / prompt, append --resume <id>.
function ConvertTo-TRClaudeResumeArgs([string[]]$Argv, [string]$SessionId) {
    $valueFlags    = 'model', 'permission-mode', 'settings', 'append-system-prompt', 'system-prompt', 'agent', 'agents', 'fallback-model', 'max-turns', 'output-format', 'input-format', 'name', 'n', 'setting-sources', 'betas', 'effort', 'permission-prompt-tool', 'max-budget-usd', 'ide-port', 'teammate-mode', 'debug-file'
    $variadicFlags = 'add-dir', 'allowedTools', 'allowed-tools', 'disallowedTools', 'disallowed-tools', 'mcp-config', 'plugin-dir', 'tools'
    $dropBool      = 'continue', 'c', 'fork-session', 'print', 'p'
    $out = New-Object 'Collections.Generic.List[string]'
    $i = 1
    while ($i -lt $Argv.Count) {
        $a = $Argv[$i]
        if ($a -eq '--') { break }
        if ($a -match '^--?([^=]+)=') {
            if ($Matches[1] -in 'resume', 'r', 'session-id') { $i++; continue }
            $out.Add($a); $i++; continue
        }
        if ($a -match '^--?(.+)$') {
            $n = $Matches[1]
            if ($n -in 'resume', 'r') { $i++; if ($i -lt $Argv.Count -and $Argv[$i] -notlike '-*') { $i++ }; continue }
            if ($n -eq 'session-id')  { $i++; if ($i -lt $Argv.Count) { $i++ }; continue }
            if ($n -in $dropBool)     { $i++; continue }
            $out.Add($a); $i++
            if ($n -in $valueFlags -and $i -lt $Argv.Count) { $out.Add($Argv[$i]); $i++ }
            elseif ($n -in $variadicFlags) { while ($i -lt $Argv.Count -and $Argv[$i] -notlike '-*') { $out.Add($Argv[$i]); $i++ } }
            continue
        }
        $i++   # positional prompt: dropped
    }
    if ($SessionId) { $out.Add('--resume'); $out.Add($SessionId) }
    ,$out.ToArray()
}
function Get-TRClaudeSessionsDir {
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    Join-Path $base 'sessions'
}
function Get-TRClaudeResume($Child, [string[]]$Argv) {
    $sid = $null; $cwd = $null
    $sf = Join-Path (Get-TRClaudeSessionsDir) "$($Child.ProcessId).json"
    if (Test-Path -LiteralPath $sf) { $s = Read-TRJson $sf; if ($s) { $sid = $s.sessionId; $cwd = $s.cwd } }
    if (-not $sid -and $Argv) {          # fallback: the command line
        for ($i = 1; $i -lt $Argv.Count - 1; $i++) { if ($Argv[$i] -in '--resume', '-r', '--session-id') { $sid = $Argv[$i + 1]; break } }
        if ($sid -notmatch '^[0-9a-fA-F-]{36}$') { $sid = $null }
    }
    $rargs = if ($sid) { ConvertTo-TRClaudeResumeArgs $Argv $sid } elseif ($Argv.Count -gt 1) { [string[]]$Argv[1..($Argv.Count - 1)] } else { @() }
    [ordered]@{ handler = 'claude'; exe = $Child.ExecutablePath; args = @($rargs); cwd = $cwd; sessionId = $sid }
}
# Handler registry: built-in claude + config.resumeHandlers entries
#   { "exe": "codex.exe", "command": ["{exe}", "resume", "--last"] }   ({argv} expands to the original arguments)
function Get-TRResumeCommand($Child, [string[]]$Argv) {
    $name = [string]$Child.Name
    if ($name -ieq 'claude.exe') { return (Get-TRClaudeResume $Child $Argv) }
    foreach ($h in @((Get-TRConfig).resumeHandlers)) {
        if (-not $h -or -not $h.exe -or $name -ine [string]$h.exe) { continue }
        $parts = New-Object 'Collections.Generic.List[string]'
        foreach ($c in @($h.command)) {
            if ($c -eq '{exe}') { $parts.Add([string]$Child.ExecutablePath) }
            elseif ($c -eq '{argv}') { if ($Argv.Count -gt 1) { foreach ($a in $Argv[1..($Argv.Count - 1)]) { $parts.Add($a) } } }
            else { $parts.Add([string]$c) }
        }
        if ($parts.Count -eq 0) { continue }
        $rest = if ($parts.Count -gt 1) { [string[]]$parts.GetRange(1, $parts.Count - 1).ToArray() } else { @() }
        return [ordered]@{ handler = [string]$h.exe; exe = $parts[0]; args = @($rest); cwd = $null; sessionId = $null }
    }
    $null
}

# ---------------------------------------------------------------- wt command lines
function ConvertTo-TRWtArg([string]$s) {
    $s = $s.Replace(';', '\;')
    if ($s -ne '' -and $s -notmatch '[\s"]') { return $s }
    $s = [regex]::Replace($s, '(\\*)"', '$1$1\"')
    $s = [regex]::Replace($s, '(\\+)$', '$1$1')
    '"' + $s + '"'
}
function New-TRTabArgs($Tab, [string]$TabFile) {
    $restoreTab = Join-Path (Get-TRRuntimeDir) 'restore-tab.ps1'
    $q = { param($x) "'" + ([string]$x).Replace("'", "''") + "'" }
    $inner = ". " + (& $q $restoreTab) + " " + (& $q $TabFile)
    $pa = @((Get-TRConfig).profileArgs | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { ("$_" -replace '[\r\n]+', ' ') })
    if ($pa.Count -gt 0) { $inner += ' # ' + ($pa -join ' ') }      # trailing comment: harmless to PowerShell, visible in GetCommandLineArgs()
    $shell = 'powershell.exe'
    if ($Tab.shellExe -and (Test-Path -LiteralPath $Tab.shellExe)) { $shell = [string]$Tab.shellExe }
    $a = @('new-tab')
    if ($Tab.cwd -and (Test-Path -LiteralPath $Tab.cwd -PathType Container)) { $a += '-d'; $a += [string]$Tab.cwd }
    $a += $shell, '-NoProfile', '-NoExit', '-Command', $inner
    ($a | ForEach-Object { ConvertTo-TRWtArg $_ }) -join ' '
}

function Get-TRLastTabs {
    $tabs = @()
    foreach ($f in Get-TRTabFiles $script:TR_Last) {
        $t = Read-TRJson $f.FullName
        if ($t -and $t.shellStart) { $tabs += [pscustomobject]@{ File = $f; Tab = $t } }
    }
    @($tabs | Sort-Object { [int64]$_.Tab.shellStart })
}
function Move-TRLastToArchive {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $arch = Join-Path $script:TR_Archive $stamp
    New-Item -ItemType Directory -Force -Path $arch | Out-Null
    Get-ChildItem -LiteralPath $script:TR_Last -File -ErrorAction SilentlyContinue | Move-Item -Destination $arch -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $script:TR_Archive -Directory | Sort-Object Name -Descending | Select-Object -Skip 5 | ForEach-Object { [IO.Directory]::Delete($_.FullName, $true) }
    $arch
}
function Enter-TRRestoreLock {
    $created = $false
    $m = New-Object Threading.Mutex($false, (Get-TRMutexName 'Restore'), [ref]$created)
    if ($m.WaitOne(0)) { return $m }
    $m.Dispose(); $null
}

# Restore everything into ONE NEW window (Restore-TerminalRess). -DryRun returns the wt arguments.
function Invoke-TRRestoreAll([switch]$DryRun) {
    Initialize-TRDirs
    $wt = Get-TRWtPath
    if (-not $wt) { throw 'Windows Terminal (wt.exe) was not found. Set "wtPath" in config.json.' }
    $lock = Enter-TRRestoreLock
    if (-not $lock) { return 'restore already running' }
    try {
        $tabs = Get-TRLastTabs
        if ($tabs.Count -eq 0) { return $null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $archName = Join-Path $script:TR_Archive $stamp
        $parts = foreach ($t in $tabs) { New-TRTabArgs $t.Tab (Join-Path $archName $t.File.Name) }
        $wtArgs = '-w new ' + ($parts -join ' ; ')
        if ($DryRun) { return "$wt $wtArgs" }
        $arch = Move-TRLastToArchive
        $wtArgs = $wtArgs.Replace($archName, $arch)
        Start-TRProcess $wt $wtArgs
        return "restored $($tabs.Count) tab(s)"
    } finally { try { $lock.ReleaseMutex() } catch { } }
}

# Called by pre-adopt.ps1 in a freshly started launcher shell: if a saved generation exists and nothing else is tracked, take
# the lock, archive last\ and open ALL saved tabs (original order) in the launcher's window. Returns the number of tabs
# spawned, or 0 when there was nothing to do (the caller then continues as a normal shell).
function Invoke-TRSpawnAll($Owner) {
    if ((Get-TRTabFiles $script:TR_Last).Count -eq 0) { Invoke-TRSweep; if ((Get-TRTabFiles $script:TR_Last).Count -eq 0) { return 0 } }
    if (@(Get-TRLiveAliveTabs $PID).Count -gt 0) { return 0 }
    $wt = Get-TRWtPath $Owner
    if (-not $wt) { return 0 }
    $lock = Enter-TRRestoreLock
    if (-not $lock) { return 0 }
    try {
        $tabs = Get-TRLastTabs
        if ($tabs.Count -eq 0) { return 0 }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $archName = Join-Path $script:TR_Archive $stamp
        $wtArgs = '-w 0 ' + ((@($tabs | ForEach-Object { New-TRTabArgs $_.Tab (Join-Path $archName $_.File.Name) })) -join ' ; ')
        $arch = Move-TRLastToArchive               # archive BEFORE spawning: restored tabs must never re-trigger
        Start-TRProcess $wt ($wtArgs.Replace($archName, $arch))
        $tabs.Count
    } finally { try { $lock.ReleaseMutex() } catch { } }
}

# ---------------------------------------------------------------- applying a saved tab
function Set-TREnvDiff($Diff) {
    if (-not $Diff) { return }
    foreach ($p in $Diff.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($p.Name, $(if ($null -eq $p.Value) { $null } else { [string]$p.Value }), 'Process')
    }
}
function Test-TRReplayAllowed([string]$ExeName, $Cfg) {
    if (-not $ExeName) { return $false }
    $leaf = [IO.Path]::GetFileNameWithoutExtension($ExeName).ToLowerInvariant()
    foreach ($d in @($Cfg.replayAllowlist)) { if ($leaf -eq ([IO.Path]::GetFileNameWithoutExtension([string]$d)).ToLowerInvariant()) { return $true } }
    $false
}
# What should this tab do? Returns @{Kind=Resume|Replay|Pretype; ...} or $null.
#   Resume  - a resume handler matched the foreground program (claude, config handlers): always resumed
#   Replay  - the foreground program's exe is on config.replayAllowlist: the typed line is re-executed
#   Pretype - anything else that was running (builds, pushes, deploys, no child at all) and idle tabs: typed, NOT executed
function Get-TRTabAction($Tab, $Run, $Cfg) {
    $pending = [string]$Tab.pendingCommand
    if ($pending) {
        if ($Run -and $Run.resume -and $Run.resume.exe) {
            return @{ Kind = 'Resume'; Exe = [string]$Run.resume.exe; Args = [string[]]@($Run.resume.args); Cwd = $Run.resume.cwd }
        }
        if ($Tab.seeded) { return $null }          # seeded placeholder: nothing typed is known
        if ($Run -and (Test-TRReplayAllowed ([string]$Run.name) $Cfg)) { return @{ Kind = 'Replay'; Text = $pending } }
        return @{ Kind = 'Pretype'; Text = $pending }
    }
    if ($Tab.lastCommand) { return @{ Kind = 'Pretype'; Text = [string]$Tab.lastCommand } }
    $null
}
# Executed with dot-sourcing (". $global:TRRunAction $act") so Replay runs in the caller's (global) scope.
$global:TRRunAction = {
    param($Act)
    if (-not $Act) { return }
    if ($Act.Kind -eq 'Pretype') {
        # PowerShell raises OnIdle also between pipelines BEFORE the first prompt, where Insert() is lost (PSReadLine resets its
        # buffer when it starts reading). So the action only fires once a prompt has completed since registration and PSReadLine
        # has been waiting for a key for a moment; then it unregisters itself.
        # (The subscriber's -MessageData is NOT visible in $Event for engine events, hence the global.)
        $tr0 = $global:__TR
        $global:TRPretype = @{ Text = [string]$Act.Text; Log = $env:TERMINALRESS_TESTLOG; At = [DateTime]::UtcNow; Count0 = $(if ($tr0) { [int]$tr0.PromptCount } else { 0 }) }
        $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
            $m = $global:TRPretype; $t = $global:__TR
            if (-not $m) { Unregister-Event -SubscriptionId $EventSubscriber.SubscriptionId -ErrorAction SilentlyContinue; return }
            if ($t) { if ([int]$t.PromptCount -le $m.Count0 -or ([DateTime]::UtcNow - $t.PromptAt).TotalMilliseconds -lt 400) { return } }
            elseif (([DateTime]::UtcNow - $m.At).TotalSeconds -lt 2) { return }
            $global:TRPretype = $null
            try {
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert([string]$m.Text)
                if ($m.Log) { [IO.File]::AppendAllText($m.Log, "PRETYPED pid=$PID text=$($m.Text)`r`n") }   # test-only log
            } catch { if ($m.Log) { try { [IO.File]::AppendAllText($m.Log, "PRETYPE-FAILED pid=$PID $($_.Exception.Message)`r`n") } catch { } } }
            Unregister-Event -SubscriptionId $EventSubscriber.SubscriptionId -ErrorAction SilentlyContinue
        }
        return
    }
    if ($Act.Kind -eq 'Resume') {
        if ($Act.Cwd -and (Test-Path -LiteralPath $Act.Cwd -PathType Container)) { Set-Location -LiteralPath $Act.Cwd }
        $trText = ($Act.Exe + ' ' + ($Act.Args -join ' '))
    } else { $trText = [string]$Act.Text }
    if (Get-Command TR_MarkRunning -ErrorAction SilentlyContinue) { TR_MarkRunning $trText }
    Write-Host "TerminalRess: $trText" -ForegroundColor DarkGray
    if ($Act.Kind -eq 'Resume') { & $Act.Exe @($Act.Args) } else { Invoke-Expression $Act.Text }
}

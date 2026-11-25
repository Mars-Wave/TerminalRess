# TerminalRess base library: the part of the shared library the tab hook needs (paths, config, guardian start).
# The hook dot-sources only this file, since it runs in every new tab; Common.ps1 dot-sources it and adds the rest.
# Keep it dependency free and Windows PowerShell 5.1 compatible, and keep New-Object, *-Variable and the JSON cmdlets off
# the hook's path: in a fresh shell their first use loads a module or an assembly (~50 ms each).
# ASCII only: PowerShell 5.1 reads BOM-less files as ANSI.

$script:TR_Runtime = $PSScriptRoot
$script:TR_State   = if ($env:TERMINALRESS_STATE) { $env:TERMINALRESS_STATE } else { Join-Path $env:LOCALAPPDATA 'TerminalRess' }
$script:TR_Live    = Join-Path $script:TR_State 'live'
$script:TR_Last    = Join-Path $script:TR_State 'last'
$script:TR_Archive = Join-Path $script:TR_State 'archive'
$script:TR_Utf8    = [Text.UTF8Encoding]::new($false)
$script:TR_InstalledRuntime = if ($env:TERMINALRESS_RUNTIME) { $env:TERMINALRESS_RUNTIME } else { Join-Path $env:LOCALAPPDATA 'TerminalRess\runtime' }
$script:TR_ScrubRegex = '^(CLAUDE|NO_COLOR$|GIT_TERMINAL_PROMPT$|WT_SESSION$|WT_PROFILE_ID$|POSH_|TERMINALRESS_RESTORING$|TERMINALRESS_FORCE$|TERMINALRESS_TAB$)'
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
    if ([IO.File]::Exists($p)) {
        $u = Read-TRJson $p
        if ($u) { foreach ($k in @($cfg.Keys)) { if ($u.PSObject.Properties[$k] -and $null -ne $u.$k) { $cfg[$k] = $u.$k } } }
    }
    $script:TR_ConfigCache = [pscustomobject]$cfg
    $script:TR_ConfigCache
}
# config.envDenylist for the hook: Windows PowerShell's first ConvertFrom-Json in a shell costs ~100 ms, so a plain
# string array is read straight from the text; anything the pattern does not match goes through Get-TRConfig.
function Get-TREnvDenylist {
    $p = Join-Path $script:TR_State 'config.json'
    if (-not [IO.File]::Exists($p)) { return @((Get-TRDefaultConfig).envDenylist) }
    $m = [regex]::Match([IO.File]::ReadAllText($p), '"envDenylist"\s*:\s*\[((?:\s*"[^"\\]*"\s*,?)*)\s*\]')
    if (-not $m.Success) { return @((Get-TRConfig).envDenylist) }
    @(foreach ($s in [regex]::Matches($m.Groups[1].Value, '"([^"]*)"')) { $s.Groups[1].Value })
}
function ConvertTo-TRWildcardRegex([string[]]$Patterns) {
    $alts = foreach ($p in $Patterns) { if ($p) { ([regex]::Escape($p)).Replace('\*', '.*').Replace('\?', '.') } }
    [regex]::new('^(?:' + ($alts -join '|') + ')$', 'IgnoreCase')
}

# ---------------------------------------------------------------- io
function Initialize-TRDirs { foreach ($d in $script:TR_State, $script:TR_Live, $script:TR_Last, $script:TR_Archive) { $null = [IO.Directory]::CreateDirectory($d) } }
function Read-TRJson([string]$Path) { try { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null } }
function Get-TRHash([string]$s, [switch]$Md5) {
    # MD5 throws under the Windows FIPS policy (so does SHA256Managed on .NET Framework < 4.8); the CSP class is FIPS-validated.
    # -Md5 only rebuilds the pre-SHA256 mutex names.
    if ($Md5) { $h = [Security.Cryptography.MD5]::Create() }
    else { $h = try { [Security.Cryptography.SHA256CryptoServiceProvider]::new() } catch { [Security.Cryptography.SHA256]::Create() } }
    try { [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLowerInvariant())), 0, 4).Replace('-', '').ToLowerInvariant() }
    finally { $h.Dispose() }
}
function Get-TRMutexName([string]$Kind, [switch]$Legacy) { "Local\TerminalRess-$Kind-" + (Get-TRHash $script:TR_State -Md5:$Legacy) }
function Get-TRRuntimeDir {
    if ([IO.File]::Exists((Join-Path $script:TR_InstalledRuntime 'guardian.ps1'))) { $script:TR_InstalledRuntime } else { $script:TR_Runtime }
}

# ---------------------------------------------------------------- processes
function Start-TRProcess {
    # Launches a process with the Claude-Code / tool-shell environment removed (so tabs render with colour).
    param([string]$FilePath, [string]$Arguments, [switch]$Hidden)
    if ($env:TERMINALRESS_DRYRUN -eq '1') {
        [IO.File]::AppendAllText((Join-Path $script:TR_State 'dryrun.log'), "$FilePath $Arguments`r`n", $script:TR_Utf8); return
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath; $psi.Arguments = $Arguments; $psi.UseShellExecute = $false
    if ($Hidden) { $psi.CreateNoWindow = $true }
    foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -match $script:TR_ScrubRegex) { $psi.EnvironmentVariables.Remove($k) } }
    [void][Diagnostics.Process]::Start($psi)
}
function Test-TRMutexExists([string]$Name) {
    $m = $null
    $r = [Threading.Mutex]::TryOpenExisting($Name, [ref]$m)
    if ($m) { $m.Dispose() }
    $r
}
# A guardian started before an upgrade keeps its MD5-named mutex until it exits; without this a second one would start.
# Under FIPS MD5 throws, but then no old guardian can have run either.
function Test-TRLegacyGuardian { try { Test-TRMutexExists (Get-TRMutexName 'Guardian' -Legacy) } catch { $false } }
function Test-TRGuardianRunning { (Test-TRMutexExists (Get-TRMutexName 'Guardian')) -or (Test-TRLegacyGuardian) }
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

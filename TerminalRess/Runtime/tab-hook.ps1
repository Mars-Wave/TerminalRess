# TerminalRess main hook. Dot-sourced at the END of the profile so it wraps the final prompt.
# Registers this shell (a Windows Terminal tab) in <state>\live\<pid>.json on every prompt.
# Runs in every new tab, so it loads only Base.ps1 and never touches CIM: the guardian records the owning WT.
# Test switches: TERMINALRESS_STATE (state dir), TERMINALRESS_FORCE=1 (skip the nested-shell check), TERMINALRESS_DRYRUN=1.

if (-not $env:WT_SESSION) { return }
if ($env:CLAUDECODE) { return }
if ($global:__TR) { return }
# A shell started inside a tracked tab inherits that tab's WT_SESSION and the marker set below; a new tab (even one
# opened by wt.exe from a tracked shell) gets a WT_SESSION of its own.
if ($env:TERMINALRESS_FORCE -ne '1' -and $env:TERMINALRESS_TAB -eq $env:WT_SESSION) { return }

try {
    . (Join-Path $PSScriptRoot 'Base.ps1')
    $null = [IO.Directory]::CreateDirectory($script:TR_Live)

    # Baseline = the environment the shell process STARTED with (captured by the pre-hook at the top of the profile),
    # so changes made by the profile itself are part of the diff. Fallback: now.
    $trBase = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $trSrc = if ($global:TerminalRessBaseline) { $global:TerminalRessBaseline } else { [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process) }
    foreach ($trE in $trSrc.GetEnumerator()) { $trBase[[string]$trE.Key] = [string]$trE.Value }
    if (-not $global:TerminalRessBaseline) { $global:TerminalRessBaseline = $trSrc }

    $me = [Diagnostics.Process]::GetCurrentProcess()
    $global:__TR = @{
        File        = Join-Path $script:TR_Live "$PID.json"
        Baseline    = $trBase
        Deny        = ConvertTo-TRWildcardRegex (Get-TREnvDenylist)
        Utf8        = $script:TR_Utf8
        ShellStart  = $me.StartTime.Ticks
        ShellExe    = $me.Path
        Session     = $me.SessionId
        Exiting     = $false
        PromptCount = 0
        PromptAt    = [DateTime]::UtcNow
        Cwd         = $null
        EnvDiff     = $null
        Pending     = $null
        LastCommand = $null
        OrigPrompt  = $function:prompt
        OrigHandler = $null
        Sensitive   = '(?i)password|asplaintext|token|apikey|api_key|secret|credential'
    }
    $env:TERMINALRESS_TAB = $env:WT_SESSION
} catch { return }

# Hand-written JSON: on Windows PowerShell the first ConvertTo-Json in a shell costs ~40 ms (module + assembly load).
# Only strings, integers, booleans, null and string maps occur here.
function global:TR_Json($v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long]) { return [string]$v }
    if ($v -is [Collections.IDictionary]) { return '{' + (@(foreach ($k in $v.Keys) { (TR_Json ([string]$k)) + ':' + (TR_Json $v[$k]) }) -join ',') + '}' }
    $s = ([string]$v).Replace('\', '\\').Replace('"', '\"')
    if ($s -match '[\x00-\x1f]') { $s = [regex]::Replace($s, '[\x00-\x1f]', { '\u{0:x4}' -f [int][char]$args[0].Value }) }
    '"' + $s + '"'
}

function global:TR_WriteState {
    try {
        $t = $global:__TR
        $o = [ordered]@{
            shellPid = $PID; shellStart = $t.ShellStart; shellExe = $t.ShellExe; session = $t.Session; wtSession = $env:WT_SESSION
            exiting = $t.Exiting
            cwd = $t.Cwd; envDiff = $t.EnvDiff; lastCommand = $t.LastCommand; pendingCommand = $t.Pending
            updatedAt = [DateTime]::UtcNow.ToString('o')
        }
        $tmp = "$($t.File).tmp"
        [IO.File]::WriteAllText($tmp, (TR_Json $o), $t.Utf8)
        if ([IO.File]::Exists($t.File)) { [IO.File]::Replace($tmp, $t.File, [NullString]::Value) } else { [IO.File]::Move($tmp, $t.File) }
    } catch { }
}

function global:TR_Snapshot {
    $t = $global:__TR
    if ($PWD.Provider.Name -eq 'FileSystem') { $t.Cwd = $PWD.ProviderPath }
    $diff = [ordered]@{}
    $cur = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    foreach ($k in $cur.Keys) {
        if ($t.Deny.IsMatch([string]$k)) { continue }
        $b = $null
        if (-not $t.Baseline.TryGetValue([string]$k, [ref]$b) -or $b -ne [string]$cur[$k]) { $diff[[string]$k] = [string]$cur[$k] }
    }
    foreach ($k in $t.Baseline.Keys) {
        if ($t.Deny.IsMatch($k)) { continue }
        if (-not $cur.Contains($k)) { $diff[$k] = $null }
    }
    $t.EnvDiff = $diff
    $h = Get-History -Count 1 -ErrorAction SilentlyContinue
    if ($h -and $h.CommandLine -notmatch $t.Sensitive -and $h.CommandLine -notmatch 'restore-tab.ps1') { $t.LastCommand = $h.CommandLine }
}

# used by restore code: mark the tab as "running <text>" before the first prompt exists
function global:TR_MarkRunning([string]$Text) {
    try {
        TR_Snapshot
        $global:__TR.Pending = $Text
        TR_WriteState
    } catch { }
}

function global:prompt {
    $trOk = $?; $trLec = $global:LASTEXITCODE
    $global:LASTEXITCODE = $trLec
    if (-not $trOk) { Write-Error 'x' -ErrorAction Ignore }   # hand the original prompt the same $? (must be the LAST statement before the call)
    $trOut = & $global:__TR.OrigPrompt
    try {
        $global:__TR.Pending = $null            # back at a prompt: nothing is running
        $global:__TR.Exiting = $false
        TR_Snapshot
        TR_WriteState
        $global:__TR.PromptCount++; $global:__TR.PromptAt = [DateTime]::UtcNow
        if ($global:__TR.Cwd) { [Console]::Write("$([char]27)]9;9;$($global:__TR.Cwd)$([char]27)\") }
    } catch { }
    $global:LASTEXITCODE = $trLec
    $trOut
}

# Record the accepted line (typed form) as pendingCommand, chaining any existing handler.
try {
    # the live options object, as Set-PSReadLineOption sets it; the static call skips the cmdlets' first-call cost
    $trOpt = try { [Microsoft.PowerShell.PSConsoleReadLine]::GetOptions() } catch { Get-PSReadLineOption }
    $global:__TR.OrigHandler = $trOpt.AddToHistoryHandler
    $trOpt.AddToHistoryHandler = {
        param([string]$line)
        try {
            $t = $global:__TR
            if ($line -match '^\s*exit\b') { $t.Exiting = $true; TR_WriteState }    # deliberate close: never restored
            elseif ($line.Trim() -and $line -notmatch $t.Sensitive) {
                $t.Pending = $line
                TR_WriteState
            }
        } catch { }
        $oh = $global:__TR.OrigHandler
        if ($oh -is [scriptblock]) { return (& $oh $line) }
        if ($oh) { return $oh.Invoke($line) }       # PSReadLine's own default handler is a delegate
        if ($line -match $global:__TR.Sensitive) { return [Microsoft.PowerShell.AddToHistoryOption]::MemoryOnly }
        return [Microsoft.PowerShell.AddToHistoryOption]::MemoryAndFile
    }
} catch { }

# Register right away and make sure the guardian runs.
try {
    $global:__TR.Cwd = if ($PWD.Provider.Name -eq 'FileSystem') { $PWD.ProviderPath } else { $null }
    TR_Snapshot
    TR_WriteState
    $null = Start-TRGuardianProcess
} catch { }

# not Remove-Variable: its module would be loaded just for this
foreach ($trV in 'trBase', 'trSrc', 'trOpt', 'me', 'trE', 'trV') { $ExecutionContext.SessionState.PSVariable.Remove($trV) }

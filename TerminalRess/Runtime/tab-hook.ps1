# TerminalRess main hook. Dot-sourced at the END of the profile so it wraps the final prompt.
# Registers this shell (a Windows Terminal tab) in <state>\live\<pid>.json on every prompt.
# Test switches: TERMINALRESS_STATE (state dir), TERMINALRESS_FORCE=1 (skip parent check), TERMINALRESS_DRYRUN=1.

if (-not $env:WT_SESSION) { return }
if ($env:CLAUDECODE) { return }
if ($global:__TR) { return }

try {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    # guard + owning WT (shell -> OpenConsole -> WindowsTerminal)
    $trOwner = Get-TROwnerWt $PID
    if ($env:TERMINALRESS_FORCE -ne '1' -and $trOwner.ParentName -notin 'OpenConsole', 'WindowsTerminal') { return }
    Initialize-TRDirs
    $trCfg = Get-TRConfig

    # Baseline = the environment the shell process STARTED with (captured by the pre-hook at the top of the profile),
    # so changes made by the profile itself are part of the diff. Fallback: now.
    $trBase = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $trSrc = if ($global:TerminalRessBaseline) { $global:TerminalRessBaseline } else { [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process) }
    foreach ($e in $trSrc.GetEnumerator()) { $trBase[[string]$e.Key] = [string]$e.Value }
    if (-not $global:TerminalRessBaseline) { $global:TerminalRessBaseline = $trSrc }

    $me = [Diagnostics.Process]::GetCurrentProcess()
    $global:__TR = @{
        File        = Join-Path $script:TR_Live "$PID.json"
        Baseline    = $trBase
        Deny        = ConvertTo-TRWildcardRegex @($trCfg.envDenylist)
        Utf8        = $script:TR_Utf8
        ShellStart  = $me.StartTime.Ticks
        ShellExe    = $me.Path
        Session     = $me.SessionId
        Owner       = $trOwner
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
} catch { return }

function global:TR_WriteState {
    try {
        $t = $global:__TR
        $o = [ordered]@{
            shellPid = $PID; shellStart = $t.ShellStart; shellExe = $t.ShellExe; session = $t.Session; wtSession = $env:WT_SESSION
            wtPid = $t.Owner.Pid; wtStart = $t.Owner.Start; exiting = $t.Exiting
            cwd = $t.Cwd; envDiff = $t.EnvDiff; lastCommand = $t.LastCommand; pendingCommand = $t.Pending
            updatedAt = [DateTime]::UtcNow.ToString('o')
        }
        $tmp = "$($t.File).tmp"
        [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 4 -Compress), $t.Utf8)
        Move-Item -LiteralPath $tmp -Destination $t.File -Force
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
    $global:__TR.OrigHandler = (Get-PSReadLineOption).AddToHistoryHandler
    Set-PSReadLineOption -AddToHistoryHandler {
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

Remove-Variable trCfg, trBase, trSrc, trOwner, me -ErrorAction SilentlyContinue

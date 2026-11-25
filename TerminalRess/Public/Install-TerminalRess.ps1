function Install-TerminalRess {
    <#
    .SYNOPSIS
        Installs tab resurrection for Windows Terminal: profile hooks, runtime scripts, optional logon shortcut.
    .DESCRIPTION
        - copies the runtime scripts to %LOCALAPPDATA%\TerminalRess\runtime
        - adds a pre-hook at the TOP and the main hook at the END of the profile (backup first; idempotent)
        - writes config.json if missing
        - creates a Startup shortcut (hidden, via wscript) unless -NoLogonRestore
        - starts the guardian
        Run it once per PowerShell edition (Windows PowerShell 5.1 and pwsh 7 have separate profiles).
    .PARAMETER NoLogonRestore
        Do not create the Startup shortcut and set restoreOnLogon=false.
    .PARAMETER NoLaunchRestore
        Set restoreOnLaunch=false: opening a terminal will not restore the previous generation.
    .PARAMETER ProfileScope
        CurrentHost (default) uses $PROFILE.CurrentUserCurrentHost, AllHosts uses $PROFILE.CurrentUserAllHosts.
        The hook must come LAST in the profile chain, so CurrentHost is the safe default.
    .PARAMETER ProfilePath
        Explicit profile file (mainly for tests).
    .PARAMETER StartupFolder
        Startup folder override (mainly for tests).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$NoLogonRestore,
        [switch]$NoLaunchRestore,
        [ValidateSet('CurrentHost', 'AllHosts')][string]$ProfileScope = 'CurrentHost',
        [string]$ProfilePath,
        [string]$StartupFolder,
        [switch]$NoGuardian,
        [switch]$NoRegisterExisting
    )
    if (-not $ProfilePath) { $ProfilePath = if ($ProfileScope -eq 'AllHosts') { $PROFILE.CurrentUserAllHosts } else { $PROFILE.CurrentUserCurrentHost } }
    Initialize-TRDirs

    $runtimeSrc = $script:TR_Runtime
    $runtimeDst = $script:TR_InstalledRuntime
    if ($PSCmdlet.ShouldProcess($runtimeDst, 'Copy runtime scripts')) {
        if (-not (Test-Path -LiteralPath $runtimeDst)) { New-Item -ItemType Directory -Force -Path $runtimeDst | Out-Null }
        Get-ChildItem -LiteralPath $runtimeSrc -File | Copy-Item -Destination $runtimeDst -Force
    }

    $cfgPath = Join-Path $script:TR_State 'config.json'
    if ($PSCmdlet.ShouldProcess($cfgPath, 'Write config')) {
        if (-not (Test-Path -LiteralPath $cfgPath)) { Write-TRJsonPretty $cfgPath (Get-TRDefaultConfig) }
        $c = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $dirty = $false
        if ($NoLaunchRestore) { $c.restoreOnLaunch = $false; $dirty = $true }
        if ($NoLogonRestore)  { $c.restoreOnLogon = $false; $dirty = $true }
        if ($dirty) { Write-TRJsonPretty $cfgPath $c }
        $script:TR_ConfigCache = $null
    }

    $prof = $null
    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Add TerminalRess hooks to profile')) { $prof = Set-TRProfileBlocks -Path $ProfilePath }

    $lnk = $null
    if (-not $NoLogonRestore -and $PSCmdlet.ShouldProcess((Get-TRStartupShortcutPath $StartupFolder), 'Create Startup shortcut')) {
        $lnk = New-TRStartupShortcut $StartupFolder $runtimeDst
    }
    if (-not $NoGuardian -and $PSCmdlet.ShouldProcess('guardian', 'Start')) { $null = Start-TRGuardianProcess }

    $seeded = @()
    if (-not $NoRegisterExisting -and $PSCmdlet.ShouldProcess('open Windows Terminal tabs', 'Register existing tabs')) { $seeded = @(Register-TerminalRessExisting) }

    [pscustomobject]@{
        SeededTabs      = $seeded.Count
        Profile         = $ProfilePath
        ProfileChanged  = [bool]($prof -and $prof.Changed)
        ProfileBackup   = if ($prof) { $prof.Backup } else { $null }
        Runtime         = $runtimeDst
        State           = $script:TR_State
        StartupShortcut = $lnk
        Note            = 'New terminals pick the hooks up; tabs already open are not tracked until reopened.'
    }
}

# Profile and shortcut helpers used by Install-/Uninstall-TerminalRess.

$script:TR_PreBegin  = '# >>> TerminalRess (pre) >>>'
$script:TR_PreEnd    = '# <<< TerminalRess (pre) <<<'
$script:TR_MainBegin = '# >>> TerminalRess >>>'
$script:TR_MainEnd   = '# <<< TerminalRess <<<'

function Get-TRPreBlock {
    @($script:TR_PreBegin,
      '# Captures the environment this shell started with (before the profile changes it) and, only when a saved',
      '# tab generation is waiting, reopens all saved tabs and closes this launcher tab. Managed by TerminalRess.',
      'if ($env:WT_SESSION -and -not $global:TerminalRessBaseline) {',
      '    $global:TerminalRessBaseline = [Environment]::GetEnvironmentVariables(''Process'')',
      '    $trS = if ($env:TERMINALRESS_STATE) { $env:TERMINALRESS_STATE } else { Join-Path $env:LOCALAPPDATA ''TerminalRess'' }',
      '    # restore is due if a saved generation exists OR a tracked tab is dead and not yet swept (WT relaunched within the guardian''s grace period)',
      '    $trNeed = Test-Path -Path (Join-Path $trS ''last\*.json'')',
      '    $trL = Join-Path $trS ''live''',
      '    if (-not $trNeed -and [IO.Directory]::Exists($trL)) { foreach ($trF in [IO.Directory]::GetFiles($trL, ''*.json'')) { $trN = [IO.Path]::GetFileNameWithoutExtension($trF); if ($trN -match ''^\d+$'' -and -not (Get-Process -Id ([int]$trN) -ErrorAction SilentlyContinue)) { $trNeed = $true; break } } }',
      '    if ($trNeed) { $trP = Join-Path $env:LOCALAPPDATA ''TerminalRess\runtime\pre-adopt.ps1''; if (Test-Path -LiteralPath $trP) { . $trP } }',
      '    Remove-Variable trS, trP, trNeed, trL, trF, trN -ErrorAction SilentlyContinue',
      '}',
      $script:TR_PreEnd)
}
function Get-TRMainBlock {
    @($script:TR_MainBegin,
      '# Tab resurrection hook; keep this at the END of the profile. Managed by TerminalRess.',
      'if ($env:WT_SESSION) {',
      '    $trHook = Join-Path $env:LOCALAPPDATA ''TerminalRess\runtime\tab-hook.ps1''',
      '    if (Test-Path -LiteralPath $trHook) { . $trHook }',
      '    Remove-Variable trHook -ErrorAction SilentlyContinue',
      '}',
      $script:TR_MainEnd)
}

function Read-TRTextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Text = ''; Bom = $true; Exists = $false } }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $enc = New-Object Text.UTF8Encoding $false
    $text = $enc.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{ Text = $text; Bom = $bom; Exists = $true }
}
function Remove-TRBlocks([string]$Text) {
    foreach ($pair in @(@($script:TR_PreBegin, $script:TR_PreEnd), @($script:TR_MainBegin, $script:TR_MainEnd))) {
        $rx = '(?ms)^' + [regex]::Escape($pair[0]) + '.*?^' + [regex]::Escape($pair[1]) + '[ \t]*(\r?\n)?'
        $Text = [regex]::Replace($Text, $rx, '')
    }
    $Text
}
function Set-TRProfileBlocks {
    # Adds (or, with -Remove, strips) the two blocks. Idempotent; backs the file up before changing it.
    param([string]$Path, [switch]$Remove)
    $f = Read-TRTextFile $Path
    if (-not $f.Exists -and $Remove) { return [pscustomobject]@{ Changed = $false; Backup = $null } }
    $nl = if ($f.Text -match "`r`n") { "`r`n" } elseif ($f.Text -match "`n") { "`n" } else { "`r`n" }
    if ($Remove -and -not ($f.Text.Contains($script:TR_MainBegin) -or $f.Text.Contains($script:TR_PreBegin))) { return [pscustomobject]@{ Changed = $false; Backup = $null } }
    $body = (Remove-TRBlocks $f.Text).Trim("`r", "`n")
    if ($Remove) { $new = $(if ($body) { $body + $nl } else { '' }) }
    else {
        $new = ((Get-TRPreBlock) -join $nl) + $nl + $nl
        if ($body) { $new += $body + $nl + $nl }
        $new += ((Get-TRMainBlock) -join $nl) + $nl
    }
    if ($new -ceq $f.Text) { return [pscustomobject]@{ Changed = $false; Backup = $null } }
    $backup = $null
    if ($f.Exists) {
        $backup = "$Path.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    } else {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }
    [IO.File]::WriteAllText($Path, $new, (New-Object Text.UTF8Encoding $f.Bom))
    [pscustomobject]@{ Changed = $true; Backup = $backup }
}
function Test-TRProfileInstalled([string]$Path) {
    $f = Read-TRTextFile $Path
    $f.Exists -and $f.Text.Contains($script:TR_MainBegin) -and $f.Text.Contains($script:TR_PreBegin)
}

function Get-TRStartupShortcutPath([string]$StartupFolder) {
    if (-not $StartupFolder) { $StartupFolder = [Environment]::GetFolderPath('Startup') }
    Join-Path $StartupFolder 'TerminalRess.lnk'
}
function New-TRStartupShortcut([string]$StartupFolder, [string]$RuntimeDir) {
    $path = Get-TRStartupShortcutPath $StartupFolder
    if (-not (Test-Path -LiteralPath (Split-Path $path))) { New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null }
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($path)
    $l.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $l.Arguments = '"' + (Join-Path $RuntimeDir 'startup.vbs') + '"'
    $l.WorkingDirectory = $RuntimeDir
    $l.WindowStyle = 7
    $l.Description = 'TerminalRess: restore Windows Terminal tabs after a reboot'
    $l.Save()
    $path
}

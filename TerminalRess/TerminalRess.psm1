# TerminalRess module loader.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime\Common.ps1')
foreach ($dir in 'Private', 'Public') {
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $dir) -Filter '*.ps1' -File) { . $f.FullName }
}
$script:TR_ModuleRoot = $PSScriptRoot
# After Update-Module the first import refreshes an older installed runtime (the guardian also scans for new versions).
# The running guardian is restarted onto the new code: one from before self-updating existed would never do it itself.
try {
    if ((Update-TRRuntime $PSScriptRoot) -and (Stop-TerminalRessGuardian)) { $null = Start-TRGuardianProcess }
} catch { Write-Warning "TerminalRess: runtime update failed: $($_.Exception.Message)" }
Export-ModuleMember -Function (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File).BaseName

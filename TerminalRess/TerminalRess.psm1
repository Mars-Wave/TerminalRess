# TerminalRess module loader.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Runtime\Common.ps1')
foreach ($dir in 'Private', 'Public') {
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $dir) -Filter '*.ps1' -File) { . $f.FullName }
}
$script:TR_ModuleRoot = $PSScriptRoot
Export-ModuleMember -Function (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File).BaseName

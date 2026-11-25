@{
    RootModule           = 'TerminalRess.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '341530b1-3443-4f88-9201-05e77c6684d2'
    Author               = 'Mars-Wave'
    Copyright            = '(c) 2026 Mars-Wave. MIT License.'
    Description          = 'Windows only. Brings Windows Terminal tabs back after a crash, kill, logoff or reboot: same directory, environment and foreground command (Claude Code sessions are resumed).'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Install-TerminalRess', 'Uninstall-TerminalRess', 'Restore-TerminalRess', 'Get-TerminalRessStatus', 'Register-TerminalRessExisting', 'Start-TerminalRessGuardian', 'Stop-TerminalRessGuardian')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Windows', 'WindowsTerminal', 'Terminal', 'Session', 'Restore', 'Resurrect', 'ClaudeCode', 'PSEdition_Desktop', 'PSEdition_Core')
            LicenseUri   = 'https://github.com/Mars-Wave/TerminalRess/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Mars-Wave/TerminalRess'
        }
    }
}

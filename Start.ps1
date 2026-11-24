[CmdletBinding()]
param()

# Run in this PowerShell window. Ctrl+C stops only the remote bridge.
& (Join-Path $PSScriptRoot 'scripts\Start-Remote.ps1')

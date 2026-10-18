# PowerShell wrapper: runs scripts/suspend-evaluation.sh with Git Bash (the bash script does the work).
#   powershell -ExecutionPolicy Bypass -File scripts\suspend-evaluation.ps1 [--plan]
$ErrorActionPreference = 'Stop'
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash) { throw 'Git Bash not found: install Git for Windows' }
if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = 'order-inventory' }
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & $bash scripts/suspend-evaluation.sh @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}

#Requires -Version 7.6
param([string] $Destination = (Join-Path $env:RUNNER_TEMP 'release-archive-tools'))

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) {
    foreach ($name in @('zip', 'unzip')) {
        $tool = Get-Command $name -CommandType Application -ErrorAction Stop | Select-Object -First 1
        & $tool.Source -v | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Required archive tool $name failed." }
    }
    return
}

$release = Get-Content "$PSScriptRoot/../release.json" -Raw | ConvertFrom-Json
Import-Module "$PSScriptRoot/Bootstrap.psm1" -Force
Install-StandaloneSevenZip -Pin $release.archive_tools.seven_zip -Destination $Destination
$env:PATH = $Destination + [IO.Path]::PathSeparator + $env:PATH
if ($env:GITHUB_PATH) { $Destination >> $env:GITHUB_PATH }

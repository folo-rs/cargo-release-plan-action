#Requires -Version 7.6
param([Parameter(Mandatory)][ValidateSet('prepare', 'install')][string] $Stage)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/Bootstrap.psm1" -Force

if ($env:CRP_COMMAND -notin @('version', 'version-readiness', 'check', 'prepare-publish', 'publish-registry', 'check-publishing-identity')) {
    throw "Unsupported action command '$env:CRP_COMMAND'."
}
$sourcePath = if ([IO.Path]::IsPathRooted($env:CRP_SOURCE_PATH)) {
    $env:CRP_SOURCE_PATH
}
else {
    Join-Path $env:GITHUB_WORKSPACE $env:CRP_SOURCE_PATH
}
$settings = Get-InstallationSettings -ActionPath $env:CRP_ACTION_PATH -Method $env:CRP_INSTALL_METHOD -SourcePath $sourcePath -TemporaryDirectory $env:RUNNER_TEMP -RunnerOS $env:RUNNER_OS -RunnerArch $env:RUNNER_ARCH
if ($Stage -eq 'prepare') {
    "root=$($settings.Root)" >> $env:GITHUB_OUTPUT
    "cache-key=$($settings.CacheKey)" >> $env:GITHUB_OUTPUT
}
else {
    Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
    try {
        $executable = Install-ReleasePlan $settings
    }
    finally {
        Pop-Location
    }
    "executable=$executable" >> $env:GITHUB_OUTPUT
    "version=$($settings.Version)" >> $env:GITHUB_OUTPUT
    (Split-Path $executable) >> $env:GITHUB_PATH
}

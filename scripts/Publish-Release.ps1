#Requires -Version 7.6
<#
CI calls this entry point for action version readiness and, after installation
acceptance, action publication. Cargo workspace publication remains with CRP.
#>
[CmdletBinding()]
param(
    [string] $RepositoryPath = (Split-Path $PSScriptRoot -Parent),
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $Ref = 'HEAD',
    [string] $BaseRef,
    [switch] $CheckOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release.psm1') -Force

if ($CheckOnly) {
    $null = Assert-ReleaseReadiness -RepositoryPath $RepositoryPath -Ref $Ref -BaseRef $BaseRef
    Write-Information 'Action version is ready for the proposed release-bearing content.' -InformationAction Continue
}
else {
    if ([string]::IsNullOrWhiteSpace($Repository)) { throw 'A GitHub repository is required.' }
    Publish-ActionRelease -RepositoryPath $RepositoryPath -Repository $Repository -Ref $Ref -BaseRef $BaseRef
}

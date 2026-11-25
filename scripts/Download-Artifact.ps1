#Requires -Version 7.6

# Stable command boundary for the private same-run artifact download action.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApiUrl,
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [long] $RunId,
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $GitHubToken,
    [string] $ArtifactIds = '',
    [string] $Name = '',
    [string] $Pattern = '',
    [string[]] $ProducerSteps = @(),
    [switch] $AllowEmpty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module (Join-Path $PSScriptRoot 'ArtifactDownload.psm1') -Force
Invoke-ArtifactDownload -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId `
    -Path $Path -GitHubToken $GitHubToken -ArtifactIds $ArtifactIds -Name $Name `
    -Pattern $Pattern -ProducerSteps $ProducerSteps -AllowEmpty:$AllowEmpty

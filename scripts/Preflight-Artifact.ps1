#Requires -Version 7.6

# Stable command boundary for the private same-run artifact preflight action.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApiUrl,
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [long] $RunId,
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

Import-Module (Join-Path $PSScriptRoot 'ArtifactPreflight.psm1') -Force
$selection = @(Invoke-ArtifactPreflight -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId `
    -GitHubToken $GitHubToken -ArtifactIds $ArtifactIds -Name $Name -Pattern $Pattern `
    -ProducerSteps $ProducerSteps -AllowEmpty:$AllowEmpty)
"ids=$(($selection | ForEach-Object Id) -join ',')" >> $env:GITHUB_OUTPUT
"selection=$(ConvertTo-Json -InputObject $selection -Compress)" >> $env:GITHUB_OUTPUT

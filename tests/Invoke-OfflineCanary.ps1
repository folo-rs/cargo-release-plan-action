#Requires -Version 7.6
param([Parameter(Mandatory)][string] $Executable)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
$fixture = Join-Path $env:RUNNER_TEMP "release-plan-consumer-$([guid]::NewGuid())"
$artifacts = Join-Path $env:RUNNER_TEMP "release-plan-artifacts-$([guid]::NewGuid())"
$originalEnvironment = @{}
foreach ($name in @('GITHUB_WORKSPACE', 'CRP_EXECUTABLE', 'CRP_COMMAND', 'CRP_WORKING_DIRECTORY', 'CRP_BASE', 'CRP_CONFIG', 'CRP_SOURCE', 'CRP_OUTPUT')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    New-Item (Join-Path $fixture '.cargo') -ItemType Directory -Force | Out-Null
    # A publishable empty library isolates action forwarding from binary-release policy.
    @'
[package]
name = "release-plan-action-canary"
version = "0.1.0"
edition = "2024"
include = ["lib.rs"]

[lib]
path = "lib.rs"

[package.metadata.docs.rs]
all-features = true
'@ | Set-Content (Join-Path $fixture 'Cargo.toml')
    '' | Set-Content (Join-Path $fixture 'lib.rs')
    @'
[toolchain]
channel = "1.98.1"
profile = "minimal"
'@ | Set-Content (Join-Path $fixture 'rust-toolchain.toml')
    @'
schema-version = 1
repository = "folo-rs/cargo-release-plan-action"
release-branch = "main"
targets = ["x86_64-unknown-linux-gnu"]
'@ | Set-Content (Join-Path $fixture '.cargo/release_plan.toml')
    Invoke-BootstrapCommand cargo @('+1.98.1', 'generate-lockfile', '--manifest-path', (Join-Path $fixture 'Cargo.toml'))
    Invoke-BootstrapCommand git @('-C', $fixture, 'init', '--quiet', '--initial-branch', 'main')
    Invoke-BootstrapCommand git @('-C', $fixture, 'add', '.')
    Invoke-BootstrapCommand git @('-C', $fixture, '-c', 'user.name=Action canary', '-c', 'user.email=canary@example.invalid', 'commit', '--quiet', '-m', 'Initial fixture')

    $env:GITHUB_WORKSPACE = $fixture
    $env:CRP_EXECUTABLE = $Executable
    $env:CRP_WORKING_DIRECTORY = '.'
    $env:CRP_BASE = Invoke-BootstrapCommand git @('-C', $fixture, 'rev-parse', 'HEAD')
    $env:CRP_CONFIG = '.cargo/release_plan.toml'
    foreach ($command in @('version-readiness', 'check')) {
        $env:CRP_COMMAND = $command
        & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    }

    $env:CRP_CONFIG = '.cargo/missing.toml'
    $rejected = $false
    try {
        & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    }
    catch {
        $rejected = $true
        Write-Output "Expected missing-config rejection: $($_.Exception.Message)"
    }
    if (-not $rejected) { throw 'Configured check accepted a missing configuration.' }
    # Match the Rust integration fixture: real fetch arguments, repository-local transport.
    Invoke-BootstrapCommand git @('-C', $fixture, 'config', "url.$fixture.insteadOf", 'https://github.com/folo-rs/cargo-release-plan-action.git')
    $env:CRP_COMMAND = 'prepare-publish'
    $env:CRP_CONFIG = '.cargo/release_plan.toml'
    $env:CRP_SOURCE = $env:CRP_BASE
    $env:CRP_OUTPUT = Join-Path $artifacts 'publication.json'
    & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    $publication = Get-Content $env:CRP_OUTPUT -Raw | ConvertFrom-Json
    if ($publication.id -cnotmatch '^[0-9a-f]{64}$' -or
        $publication.publication.source -cne $env:CRP_SOURCE -or
        $publication.publication.workspace_manifest -cne 'Cargo.toml') {
        throw 'Publication envelope does not identify the selected source.'
    }
    $digest = (Get-FileHash $env:CRP_OUTPUT).Hash
    & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    if ((Get-FileHash $env:CRP_OUTPUT).Hash -cne $digest) {
        throw 'Repeated preparation changed immutable publication intent.'
    }
    $status = Invoke-BootstrapCommand git @('-C', $fixture, 'status', '--porcelain')
    if ($status) { throw "Read-only action operations changed the fixture: $status" }
    Write-Output 'Real offline checks and immutable preparation succeeded without changing source.'
}
finally {
    foreach ($entry in $originalEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
    if (Test-Path -LiteralPath $artifacts) {
        Remove-Item -LiteralPath $artifacts -Recurse -Force
    }
}

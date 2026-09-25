#Requires -Version 7.6
param([Parameter(Mandatory)][string] $Executable)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
$fixture = Join-Path $env:RUNNER_TEMP "release-plan-consumer-$([guid]::NewGuid())"
$originalEnvironment = @{}
foreach ($name in @('GITHUB_WORKSPACE', 'CRP_EXECUTABLE', 'CRP_COMMAND', 'CRP_WORKING_DIRECTORY', 'CRP_BASE', 'CRP_CONFIG')) {
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
    $status = Invoke-BootstrapCommand git @('-C', $fixture, 'status', '--porcelain')
    if ($status) { throw "Offline action operations changed the fixture: $status" }
    Write-Output 'Real offline action operations succeeded and rejected missing configuration.'
}
finally {
    foreach ($entry in $originalEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

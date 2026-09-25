#Requires -Version 7.6
param([Parameter(Mandatory)][string] $Executable)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
$fixture = Join-Path $env:RUNNER_TEMP "release-plan-consumer-$([guid]::NewGuid())"
$artifacts = Join-Path $env:RUNNER_TEMP "release-plan-artifacts-$([guid]::NewGuid())"
$packageName = "release-plan-action-canary-$([guid]::NewGuid().ToString('N'))"
$originalEnvironment = @{}
foreach ($name in @('GITHUB_WORKSPACE', 'CRP_EXECUTABLE', 'CRP_COMMAND', 'CRP_WORKING_DIRECTORY', 'CRP_BASE', 'CRP_CONFIG', 'CRP_SOURCE', 'CRP_PUBLICATION', 'CRP_OUTPUT', 'CRP_DRY_RUN')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    New-Item (Join-Path $fixture '.cargo') -ItemType Directory -Force | Out-Null
    # A unique unpublished library exercises nonempty registry work without reserving a crate name.
    @"
[package]
name = "$packageName"
version = "0.1.0"
edition = "2024"
include = ["lib.rs"]

[lib]
path = "lib.rs"

[package.metadata.docs.rs]
all-features = true
"@ | Set-Content (Join-Path $fixture 'Cargo.toml')
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
        $publication.publication.workspace_manifest -cne 'Cargo.toml' -or
        $publication.publication.packages.Count -ne 1 -or
        $publication.publication.packages[0].name -cne $packageName) {
        throw 'Publication envelope does not identify the selected source and fixture package.'
    }
    $digest = (Get-FileHash $env:CRP_OUTPUT).Hash
    & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    if ((Get-FileHash $env:CRP_OUTPUT).Hash -cne $digest) {
        throw 'Repeated preparation changed immutable publication intent.'
    }
    if ($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN -or $env:ACTIONS_ID_TOKEN_REQUEST_URL -or
        $env:CARGO_REGISTRIES_CRATES_IO_TOKEN -or $env:CARGO_REGISTRY_TOKEN) {
        throw 'The registry dry-run canary must not receive publication credentials or OIDC authority.'
    }
    $intent = $env:CRP_OUTPUT
    $env:CRP_COMMAND = 'publish-registry'
    $env:CRP_PUBLICATION = $intent
    $env:CRP_OUTPUT = Join-Path $artifacts 'registry-attempt-1.json'
    $env:CRP_DRY_RUN = 'true'
    Write-Output 'Checking live crates.io sparse-index availability with publish-registry --dry-run; no upload authority is present.'
    & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    $outcome = Get-Content $env:CRP_OUTPUT -Raw | ConvertFrom-Json
    if ($outcome.schema_version -ne 1 -or $outcome.publication_id -cne $publication.id -or
        $outcome.phase -cne 'registry' -or $outcome.dry_run -ne $true -or
        $outcome.complete -ne $false -or $outcome.packages.Count -ne 1 -or
        $outcome.packages[0].name -cne $packageName -or
        $outcome.packages[0].version -cne '0.1.0' -or
        $outcome.packages[0].state -cne 'would_publish' -or $outcome.errors.Count -ne 0) {
        throw 'Nonempty registry dry-run did not preserve the expected incomplete outcome contract.'
    }
    $outcomeDigest = (Get-FileHash $env:CRP_OUTPUT).Hash
    $rejected = $false
    try {
        & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    }
    catch {
        $rejected = $true
        Write-Output "Expected reused-outcome rejection: $($_.Exception.Message)"
    }
    if (-not $rejected -or (Get-FileHash $env:CRP_OUTPUT).Hash -cne $outcomeDigest) {
        throw 'Registry retry did not preserve its prior outcome.'
    }
    $env:CRP_PUBLICATION = Join-Path $artifacts 'missing-publication.json'
    $env:CRP_OUTPUT = Join-Path $artifacts 'registry-invalid-input.json'
    $rejected = $false
    try {
        & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    }
    catch {
        $rejected = $true
        Write-Output "Expected missing-publication rejection: $($_.Exception.Message)"
    }
    if (-not $rejected -or (Test-Path $env:CRP_OUTPUT)) {
        throw 'Missing registry input must not become an empty-work outcome.'
    }
    $env:CRP_PUBLICATION = $intent
    $env:CRP_OUTPUT = Join-Path $artifacts 'registry-dirty-source.json'
    '// Modified source must fail before registry work.' | Set-Content (Join-Path $fixture 'lib.rs')
    $rejected = $false
    try {
        & "$PSScriptRoot/../scripts/Invoke-ReleasePlan.ps1"
    }
    catch {
        $rejected = $true
        Write-Output "Expected source-mismatch rejection: $($_.Exception.Message)"
    }
    if (-not $rejected) { throw 'Registry dry-run accepted source differing from its intent.' }
    $failed = Get-Content $env:CRP_OUTPUT -Raw | ConvertFrom-Json
    if ($failed.publication_id -cne $publication.id -or $failed.complete -ne $false -or
        $failed.dry_run -ne $true -or $failed.errors.Count -eq 0) {
        throw 'Failed registry attempt did not retain its linked outcome.'
    }
    '' | Set-Content (Join-Path $fixture 'lib.rs')
    if ((Get-FileHash $intent).Hash -cne $digest) {
        throw 'Registry operations changed immutable publication intent.'
    }
    $status = Invoke-BootstrapCommand git @('-C', $fixture, 'status', '--porcelain')
    if ($status) { throw "Read-only action operations changed the fixture: $status" }
    Write-Output 'Read-only checks, preparation and nonempty registry dry-run preserved source and immutable intent.'
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

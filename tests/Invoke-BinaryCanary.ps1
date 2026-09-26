#Requires -Version 7.6
param([Parameter(Mandatory)][string] $Executable)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
& "$PSScriptRoot/../scripts/Install-ArchiveTools.ps1"
$work = Join-Path $env:RUNNER_TEMP "release-native-canary-$([guid]::NewGuid().ToString('N'))"
$source = Join-Path $work 'source'
$artifacts = Join-Path $work 'artifacts'
$target = switch ("$env:RUNNER_OS-$env:RUNNER_ARCH") {
    Linux-X64 { 'x86_64-unknown-linux-gnu' }
    Linux-ARM64 { 'aarch64-unknown-linux-gnu' }
    Windows-X64 { 'x86_64-pc-windows-msvc' }
    Windows-ARM64 { 'aarch64-pc-windows-msvc' }
    macOS-ARM64 { 'aarch64-apple-darwin' }
    default { throw 'Unsupported native canary target.' }
}
try {
    New-Item (Join-Path $source '.cargo') -ItemType Directory -Force | Out-Null
    @'
[package]
name = "release-action-binary-canary"
version = "1.0.0"
edition = "2024"
repository = "https://github.com/folo-rs/cargo-release-plan-action"
include = ["main.rs"]

[[bin]]
name = "canary-bin"
path = "main.rs"

[package.metadata.binstall]
pkg-url = "{ repo }/releases/download/{ name }-v{ version }/{ name }-v{ version }-{ target }.zip"
bin-dir = "{ bin }{ binary-ext }"
pkg-fmt = "zip"
'@ | Set-Content (Join-Path $source 'Cargo.toml')
    'fn main() {}' | Set-Content (Join-Path $source 'main.rs')
    "[toolchain]`nchannel = `"1.98.1`"`nprofile = `"minimal`"" | Set-Content (Join-Path $source 'rust-toolchain.toml')
    @"
schema-version = 1
repository = "folo-rs/cargo-release-plan-action"
release-branch = "main"
targets = ["$target"]
"@ | Set-Content (Join-Path $source '.cargo/release_plan.toml')
    Invoke-BootstrapCommand cargo @('+1.98.1', 'generate-lockfile', '--offline', '--manifest-path', (Join-Path $source 'Cargo.toml'))
    Invoke-BootstrapCommand git @('-C', $source, 'init', '--quiet', '--initial-branch', 'main')
    Invoke-BootstrapCommand git @('-C', $source, 'add', '.')
    Invoke-BootstrapCommand git @('-C', $source, '-c', 'user.name=Native canary', '-c', 'user.email=canary@example.invalid', 'commit', '--quiet', '-m', 'Native fixture')
    Invoke-BootstrapCommand git @('-C', $source, 'config', "url.$source.insteadOf", 'https://github.com/folo-rs/cargo-release-plan-action.git')
    $sha = Invoke-BootstrapCommand git @('-C', $source, 'rev-parse', 'HEAD')
    $manifest = Join-Path $source 'Cargo.toml'
    $publicationPath = Join-Path $artifacts 'publication.json'
    Invoke-BootstrapCommand $Executable @('prepare-publish', '--manifest-path', $manifest, '--source', $sha, '--output', $publicationPath)
    $publication = Get-Content $publicationPath -Raw | ConvertFrom-Json
    $binary = [ordered]@{ name = 'release-action-binary-canary'; bin = 'canary-bin'; version = '1.0.0'; tag = 'release-action-binary-canary-v1.0.0'; source_sha = $sha }
    # Test-only wire fixture mirrors PlatformBatch::seal; production batches are always Rust-generated.
    $payload = ConvertTo-Json -InputObject @(1, $publication.id, 'folo-rs/cargo-release-plan-action', $target, @($binary)) -Depth 8 -Compress
    $batchId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))).ToLowerInvariant()
    $batch = [ordered]@{ schema_version = 1; publication_id = $publication.id; repository = 'folo-rs/cargo-release-plan-action'; target = $target; binaries = @($binary); batch_id = $batchId }
    $batchPath = Join-Path $artifacts 'batch.json'
    $batch | ConvertTo-Json -Depth 8 | Set-Content $batchPath
    $outcomePath = Join-Path $artifacts 'outcome.json'
    $staged = Join-Path $artifacts 'staged'
    Invoke-BootstrapCommand $Executable @('publish', 'binaries', '--publication', $publicationPath, '--batch', $batchPath, '--manifest-path', $manifest, '--output', $outcomePath, '--artifacts', $staged, '--no-upload')
    $outcome = Get-Content $outcomePath -Raw | ConvertFrom-Json
    if ($outcome.complete -or -not $outcome.no_upload -or $outcome.batch_id -cne $batchId -or
        $outcome.items.Count -ne 1 -or $outcome.items[0].status -cne 'staged-only') {
        throw 'Native batch staging did not preserve no-upload outcome semantics.'
    }
    $files = @(Get-ChildItem $staged -Recurse -File)
    if (@($files | Where-Object Extension -EQ '.zip').Count -ne 1 -or @($files | Where-Object Extension -EQ '.sha256').Count -ne 1) {
        throw 'Native staging did not produce the ZIP and checksum pair.'
    }
    if (Invoke-BootstrapCommand git @('-C', $source, 'status', '--porcelain')) { throw 'Binary staging changed source.' }
    Write-Output "Frozen batch staged ZIP/checksum successfully on $target without GitHub queries or uploads."
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}

#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-BootstrapCommand {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [string[]] $Arguments = @()
    )

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable failed with exit code $LASTEXITCODE."
    }
}

function Get-InstallationSettings {
    param(
        [Parameter(Mandatory)][string] $ActionPath,
        [Parameter(Mandatory)][ValidateSet('binstall', 'install', 'path')][string] $Method,
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $TemporaryDirectory,
        [Parameter(Mandatory)][string] $RunnerOS,
        [Parameter(Mandatory)][string] $RunnerArch
    )

    $nativeTargets = @{
        'Linux-X64' = 'x86_64-unknown-linux-gnu'
        'Linux-ARM64' = 'aarch64-unknown-linux-gnu'
        'Windows-X64' = 'x86_64-pc-windows-msvc'
        'Windows-ARM64' = 'aarch64-pc-windows-msvc'
        'macOS-ARM64' = 'aarch64-apple-darwin'
    }
    $target = $nativeTargets["$RunnerOS-$RunnerArch"]
    if (-not $target) { throw "Unsupported native platform: $RunnerOS-$RunnerArch." }

    if ($Method -eq 'path') {
        $packagePath = Join-Path (Resolve-Path -LiteralPath $SourcePath).Path 'packages/cargo-release-plan'
        if (-not (Test-Path (Join-Path $packagePath 'Cargo.toml') -PathType Leaf)) {
            throw "source-path must contain packages/cargo-release-plan/Cargo.toml: $SourcePath"
        }
        return @{
            Method = $Method
            Root = Join-Path $TemporaryDirectory 'cargo-release-plan-source'
            # The source canary compiler is independent of consumer rustup overrides.
            # Final released installations select their compiler from release.json.
            Toolchain = '1.98.1'
            PackagePath = $packagePath
            Target = $target
            Version = $null
            CacheKey = ''
        }
    }

    $manifestPath = Join-Path $ActionPath 'release.json'
    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        throw 'Released installation is blocked: release.json must select the finalized, published tool versions.'
    }
    $release = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($release.schema_version -ne 1) { throw 'Unsupported action release manifest schema.' }
    foreach ($version in @($release.action_version, $release.install_toolchain, $release.cargo_binstall_version, $release.tools.'cargo-release-plan'.version)) {
        if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Action release manifest requires exact stable versions.' }
    }
    $digest = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    return @{
        Method = $Method
        Root = Join-Path $TemporaryDirectory "cargo-release-plan-$Method-$digest"
        Toolchain = $release.install_toolchain
        Target = $target
        Version = $release.tools.'cargo-release-plan'.version
        BinstallVersion = $release.cargo_binstall_version
        # Never use prefix restore keys: every manifest combination has a separate cache.
        CacheKey = "cargo-release-plan-$Method-$RunnerOS-$RunnerArch-$digest"
    }
}

function Assert-ExecutableVersion {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string] $Version
    )

    $actual = (Invoke-BootstrapCommand $Executable @('--version') | Out-String).Trim()
    if ($actual -cne "cargo-release-plan $Version") {
        throw "Executable identity mismatch: expected cargo-release-plan $Version, received '$actual'."
    }
}

function Install-CompatibilityChecker {
    param(
        [Parameter(Mandatory)][string] $ActionPath,
        [Parameter(Mandatory)][hashtable] $Settings
    )

    $release = Get-Content (Join-Path $ActionPath 'release.json') -Raw | ConvertFrom-Json
    $version = $release.tools.'cargo-semver-checks'.version
    if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'The compatibility checker requires an exact version.' }
    $suffix = if ($IsWindows) { '.exe' } else { '' }
    $root = Join-Path $Settings.Root "checker-$version"
    $executable = Join-Path $root "bin/cargo-semver-checks$suffix"
    if (-not (Test-Path $executable -PathType Leaf)) {
        Invoke-BootstrapCommand rustup @('toolchain', 'install', $Settings.Toolchain, '--profile', 'minimal', '--no-self-update') | Out-Host
        if ($Settings.Method -eq 'install') {
            Invoke-BootstrapCommand cargo @("+$($Settings.Toolchain)", 'install', 'cargo-semver-checks', '--version', "=$version", '--locked', '--root', $root, '--target', $Settings.Target) | Out-Host
        }
        else {
            # The checker is external published tooling even when the controller is built from source.
            $installerRoot = Join-Path $Settings.Root 'installer'
            $installer = Join-Path $installerRoot "bin/cargo-binstall$suffix"
            if (-not (Test-Path $installer -PathType Leaf)) {
                Invoke-BootstrapCommand cargo @("+$($Settings.Toolchain)", 'install', 'cargo-binstall', '--version', "=$($release.cargo_binstall_version)", '--locked', '--root', $installerRoot) | Out-Host
            }
            $originalToolchain = $env:RUSTUP_TOOLCHAIN
            try {
                $env:RUSTUP_TOOLCHAIN = $Settings.Toolchain
                Invoke-BootstrapCommand $installer @('cargo-semver-checks', '--version', "=$version", '--locked', '--no-confirm', '--root', $root, '--no-track', '--target', $Settings.Target) | Out-Host
            }
            finally {
                $env:RUSTUP_TOOLCHAIN = $originalToolchain
            }
        }
    }
    $actual = (Invoke-BootstrapCommand $executable @('--version') | Out-String).Trim()
    if ($actual -cne "cargo-semver-checks $version") {
        throw "Compatibility checker identity mismatch: expected cargo-semver-checks $version."
    }
    return $executable
}

function Install-ReleasePlan {
    param(
        [Parameter(Mandatory)][hashtable] $Settings,
        [switch] $ArchiveOnly
    )

    if ($ArchiveOnly -and $Settings.Method -ne 'binstall') {
        throw 'Archive-only acceptance requires binstall.'
    }

    $suffix = if ($IsWindows) { '.exe' } else { '' }
    $executable = Join-Path $Settings.Root "bin/cargo-release-plan$suffix"
    if ($Settings.Method -ne 'path' -and (Test-Path $executable -PathType Leaf)) {
        Assert-ExecutableVersion $executable $Settings.Version
        return $executable
    }

    Invoke-BootstrapCommand rustup @('toolchain', 'install', $Settings.Toolchain, '--profile', 'minimal', '--no-self-update') | Out-Host
    $cargo = @("+$($Settings.Toolchain)")
    $install = @('install', '--locked', '--root', $Settings.Root, '--target', $Settings.Target)
    if ($Settings.Method -eq 'path') {
        $metadataArguments = $cargo + @('metadata', '--no-deps', '--format-version', '1', '--manifest-path', (Join-Path $Settings.PackagePath 'Cargo.toml'))
        $metadata = (Invoke-BootstrapCommand cargo $metadataArguments | Out-String) | ConvertFrom-Json
        $package = @($metadata.packages | Where-Object name -EQ 'cargo-release-plan')
        if ($package.Count -ne 1) { throw 'Source metadata must identify exactly one cargo-release-plan package.' }
        $Settings.Version = $package[0].version
        # --force ensures an unchanged declared version never reuses another source executable.
        Invoke-BootstrapCommand cargo ($cargo + $install + @('--path', $Settings.PackagePath, '--force')) | Out-Host
    }
    elseif ($Settings.Method -eq 'install') {
        Invoke-BootstrapCommand cargo ($cargo + $install + @('cargo-release-plan', '--version', "=$($Settings.Version)")) | Out-Host
    }
    else {
        $binstallRoot = Join-Path $Settings.Root 'installer'
        Invoke-BootstrapCommand cargo ($cargo + @('install', 'cargo-binstall', '--version', "=$($Settings.BinstallVersion)", '--locked', '--root', $binstallRoot)) | Out-Host
        $binstall = Join-Path $binstallRoot "bin/cargo-binstall$suffix"
        # Normal binstall source fallback uses the installation compiler, not the consumer override.
        $originalToolchain = $env:RUSTUP_TOOLCHAIN
        try {
            $env:RUSTUP_TOOLCHAIN = $Settings.Toolchain
            # --root applies to both archive extraction and compile fallback.
            $arguments = @('cargo-release-plan', '--version', "=$($Settings.Version)", '--locked', '--no-confirm', '--root', $Settings.Root, '--no-track', '--target', $Settings.Target)
            if ($ArchiveOnly) {
                # Archive acceptance must not succeed through compilation or quickinstall.
                $arguments += @('--strategies', 'crate-meta-data')
            }
            Invoke-BootstrapCommand $binstall $arguments | Out-Host
        }
        finally {
            $env:RUSTUP_TOOLCHAIN = $originalToolchain
        }
    }
    Assert-ExecutableVersion $executable $Settings.Version
    return $executable
}

Export-ModuleMember -Function Get-InstallationSettings, Install-ReleasePlan, Install-CompatibilityChecker, Invoke-BootstrapCommand

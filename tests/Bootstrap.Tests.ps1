#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
}

Describe 'Installation selection' {
    BeforeEach {
        $script:Parameters = @{
            ActionPath = Join-Path $TestDrive 'action'
            Method = 'install'
            SourcePath = Join-Path $TestDrive 'source'
            TemporaryDirectory = $TestDrive
            RunnerOS = 'Linux'
            RunnerArch = 'X64'
        }
        New-Item $script:Parameters.ActionPath -ItemType Directory -Force | Out-Null
        Copy-Item "$PSScriptRoot/fixtures/release.json" (Join-Path $script:Parameters.ActionPath 'release.json')
    }

    It 'keys released binaries by exact manifest, operating system and architecture' {
        $original = Get-InstallationSettings @script:Parameters
        $script:Parameters.RunnerArch = 'ARM64'
        $arm = Get-InstallationSettings @script:Parameters
        $arm.CacheKey | Should -Not -Be $original.CacheKey
        $script:Parameters.RunnerOS = 'Windows'
        $windows = Get-InstallationSettings @script:Parameters
        $windows.CacheKey | Should -Not -Be $arm.CacheKey
        $script:Parameters.RunnerOS = 'Linux'
        $script:Parameters.RunnerArch = 'X64'
        $script:Parameters.Method = 'binstall'
        $binary = Get-InstallationSettings @script:Parameters
        $binary.CacheKey | Should -Not -Be $original.CacheKey
        $binary.Root | Should -Not -Be $original.Root
        $script:Parameters.Method = 'install'
        $manifestPath = Join-Path $script:Parameters.ActionPath 'release.json'
        (Get-Content $manifestPath -Raw).Replace('0.4.0', '0.4.1') | Set-Content $manifestPath
        $updated = Get-InstallationSettings @script:Parameters
        $updated.CacheKey | Should -Not -Be $original.CacheKey
        $updated.Root | Should -Not -Be $original.Root
    }

    It 'rejects an unavailable release manifest rather than using test pins' {
        Remove-Item (Join-Path $script:Parameters.ActionPath 'release.json')
        { Get-InstallationSettings @script:Parameters } | Should -Throw '*Released installation is blocked*'
    }

    It 'rejects floating versions and unsupported manifest schemas' -ForEach @(
        @{ Before = '"0.4.0"'; After = '"latest"' }
        @{ Before = '"schema_version": 1'; After = '"schema_version": 2' }
    ) {
        $manifestPath = Join-Path $script:Parameters.ActionPath 'release.json'
        (Get-Content $manifestPath -Raw).Replace($Before, $After) | Set-Content $manifestPath
        { Get-InstallationSettings @script:Parameters } | Should -Throw
    }

    It 'rejects targets with no promised native archive' {
        $script:Parameters.RunnerOS = 'macOS'
        { Get-InstallationSettings @script:Parameters } | Should -Throw '*Unsupported native platform*'
    }

    It 'selects source without a release manifest or released cache' {
        Remove-Item (Join-Path $script:Parameters.ActionPath 'release.json')
        $package = Join-Path $script:Parameters.SourcePath 'packages/cargo-release-plan'
        New-Item $package -ItemType Directory -Force | Out-Null
        '' | Set-Content (Join-Path $package 'Cargo.toml')
        $script:Parameters.Method = 'path'
        $settings = Get-InstallationSettings @script:Parameters
        $settings.CacheKey | Should -Be ''
        $settings.Version | Should -BeNullOrEmpty
        $settings.Root | Should -Be (Join-Path $TestDrive 'cargo-release-plan-source')
        $settings.Toolchain | Should -Be '1.98.1'
    }
}

Describe 'Executable installation' {
    BeforeEach {
        $script:Settings = @{
            Method = 'install'
            Root = Join-Path $TestDrive 'tools'
            Toolchain = '1.98.1'
            Version = '0.4.0'
            Target = 'x86_64-unknown-linux-gnu'
            BinstallVersion = '1.23.0'
            PackagePath = Join-Path $TestDrive 'source/packages/cargo-release-plan'
        }
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap {
            if ($Arguments -contains '--version' -and $Executable -like '*cargo-release-plan*') {
                'cargo-release-plan 0.4.0'
            }
            elseif ($Arguments -contains 'metadata') {
                '{"packages":[{"name":"cargo-release-plan","version":"0.4.0"}]}'
            }
        }
        Mock Test-Path -ModuleName Bootstrap { $false }
    }

    It 'installs the exact published package with the pinned compiler and lockfile' {
        Install-ReleasePlan $script:Settings | Should -Match 'cargo-release-plan'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter {
            $Executable -eq 'cargo' -and $Arguments[0] -eq '+1.98.1' -and
            $Arguments -contains 'install' -and $Arguments -contains '--locked' -and
            $Arguments -contains '=0.4.0'
        }
    }

    It 'verifies an existing released executable without rebuilding' {
        Mock Test-Path -ModuleName Bootstrap { $true }
        Install-ReleasePlan $script:Settings | Should -Match 'cargo-release-plan'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0 -ParameterFilter { $Executable -eq 'cargo' }
    }

    It 'rejects a stale executable identity even on a cache hit' {
        Mock Test-Path -ModuleName Bootstrap { $true }
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap { 'cargo-release-plan 0.3.0' }
        { Install-ReleasePlan $script:Settings } | Should -Throw '*identity mismatch*'
    }

    It 'always builds selected source even when a same-version executable exists' {
        Mock Test-Path -ModuleName Bootstrap { $true }
        $script:Settings.Method = 'path'
        $script:Settings.Version = $null
        Install-ReleasePlan $script:Settings | Should -Match 'cargo-release-plan'
        $script:Settings.Version | Should -Be '0.4.0'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter {
            $Executable -eq 'cargo' -and $Arguments -contains 'install' -and
            $Arguments -contains '--path' -and $Arguments -contains '--force' -and
            $Arguments -contains '--locked' -and $Arguments[0] -eq '+1.98.1'
        }
    }

    It 'uses exact binstall pins and permits normal source fallback' {
        $script:Settings.Method = 'binstall'
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap -ParameterFilter {
            $Executable -like '*cargo-binstall*'
        } {
            $env:RUSTUP_TOOLCHAIN | Should -Be '1.98.1'
        }
        Install-ReleasePlan $script:Settings | Should -Match 'cargo-release-plan'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter {
            $Executable -eq 'cargo' -and $Arguments -contains '=1.23.0'
        }
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter {
            $Executable -like '*cargo-binstall*' -and $Arguments -contains '=0.4.0' -and
            $Arguments -contains '--locked' -and $Arguments -contains '--no-confirm' -and
            $Arguments -contains '--root' -and $Arguments -contains $script:Settings.Root -and
            $Arguments -notcontains '--install-path' -and $Arguments -notcontains '--strategies'
        }
    }

    It 'restricts archive acceptance to publisher metadata without source fallback' {
        $script:Settings.Method = 'binstall'
        Install-ReleasePlan $script:Settings -ArchiveOnly | Should -Match 'cargo-release-plan'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter {
            $Executable -like '*cargo-binstall*' -and
            $Arguments -contains '--strategies' -and $Arguments -contains 'crate-meta-data'
        }
    }

    It 'propagates installation failures without claiming executable success' {
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap { throw 'Installation failed.' }
        { Install-ReleasePlan $script:Settings } | Should -Throw '*Installation failed*'
    }
}

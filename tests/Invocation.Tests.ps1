#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
    $script:InvokeAction = Join-Path $PSScriptRoot '../scripts/Invoke-ReleasePlan.ps1'
    $script:OriginalEnvironment = @{}
    foreach ($name in @('GITHUB_WORKSPACE', 'CRP_EXECUTABLE', 'CRP_COMMAND', 'CRP_WORKING_DIRECTORY', 'CRP_BASE', 'CRP_CONFIG', 'CRP_SOURCE', 'CRP_OUTPUT')) {
        $script:OriginalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($entry in $script:OriginalEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
}

Describe 'Action command forwarding' {
    BeforeEach {
        Mock Import-Module {}
        Mock Invoke-BootstrapCommand {}
        $env:GITHUB_WORKSPACE = $TestDrive
        $env:CRP_EXECUTABLE = Join-Path $TestDrive 'selected-executable'
        $env:CRP_WORKING_DIRECTORY = 'nested workspace'
        $env:CRP_BASE = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $env:CRP_CONFIG = '.cargo/release_plan.toml'
        $env:CRP_SOURCE = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $env:CRP_OUTPUT = Join-Path $TestDrive 'artifacts/publication.json'
        New-Item (Join-Path $TestDrive $env:CRP_WORKING_DIRECTORY) -ItemType Directory -Force | Out-Null
    }

    It 'passes the caller token only to preparation, not tool source builds' {
        $metadata = Get-Content "$PSScriptRoot/../action.yml" -Raw
        $marker = $metadata.IndexOf('    - name: Run cargo-release-plan', [StringComparison]::Ordinal)
        $marker | Should -BeGreaterThan 0
        $metadata.Substring(0, $marker) | Should -Not -Match 'GH_TOKEN:'
        $invocation = $metadata.Substring($marker)
        $invocation | Should -Match ([regex]::Escape('GH_TOKEN: ${{ inputs.command == ''prepare-publish'' && github.token || '''' }}'))
    }

    It 'uses the selected executable for identity without acquiring a workspace' {
        $env:CRP_COMMAND = 'version'
        $env:CRP_WORKING_DIRECTORY = 'missing'
        & $script:InvokeAction
        Should -Invoke Invoke-BootstrapCommand -Times 1 -ParameterFilter {
            $Executable -eq $env:CRP_EXECUTABLE -and $Arguments.Count -eq 1 -and $Arguments[0] -eq '--version'
        }
    }

    It 'keeps queue readiness narrow with the explicit baseline and selected workspace' {
        $env:CRP_COMMAND = 'version-readiness'
        $originalDirectory = (Get-Location).Path
        Mock Invoke-BootstrapCommand {
            (Get-Location).Path | Should -Be (Join-Path $TestDrive 'nested workspace')
        }
        & $script:InvokeAction
        (Get-Location).Path | Should -Be $originalDirectory
        Should -Invoke Invoke-BootstrapCommand -Times 1 -ParameterFilter {
            $Executable -eq $env:CRP_EXECUTABLE -and
            ($Arguments -join '|') -eq "check|--manifest-path|Cargo.toml|--base|$env:CRP_BASE|--format|github"
        }
    }

    It 'rejects a mutable baseline before invoking Cargo' {
        $env:CRP_COMMAND = 'version-readiness'
        $env:CRP_BASE = 'main'
        { & $script:InvokeAction } | Should -Throw '*immutable base*'
        Should -Invoke Invoke-BootstrapCommand -Times 0
    }

    It 'forwards one explicit workspace-relative config without parsing it' {
        $env:CRP_COMMAND = 'check'
        $env:CRP_CONFIG = '.cargo/custom release.toml'
        & $script:InvokeAction
        Should -Invoke Invoke-BootstrapCommand -Times 1 -ParameterFilter {
            $Executable -eq $env:CRP_EXECUTABLE -and
            ($Arguments -join '|') -eq "check|--manifest-path|Cargo.toml|--base|$env:CRP_BASE|--format|github|--config|.cargo/custom release.toml"
        }
    }

    It 'rejects an empty config rather than silently running a narrower check' {
        $env:CRP_COMMAND = 'check'
        $env:CRP_CONFIG = ''
        { & $script:InvokeAction } | Should -Throw '*requires an explicit*configuration*'
        Should -Invoke Invoke-BootstrapCommand -Times 0
    }

    It 'preserves invalid-configuration errors from the application' {
        $env:CRP_COMMAND = 'check'
        Mock Invoke-BootstrapCommand { throw 'Invalid configuration.' }
        { & $script:InvokeAction } | Should -Throw '*Invalid configuration*'
    }

    It 'does not expose an unfinished publication command' {
        $env:CRP_COMMAND = 'publish'
        { & $script:InvokeAction } | Should -Throw '*Unsupported action command*'
        Should -Invoke Invoke-BootstrapCommand -Times 0
    }

    It 'keeps the controller separate from the selected publication source' {
        $env:CRP_COMMAND = 'prepare-publish'
        Mock Invoke-BootstrapCommand {
            (Get-Location).Path | Should -Be (Join-Path $TestDrive 'nested workspace')
        }
        & $script:InvokeAction
        Should -Invoke Invoke-BootstrapCommand -Times 1 -ParameterFilter {
            $Executable -eq $env:CRP_EXECUTABLE -and
            ($Arguments -join '|') -eq "prepare-publish|--manifest-path|Cargo.toml|--config|$env:CRP_CONFIG|--source|$env:CRP_SOURCE|--output|$env:CRP_OUTPUT"
        }
    }

    It 'requires preparation source and output rather than choosing a branch tip' -ForEach @(
        @{ Missing = 'source' }
        @{ Missing = 'output' }
        @{ Missing = 'config' }
    ) {
        $env:CRP_COMMAND = 'prepare-publish'
        switch ($Missing) {
            source { $env:CRP_SOURCE = 'main' }
            output { $env:CRP_OUTPUT = '' }
            config { $env:CRP_CONFIG = '' }
        }
        { & $script:InvokeAction } | Should -Throw '*requires*'
        Should -Invoke Invoke-BootstrapCommand -Times 0
    }

    It 'preserves invocation errors and restores the caller directory' {
        $env:CRP_COMMAND = 'version-readiness'
        $originalDirectory = (Get-Location).Path
        Mock Invoke-BootstrapCommand { throw 'Version readiness failed.' }
        { & $script:InvokeAction } | Should -Throw '*Version readiness failed*'
        (Get-Location).Path | Should -Be $originalDirectory
    }
}

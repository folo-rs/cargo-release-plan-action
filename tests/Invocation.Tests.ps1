#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
    $script:InvokeAction = Join-Path $PSScriptRoot '../scripts/Invoke-ReleasePlan.ps1'
    $script:OriginalEnvironment = @{}
    foreach ($name in @('GITHUB_WORKSPACE', 'CRP_EXECUTABLE', 'CRP_COMMAND', 'CRP_WORKING_DIRECTORY', 'CRP_BASE')) {
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
        New-Item (Join-Path $TestDrive $env:CRP_WORKING_DIRECTORY) -ItemType Directory -Force | Out-Null
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

    It 'does not expose an unfinished publication command' {
        $env:CRP_COMMAND = 'publish'
        { & $script:InvokeAction } | Should -Throw '*Unsupported action command*'
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

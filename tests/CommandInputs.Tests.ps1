#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
    $script:Prepare = Join-Path $PSScriptRoot '../scripts/Bootstrap.ps1'
    $script:OriginalEnvironment = @{}
    foreach ($name in @('CRP_INPUTS_JSON', 'CRP_COMMAND', 'CRP_ACTION_PATH', 'CRP_INSTALL_METHOD', 'CRP_SOURCE_PATH', 'CRP_WORKING_DIRECTORY', 'GITHUB_WORKSPACE', 'GITHUB_OUTPUT', 'RUNNER_TEMP', 'RUNNER_OS', 'RUNNER_ARCH')) {
        $script:OriginalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    function Invoke-InputPreparation {
        $env:CRP_COMMAND = $script:Inputs.command
        $env:CRP_INPUTS_JSON = $script:Inputs | ConvertTo-Json -Compress
        & $script:Prepare -Stage prepare
    }
}

AfterAll {
    foreach ($entry in $script:OriginalEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
}

Describe 'Composite command input validation' {
    BeforeEach {
        Mock Import-Module {}
        Mock Get-InstallationSettings { @{ Root = 'selected-root'; CacheKey = 'selected-key' } }
        Mock Install-ReleasePlan { throw 'Unexpected installation during input validation.' }
        Mock Invoke-BootstrapCommand { throw 'Unexpected command execution during input validation.' }
        Mock Invoke-WebRequest { throw 'Unexpected download during input validation.' }
        $env:CRP_ACTION_PATH = (Resolve-Path "$PSScriptRoot/..").Path
        $env:CRP_INSTALL_METHOD = 'binstall'
        $env:CRP_SOURCE_PATH = '.'
        $env:CRP_WORKING_DIRECTORY = '.'
        $env:GITHUB_WORKSPACE = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive "$([guid]::NewGuid()).txt"
        $env:RUNNER_TEMP = $TestDrive
        $env:RUNNER_OS = 'Windows'
        $env:RUNNER_ARCH = 'X64'
        $script:Inputs = @{
            command = 'version'; 'working-directory' = '.'; 'install-method' = 'binstall'; 'source-path' = '.'
            config = '.cargo/release_plan.toml'
            base = ''; source = ''; publication = ''; output = ''; prepared = ''; plan = ''
            batches = ''; batch = ''; artifacts = ''; outcomes = ''; jobs = ''; repository = ''
            'deny-findings' = 'false'; 'dry-run' = 'false'; 'no-upload' = 'false'; 'no-issue' = 'false'
        }
    }

    It 'accepts normal defaults for <Command> without running any command' -ForEach @(
        @{ Command = 'version' }
        @{ Command = 'version-readiness' }
        @{ Command = 'check' }
        @{ Command = 'release-context' }
        @{ Command = 'check-compatibility' }
        @{ Command = 'check-published' }
        @{ Command = 'check-publishing-identity' }
        @{ Command = 'prepare-publish' }
        @{ Command = 'publish-registry' }
        @{ Command = 'publish-github' }
        @{ Command = 'publish-binaries' }
        @{ Command = 'publish-report' }
    ) {
        $script:Inputs.command = $Command
        Invoke-InputPreparation
        Should -Invoke Get-InstallationSettings -Times 1 -Exactly
        Should -Invoke Install-ReleasePlan -Times 0
        Should -Invoke Invoke-BootstrapCommand -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Get-Content $env:GITHUB_OUTPUT | Should -Contain 'root=selected-root'
    }

    It 'rejects <InputName> for <Command> before selecting or installing tools' -ForEach @(
        @{ Command = 'version'; InputName = 'publication'; Value = 'publication.json' }
        @{ Command = 'version'; InputName = 'batch'; Value = 'batch.json' }
        @{ Command = 'version'; InputName = 'output'; Value = 'outcome.json' }
        @{ Command = 'version'; InputName = 'dry-run'; Value = 'true' }
        @{ Command = 'version'; InputName = 'config'; Value = '.cargo/another.toml' }
        @{ Command = 'version-readiness'; InputName = 'config'; Value = '.cargo/another.toml' }
        @{ Command = 'check'; InputName = 'deny-findings'; Value = 'true' }
        @{ Command = 'release-context'; InputName = 'source'; Value = 'abc' }
        @{ Command = 'check-compatibility'; InputName = 'config'; Value = '.cargo/another.toml' }
        @{ Command = 'check-published'; InputName = 'base'; Value = 'abc' }
        @{ Command = 'check-publishing-identity'; InputName = 'publication'; Value = 'publication.json' }
        @{ Command = 'prepare-publish'; InputName = 'dry-run'; Value = 'true' }
        @{ Command = 'publish-registry'; InputName = 'batch'; Value = 'batch.json' }
        @{ Command = 'publish-github'; InputName = 'no-upload'; Value = 'true' }
        @{ Command = 'publish-binaries'; InputName = 'dry-run'; Value = 'true' }
        @{ Command = 'publish-binaries'; InputName = 'no-issue'; Value = 'true' }
        @{ Command = 'publish-report'; InputName = 'config'; Value = '.cargo/another.toml' }
        @{ Command = 'publish-report'; InputName = 'artifacts'; Value = 'staging' }
    ) {
        $script:Inputs.command = $Command
        $script:Inputs[$InputName] = $Value
        { Invoke-InputPreparation } | Should -Throw "*Input '$InputName' is not supported for command '$Command'*"
        Should -Invoke Get-InstallationSettings -Times 0
        Should -Invoke Install-ReleasePlan -Times 0
        Should -Invoke Invoke-BootstrapCommand -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        Test-Path $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'accepts applicable nondefault inputs for <Command>' -ForEach @(
        @{ Command = 'version-readiness'; Values = @{ base = 'a' * 40 } }
        @{ Command = 'check'; Values = @{ base = 'a' * 40; config = 'custom.toml' } }
        @{ Command = 'release-context'; Values = @{ base = 'a' * 40; config = 'custom.toml' } }
        @{ Command = 'check-compatibility'; Values = @{ base = 'a' * 40; output = 'evidence'; 'deny-findings' = 'true' } }
        @{ Command = 'check-compatibility'; Values = @{ prepared = 'prepared.json'; output = 'evidence' } }
        @{ Command = 'check-compatibility'; Values = @{ plan = 'plan.json'; output = 'evidence' } }
        @{ Command = 'check-published'; Values = @{ plan = 'plan.json' } }
        @{ Command = 'prepare-publish'; Values = @{ config = 'custom.toml'; source = 'b' * 40; output = 'publication.json' } }
        @{ Command = 'publish-registry'; Values = @{ publication = 'publication.json'; output = 'outcome.json'; 'dry-run' = 'true' } }
        @{ Command = 'publish-github'; Values = @{ publication = 'publication.json'; output = 'outcome.json'; batches = 'batches'; 'dry-run' = 'true' } }
        @{ Command = 'publish-binaries'; Values = @{ publication = 'publication.json'; batch = 'batch.json'; output = 'outcome.json'; artifacts = 'staging'; 'no-upload' = 'true' } }
        @{ Command = 'publish-report'; Values = @{ publication = 'publication.json'; output = 'report.md'; outcomes = 'receipts'; jobs = 'jobs.json'; repository = 'example/consumer'; 'no-issue' = 'true' } }
    ) {
        $script:Inputs.command = $Command
        foreach ($entry in $Values.GetEnumerator()) { $script:Inputs[$entry.Key] = $entry.Value }
        Invoke-InputPreparation
        Should -Invoke Get-InstallationSettings -Times 1 -Exactly
    }

    It 'allows empty unused inputs and preserves shared installation context' {
        $script:Inputs.config = ''
        $script:Inputs.'dry-run' = ''
        $script:Inputs.'install-method' = 'path'
        $script:Inputs.'source-path' = 'controller source'
        $script:Inputs.'working-directory' = 'nested workspace'
        $env:CRP_INSTALL_METHOD = $script:Inputs.'install-method'
        $env:CRP_SOURCE_PATH = $script:Inputs.'source-path'
        $env:CRP_WORKING_DIRECTORY = $script:Inputs.'working-directory'
        Invoke-InputPreparation
        Should -Invoke Get-InstallationSettings -Times 1 -ParameterFilter {
            $Method -eq 'path' -and $SourcePath -eq (Join-Path $TestDrive 'controller source')
        }
    }

    It 'rejects unknown commands before installation settings are selected' {
        $script:Inputs.command = 'not-a-command'
        { Invoke-InputPreparation } | Should -Throw '*Unsupported action command*'
        Should -Invoke Get-InstallationSettings -Times 0
    }
}

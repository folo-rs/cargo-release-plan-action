#Requires -Version 7.6

BeforeAll {
    $workflow = Get-Content "$PSScriptRoot\..\.github\workflows\action-source.yml" -Raw
    $source = [regex]::Match($workflow, '(?s)# BEGIN SELF-RESOLUTION\r?\n(.*?)\s*# END SELF-RESOLUTION').Groups[1].Value
    if (-not $source) { throw 'The workflow self-resolution block is missing.' }
    $script:ResolveActionSource = [scriptblock]::Create($source)
    $script:OriginalEnvironment = @{}
    foreach ($name in @('GITHUB_API_URL', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_OUTPUT', 'GITHUB_SHA', 'GH_TOKEN')) {
        $script:OriginalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($entry in $script:OriginalEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
    }
}

Describe 'Called workflow source resolution' {
    BeforeEach {
    $env:GITHUB_API_URL = 'https://api.github.com'
    $env:GITHUB_REPOSITORY = 'consumer/project'
    $env:GITHUB_RUN_ID = '123'
    $env:GITHUB_RUN_ATTEMPT = '2'
    $env:GITHUB_SHA = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $env:GH_TOKEN = 'test-only-token'
    $env:GITHUB_OUTPUT = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $script:ActionSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $script:Metadata = @{
        id = 123
        run_attempt = 2
        referenced_workflows = @(@{
            path = 'folo-rs/cargo-release-plan-action/.github/workflows/action-source.yml@v1'
            sha = $script:ActionSha
        })
    }
    Mock Invoke-RestMethod { $script:Metadata }
    }
    It 'uses current-attempt metadata instead of caller context or a mutable ref' {
        & $script:ResolveActionSource
        (Get-Content $env:GITHUB_OUTPUT) | Should -Be "sha=$script:ActionSha"
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/consumer/project/actions/runs/123/attempts/2' -and
            $Headers.Authorization -eq 'Bearer test-only-token'
        }
    }

    It 'accepts SHA, immutable-tag and moving-major references' -ForEach @(
        @{ Ref = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
        @{ Ref = 'v1.2.3' }
        @{ Ref = 'v1' }
    ) {
        $script:Metadata.referenced_workflows[0].path = "folo-rs/cargo-release-plan-action/.github/workflows/action-source.yml@$Ref"
        & $script:ResolveActionSource
        (Get-Content $env:GITHUB_OUTPUT) | Should -Be "sha=$script:ActionSha"
    }

    It 'ignores unrelated workflows in nested call graphs' {
        $script:Metadata.referenced_workflows += @{
            path = 'another/repository/.github/workflows/action-source.yml@v1'
            sha = $env:GITHUB_SHA
        }
        & $script:ResolveActionSource
        (Get-Content $env:GITHUB_OUTPUT) | Should -Be "sha=$script:ActionSha"
    }

    It 'accepts GitHub repository names without depending on their case' {
        $script:Metadata.referenced_workflows[0].path = 'FOLO-RS/CARGO-RELEASE-PLAN-ACTION/.github/workflows/action-source.yml@v1'
        & $script:ResolveActionSource
        (Get-Content $env:GITHUB_OUTPUT) | Should -Be "sha=$script:ActionSha"
    }

    It 'accepts repeated calls of the same exact revision' {
        $script:Metadata.referenced_workflows += $script:Metadata.referenced_workflows[0]
        & $script:ResolveActionSource
        (Get-Content $env:GITHUB_OUTPUT) | Should -Be "sha=$script:ActionSha"
    }

    It 'rejects ambiguous revisions' {
        $script:Metadata.referenced_workflows += @{
            path = 'folo-rs/cargo-release-plan-action/.github/workflows/action-source.yml@v2'
            sha = $env:GITHUB_SHA
        }
        { & $script:ResolveActionSource } | Should -Throw '*one exact*'
        Test-Path $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects missing, malformed or wrong-attempt evidence' -ForEach @(
        @{ Case = 'missing' }
        @{ Case = 'malformed' }
        @{ Case = 'attempt' }
        @{ Case = 'run' }
    ) {
        switch ($Case) {
            missing { $script:Metadata.referenced_workflows = @() }
            malformed { $script:Metadata.referenced_workflows[0].sha = 'main' }
            attempt { $script:Metadata.run_attempt = 1 }
            run { $script:Metadata.id = 456 }
        }
        { & $script:ResolveActionSource } | Should -Throw
        Test-Path $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'does not substitute another identity after an API error' {
        Mock Invoke-RestMethod { throw 'Forbidden' }
        { & $script:ResolveActionSource } | Should -Throw '*Forbidden*'
        Test-Path $env:GITHUB_OUTPUT | Should -BeFalse
    }
}

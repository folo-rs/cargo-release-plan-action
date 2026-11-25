#Requires -Version 7.6
BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/Workflow.psm1" -Force
}

Describe 'Workflow artifact routing' {
    BeforeEach {
        $script:Intent = Join-Path $TestDrive 'publication.json'
        $script:Outcome = Join-Path $TestDrive 'outcome.json'
        $script:Target = 'x86_64-unknown-linux-gnu'
        $script:PublicationId = 'a' * 64
        $script:BatchId = 'b' * 64
        @{ id = $script:PublicationId } | ConvertTo-Json | Set-Content $script:Intent
        $script:Receipt = @{
            schema_version = 1
            publication_id = $script:PublicationId
            phase = 'github'
            dry_run = $false
            complete = $false
            batches = @(@{ target = $script:Target; path = "$script:Target.json"; batch_id = $script:BatchId })
        }
        $script:Receipt | ConvertTo-Json -Depth 5 | Set-Content $script:Outcome
        @{ publication_id = $script:PublicationId; target = $script:Target; batch_id = $script:BatchId } |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive "$script:Target.json")
    }

    It 'admits valid batches despite an incomplete GitHub receipt' {
        Get-BatchRouting -Outcome $script:Outcome -Publication $script:Intent -Batches $TestDrive -Target $script:Target |
            Should -Be (Join-Path $TestDrive "$script:Target.json")
    }

    It 'returns no batch only for a valid receipt with no request for the slot' {
        Get-BatchRouting -Outcome $script:Outcome -Publication $script:Intent -Batches $TestDrive -Target 'aarch64-apple-darwin' |
            Should -BeNullOrEmpty
    }

    It 'rejects missing evidence rather than interpreting it as empty work' {
        Remove-Item $script:Outcome
        { Get-BatchRouting -Outcome $script:Outcome -Publication $script:Intent -Batches $TestDrive -Target $script:Target } |
            Should -Throw
    }

    It 'rejects unrelated, dry-run, escaped or duplicate routing' -ForEach @(
        @{ Invalid = 'publication' }
        @{ Invalid = 'dry-run' }
        @{ Invalid = 'path' }
        @{ Invalid = 'duplicate' }
        @{ Invalid = 'batch' }
    ) {
        switch ($Invalid) {
            publication { $script:Receipt.publication_id = 'c' * 64 }
            dry-run { $script:Receipt.dry_run = $true }
            path { $script:Receipt.batches[0].path = '../outside.json' }
            duplicate { $script:Receipt.batches += $script:Receipt.batches[0] }
            batch { $script:Receipt.batches[0].batch_id = 'c' * 64 }
        }
        $script:Receipt | ConvertTo-Json -Depth 5 | Set-Content $script:Outcome
        { Get-BatchRouting -Outcome $script:Outcome -Publication $script:Intent -Batches $TestDrive -Target $script:Target } |
            Should -Throw
    }

    It 'passes actual platform results through to the Rust reporter' {
        $output = Join-Path $TestDrive 'jobs.json'
        Write-JobResults -NeedsJson '{"prepare":{"result":"success"},"registry":{"result":"success"},"github":{"result":"failure"},"binaries":{"result":"success"}}' -Output $output
        $jobs = Get-Content $output -Raw | ConvertFrom-Json
        $jobs.github | Should -Be 'failure'
        $jobs.binaries | Should -Be 'success'
    }

    It 'rejects absent platform results rather than defaulting to success' {
        { Write-JobResults -NeedsJson '{}' -Output (Join-Path $TestDrive 'jobs.json') } | Should -Throw
    }
}

Describe 'Release history and target routing' {
    BeforeEach {
        $script:Context = @{
            schema_version = 2
            repository = 'example/consumer'
            release_branch = 'main'
            release_history = 'a' * 40
            merge_target = $null
            head = 'c' * 40
            workspace_manifest = 'Cargo.toml'
            config_path = '.cargo/release_plan.toml'
            concurrency_group = 'cargo-release-plan-' + ('d' * 64)
        }
    }

    It 'preserves the core-normalized history/target pair including an absent target' -ForEach @(
        @{ Target = $null }
        @{ Target = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
    ) {
        $script:Context.merge_target = $Target
        $context = Get-ContextRouting -Json ($script:Context | ConvertTo-Json) -Repository 'example/consumer'
        $context.release_history | Should -Be ('a' * 40)
        $context.merge_target | Should -Be $Target
        $context.head | Should -Be ('c' * 40)
    }

    It 'rejects incompatible context rather than interpreting legacy history' -ForEach @(
        @{ Invalid = 'schema' }
        @{ Invalid = 'history' }
        @{ Invalid = 'target' }
        @{ Invalid = 'missing-target' }
        @{ Invalid = 'repository' }
    ) {
        switch ($Invalid) {
            schema { $script:Context.schema_version = 1 }
            history { $script:Context.release_history = 'main' }
            target { $script:Context.merge_target = 'parent-branch' }
            missing-target { $script:Context.Remove('merge_target') }
            repository { $script:Context.repository = 'other/consumer' }
        }
        { Get-ContextRouting -Json ($script:Context | ConvertTo-Json) -Repository 'example/consumer' } |
            Should -Throw
    }

    It 'selects the PR base snapshot as target regardless of main or stacked branch name' -ForEach @(
        @{ Ref = 'main' }
        @{ Ref = 'feature/parent' }
    ) {
        $event = @{ pull_request = @{ base = @{ sha = 'b' * 40; ref = $Ref }; head = @{ sha = 'c' * 40 } } }
        Get-CheckMergeTarget -EventName pull_request -EventJson ($event | ConvertTo-Json -Depth 4) |
            Should -Be ('b' * 40)
    }

    It 'uses only the tested queue target without interpreting queued PR boundaries' {
        $event = @{ merge_group = @{ base_sha = 'b' * 40; head_sha = 'c' * 40; base_ref = 'refs/heads/main' } }
        Get-CheckMergeTarget -EventName merge_group -EventJson ($event | ConvertTo-Json) |
            Should -Be ('b' * 40)
    }

    It 'does not infer history or target from <Event> event data' -ForEach @(
        @{ Event = 'push' }
        @{ Event = 'schedule' }
        @{ Event = 'workflow_dispatch' }
    ) {
        $event = @{ after = 'c' * 40; ref = 'refs/heads/feature'; inputs = @{ 'release-history' = 'b' * 40 } }
        Get-CheckMergeTarget -EventName $Event -EventJson ($event | ConvertTo-Json) | Should -Be ''
    }

    It 'rejects missing or mutable tested event targets' -ForEach @(
        @{ Event = 'pull_request'; Json = '{"pull_request":{"base":{"sha":"main"}}}' }
        @{ Event = 'merge_group'; Json = '{"merge_group":{"head_sha":"cccccccccccccccccccccccccccccccccccccccc"}}' }
    ) {
        { Get-CheckMergeTarget -EventName $Event -EventJson $Json } | Should -Throw
    }
}

Describe 'Published installation acceptance' -Tag Integration {
    BeforeAll {
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/published-installation.yml" -Raw
        $script:PublishedJobs = [regex]::Match($workflow, '(?ms)^jobs:\r?\n(.*)$').Groups[1].Value
    }

    It 'generates fresh source and strict archive legs for every required target without scheduling macOS' {
        $matrixJob = [regex]::Match($script:PublishedJobs, '(?ms)^  matrix:\r?\n(.*?)(?=^  install:)').Groups[1].Value
        $run = [regex]::Match($matrixJob, '(?s)        run: \|\r?\n(.*)$').Groups[1].Value
        $originalOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'matrix-output'
        Push-Location "$PSScriptRoot/.."
        try {
            & ([scriptblock]::Create($run))
            $matrix = (Get-Content $env:GITHUB_OUTPUT -Raw).Trim().Substring('legs='.Length) | ConvertFrom-Json
            $release = Get-Content release.json -Raw | ConvertFrom-Json
            $matrix.include.Count | Should -Be (@($release.platforms | Where-Object os -NE macOS).Count * 2)
            @($matrix.include | Where-Object runner -Like 'macos*').Count | Should -Be 0
            foreach ($platform in @($release.platforms | Where-Object os -NE macOS)) {
                $legs = @($matrix.include | Where-Object target -CEQ $platform.target)
                $legs.Count | Should -Be 2
                @($legs.runner | Select-Object -Unique) | Should -Be @($platform.runner)
                @($legs.method | Sort-Object) | Should -Be @('binstall', 'install')
            }
        }
        finally {
            Pop-Location
            $env:GITHUB_OUTPUT = $originalOutput
        }
    }
}

Describe 'Advisory macOS validation boundaries' {
    It 'still blocks required non-macOS <File> results of <Result>' -ForEach @(
        @{ File = 'validate.yml'; Result = 'failure' },
        @{ File = 'validate.yml'; Result = 'cancelled' },
        @{ File = 'validate.yml'; Result = 'skipped' },
        @{ File = 'source-canary.yml'; Result = 'failure' },
        @{ File = 'source-canary.yml'; Result = 'cancelled' },
        @{ File = 'source-canary.yml'; Result = 'skipped' },
        @{ File = 'published-installation.yml'; Result = 'failure' },
        @{ File = 'published-installation.yml'; Result = 'cancelled' },
        @{ File = 'published-installation.yml'; Result = 'skipped' }
    ) {
        $workflow = Get-Content (Join-Path "$PSScriptRoot/../.github/workflows" $File) -Raw
        $gate = [regex]::Match($workflow, '(?ms)^  acceptance:\r?\n(.*?)(?=^  [a-z-]+:)').Groups[1].Value
        $run = [regex]::Match($gate, '(?s)        run: \|\r?\n(.*)$').Groups[1].Value
        if (-not $run) { throw 'Required aggregate command missing.' }
        $originalResults, $originalInstall, $originalMatrix = $env:RESULTS, $env:INSTALL, $env:MATRIX
        try {
            $env:RESULTS = @{ tests = @{ result = 'success' } } | ConvertTo-Json
            $env:INSTALL = 'success'
            $env:MATRIX = 'success'
            $verdict = [scriptblock]::Create($run)
            { & $verdict } | Should -Not -Throw
            $env:RESULTS = @{ tests = @{ result = $Result } } | ConvertTo-Json
            $env:INSTALL = $Result
            { & $verdict } | Should -Throw
            if ($File -eq 'published-installation.yml') {
                $env:INSTALL = 'success'
                $env:MATRIX = $Result
                { & $verdict } | Should -Throw
            }
        }
        finally {
            $env:RESULTS, $env:INSTALL, $env:MATRIX = $originalResults, $originalInstall, $originalMatrix
        }
    }
}

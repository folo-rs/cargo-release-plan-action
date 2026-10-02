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

Describe 'Release graph invariants' {
    It 'holds one noncancelling queue:max lock around the complete nested workflow' {
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/release.yml" -Raw
        $workflow | Should -Match 'uses: \./\.github/workflows/_release.yml'
        $workflow | Should -Match 'cancel-in-progress: false\r?\n\s+queue: max'
        (Get-Content "$PSScriptRoot/../.github/workflows/_release.yml" -Raw) | Should -Not -Match 'concurrency:'
    }

    It 'keeps full PR checks read-only and includes external compatibility enforcement' {
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/check.yml" -Raw
        $workflow | Should -Not -Match 'id-token:|contents: write|issues: write|pull_request_target'
        $workflow | Should -Match 'CRP_COMMAND: check\r?\n'
        $workflow | Should -Match 'CRP_COMMAND: check-compatibility'
        $workflow | Should -Match 'CRP_DENY_FINDINGS: ''true'''
        $workflow | Should -Match 'steps.checker.outcome == ''success'''
        $workflow | Should -Not -Match 'steps.readiness.outcome == ''success'''
        $workflow | Should -Match ([regex]::Escape('CRP_RELEASE_HISTORY: ${{ inputs.release-history }}'))
        $workflow | Should -Match 'Get-CheckMergeTarget -EventName \$env:GITHUB_EVENT_NAME'
        ([regex]::Matches($workflow, [regex]::Escape('CRP_RELEASE_HISTORY: ${{ steps.context.outputs.release-history }}'))).Count | Should -Be 2
        ([regex]::Matches($workflow, [regex]::Escape('CRP_MERGE_TARGET: ${{ steps.context.outputs.merge-target }}'))).Count | Should -Be 2
        $workflow | Should -Not -Match 'github.sha'
    }

    It 'preserves failed reconciliation while allowing registry-gated independent batches' {
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/_release.yml" -Raw
        $binaries = $workflow.Substring($workflow.IndexOf('  binaries:'))
        $binaries | Should -Match "needs.registry.result == 'success'"
        $binaries | Should -Match "needs.github.result == 'failure'"
        $binaries | Should -Match '!cancelled\(\)'
        $binaries | Should -Match 'fail-fast: false'
        $beforeReporter = $workflow.Substring(0, $workflow.IndexOf('  report:'))
        $beforeReporter | Should -Not -Match 'continue-on-error: true'
        $workflow | Should -Match 'merge-multiple: false'
    }

    It 'keeps OIDC confined to the registry job within publication execution' {
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/_release.yml" -Raw
        ([regex]::Matches($workflow, 'id-token: write')).Count | Should -Be 1
        $registry = $workflow.Substring($workflow.IndexOf('  registry:'), $workflow.IndexOf('  github:') - $workflow.IndexOf('  registry:'))
        $registry | Should -Match 'id-token: write'
        $registry | Should -Match 'restore-controller'
        $registry | Should -Not -Match 'command: version'
    }

    It 'requires original intent on reruns and never overwrites its artifact' {
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/_release.yml" -Raw
        $workflow | Should -Match 'if: github.run_attempt > 1'
        $workflow | Should -Match 'if: github.run_attempt == 1'
        $workflow | Should -Not -Match 'overwrite: true'
    }

    It 'separates historical release source from invocation controller code' {
        $outer = Get-Content "$PSScriptRoot/../.github/workflows/release.yml" -Raw
        $inner = Get-Content "$PSScriptRoot/../.github/workflows/_release.yml" -Raw
        $outer | Should -Match ([regex]::Escape('ref: ${{ inputs.source || github.sha }}'))
        foreach ($workflow in @($outer, $inner)) {
            $workflow | Should -Match 'ref: \$\{\{ github.sha \}\}\r?\n\s+path: invocation'
            $workflow | Should -Match 'source-path: invocation/\$\{\{ inputs.source-path \}\}'
        }
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
        $script:OriginalInstallResult = $env:INSTALL
        $script:OriginalMatrixResult = $env:MATRIX
        $env:MATRIX = 'success'
        $workflow = Get-Content "$PSScriptRoot/../.github/workflows/published-installation.yml" -Raw
        $script:PublishedJobs = [regex]::Match($workflow, '(?ms)^jobs:\r?\n(.*)$').Groups[1].Value
        $script:PublishedAcceptance = [regex]::Match($script:PublishedJobs, '(?ms)^  acceptance:\r?\n(.*?)(?=^  matrix:)').Groups[1].Value
        $run = [regex]::Match($script:PublishedAcceptance, '(?s)        run: \|\r?\n(.*)$').Groups[1].Value
        if (-not $run) { throw 'Published installation acceptance command is missing.' }
        $script:PublishedVerdict = [scriptblock]::Create($run)
    }

    Describe 'Action self-publication workflow boundaries' -Tag Integration {
        It 'gates a main-only serialized publisher on repeated exact-commit installation' {
            $workflow = Get-Content "$PSScriptRoot/../.github/workflows/publish-action.yml" -Raw
            $workflow | Should -Match 'push:\r?\n\s+branches: \[main\]'
            $workflow | Should -Match 'workflow_dispatch:'
            $workflow | Should -Not -Match 'pull_request:|workflow_call:|id-token:|issues: write'
            ([regex]::Matches($workflow, "github.repository == 'folo-rs/cargo-release-plan-action' && github.ref == 'refs/heads/main'")).Count | Should -Be 2
            $workflow | Should -Match 'uses: \./\.github/workflows/published-installation.yml'
            $workflow | Should -Match 'needs: availability'
            $workflow | Should -Match 'cancel-in-progress: false\r?\n\s+queue: max'
            $workflow | Should -Match 'ref: \$\{\{ github.sha \}\}'
            $workflow | Should -Match 'fetch-depth: 0'
            $beforePublish = $workflow.Substring(0, $workflow.IndexOf('  publish:'))
            $beforePublish | Should -Match 'contents: read'
            $beforePublish | Should -Not -Match 'contents: write'
            ([regex]::Matches($workflow, 'contents: write')).Count | Should -Be 1
            $workflow | Should -Match 'Publish-Release.ps1 -BaseRef \$base'
        }

        It 'reports required aggregates for all PR file changes including documentation' -ForEach @(
            @{ File = 'validate.yml'; Check = 'Action validation' }
            @{ File = 'source-canary.yml'; Check = 'Source installation' }
            @{ File = 'published-installation.yml'; Check = 'Published installation' }
            @{ File = 'scheduling-canary.yml'; Check = 'Workflow scheduling' }
        ) {
            $workflow = Get-Content (Join-Path "$PSScriptRoot/../.github/workflows" $File) -Raw
            $workflow | Should -Match '(?m)^  pull_request:'
            $workflow | Should -Not -Match 'paths:|paths-ignore:'
            $workflow | Should -Match "(?m)^    name: $Check"
            $workflow | Should -Match 'if: always\(\)'
        }

        It 'includes action version readiness in the existing validation aggregate' {
            $workflow = Get-Content "$PSScriptRoot/../.github/workflows/validate.yml" -Raw
            $workflow | Should -Match 'needs: \[identity, tests, workflows, version-readiness\]'
            $workflow | Should -Match 'Get-ValidationReleaseBase -EventName \$env:GITHUB_EVENT_NAME'
            $workflow | Should -Match 'Publish-Release.ps1 -CheckOnly -BaseRef \$base'
        }
    }

    AfterAll {
        $env:INSTALL = $script:OriginalInstallResult
        $env:MATRIX = $script:OriginalMatrixResult
    }

    It 'keeps the named required gate dependent on the complete install matrix' {
        $jobs = @([regex]::Matches($script:PublishedJobs, '(?m)^  ([a-z-]+):\r?$') | ForEach-Object { $_.Groups[1].Value })
        $jobs | Should -Be @('acceptance', 'matrix', 'install')
        $script:PublishedAcceptance | Should -Match '(?m)^    name: Published installation\r?$'
        $script:PublishedAcceptance | Should -Match '(?m)^    needs: \[matrix, install\]\r?$'
        $script:PublishedAcceptance | Should -Match '(?m)^    if: always\(\)\r?$'
        $script:PublishedAcceptance | Should -Match ([regex]::Escape('INSTALL: ${{ needs.install.result }}'))
    }

    It 'accepts a successful matrix result' {
        $env:INSTALL = 'success'
        { & $script:PublishedVerdict } | Should -Not -Throw
    }

    It 'rejects a matrix result of <Result>' -ForEach @(
        @{ Result = 'failure' }
        @{ Result = 'cancelled' }
        @{ Result = 'skipped' }
        @{ Result = '' }
    ) {
        $env:INSTALL = $Result
        { & $script:PublishedVerdict } | Should -Throw '*installation are required*'
    }

    It 'rejects missing matrix generation even if installations report success' {
        $env:INSTALL = 'success'
        $env:MATRIX = 'failure'
        try { { & $script:PublishedVerdict } | Should -Throw '*installation are required*' }
        finally { $env:MATRIX = 'success' }
    }

    It 'generates fresh source and strict archive legs for every declared target' {
        $matrixJob = [regex]::Match($script:PublishedJobs, '(?ms)^  matrix:\r?\n(.*?)(?=^  install:)').Groups[1].Value
        $run = [regex]::Match($matrixJob, '(?s)        run: \|\r?\n(.*)$').Groups[1].Value
        $originalOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'matrix-output'
        Push-Location "$PSScriptRoot/.."
        try {
            & ([scriptblock]::Create($run))
            $matrix = (Get-Content $env:GITHUB_OUTPUT -Raw).Trim().Substring('legs='.Length) | ConvertFrom-Json
            $release = Get-Content release.json -Raw | ConvertFrom-Json
            $matrix.include.Count | Should -Be ($release.platforms.Count * 2)
            foreach ($platform in $release.platforms) {
                $legs = @($matrix.include | Where-Object target -CEQ $platform.target)
                $legs.Count | Should -Be 2
                @($legs.runner | Select-Object -Unique) | Should -Be @($platform.runner)
                @($legs.method | Sort-Object) | Should -Be @('binstall', 'install')
                ($legs | Where-Object method -EQ binstall).archive_only | Should -BeTrue
                ($legs | Where-Object method -EQ install).archive_only | Should -BeFalse
            }
        }
        finally {
            Pop-Location
            $env:GITHUB_OUTPUT = $originalOutput
        }
        $script:PublishedJobs | Should -Not -Match 'actions/cache|install-method: path'
        $script:PublishedJobs | Should -Match '\[guid\]::NewGuid'
        $script:PublishedJobs | Should -Match 'ref: \$\{\{ github.sha \}\}'
    }
}

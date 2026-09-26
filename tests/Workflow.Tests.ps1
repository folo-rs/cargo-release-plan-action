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
        $workflow | Should -Match ([regex]::Escape('contains(fromJSON(''["push","schedule","workflow_dispatch"]''), github.event_name) && github.sha'))
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

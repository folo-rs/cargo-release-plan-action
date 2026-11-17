#Requires -Version 7.6
BeforeDiscovery {
    Import-Module "$PSScriptRoot/../.github/scripts/WorkflowGate.psm1" -Force
}

Describe 'Authenticated workflow result gates' {
    InModuleScope WorkflowGate {
        BeforeAll {
            function Set-GateFixture {
                param([string] $Profile = 'validation', [string] $Prefix = '')

                $script:Arguments.Profile = $Profile
                $script:Run.path = switch ($Profile) {
                    validation { '.github/workflows/validate.yml' }
                    source { '.github/workflows/source-canary.yml' }
                    published { '.github/workflows/published-installation.yml' }
                }
                $names = switch ($Profile) {
                    validation {
                        'tests (ubuntu-latest)', 'tests (windows-latest)', 'tests (macos-latest)',
                        'identity / rerun-prerequisite', 'identity / source / resolve', 'identity / verify',
                        'workflows', 'version-readiness', 'Action validation'
                    }
                    source {
                        'install (ubuntu-latest)', 'install (ubuntu-24.04-arm)', 'install (windows-latest)',
                        'install (windows-11-arm)', 'install (macos-latest)', 'Source installation'
                    }
                    published {
                        'matrix', 'install (x86_64-unknown-linux-gnu)', 'binstall (x86_64-unknown-linux-gnu)',
                        'install (aarch64-unknown-linux-gnu)', 'binstall (aarch64-unknown-linux-gnu)',
                        'install (x86_64-pc-windows-msvc)', 'binstall (x86_64-pc-windows-msvc)',
                        'install (aarch64-pc-windows-msvc)', 'binstall (aarch64-pc-windows-msvc)',
                        'install (aarch64-apple-darwin)', 'binstall (aarch64-apple-darwin)', 'Published installation'
                    }
                }
                $script:Jobs = @(
                    $id = 100
                    foreach ($name in $names) {
                        @{
                            id = $id++
                            name = "$Prefix$name"
                            run_id = 42
                            run_attempt = 1
                            head_sha = 'a' * 40
                            status = 'completed'
                            conclusion = 'success'
                            steps = @(@{ name = 'Set up job'; conclusion = 'success' })
                            labels = @('ubuntu-latest')
                            runner_id = 123
                            runner_name = 'hosted-runner'
                            check_run_url = "https://api.github.com/repos/example/action/check-runs/$id"
                        }
                    }
                )
                $script:Mac = @($script:Jobs | Where-Object name -CMatch 'macos-latest|aarch64-apple-darwin')[0]
                $script:Check.name = $script:Mac.name
            }

            function Set-CapacityCancellation {
                $script:Mac.status = 'completed'
                $script:Mac.conclusion = 'cancelled'
                $script:Mac.steps = @()
                $script:Mac.labels = @('macos-latest')
                $script:Mac.runner_id = 0
                $script:Mac.runner_name = ''
            }
        }

        BeforeEach {
            $script:OriginalApiUrl = $env:GITHUB_API_URL
            $env:GITHUB_API_URL = 'https://api.github.com'
            $script:Run = @{
                id = 42
                repository = @{ full_name = 'example/action' }
                head_sha = 'a' * 40
                run_attempt = 1
                event = 'pull_request'
                check_suite_id = 99
            }
            $script:Arguments = @{
                Profile = 'validation'
                Repository = 'example/action'
                RunId = 42
                Attempt = 1
                Sha = 'b' * 40
                EventName = 'pull_request'
                EventData = @{ pull_request = @{ head = @{ sha = 'a' * 40 } } }
            }
            $script:Check = @{
                name = ''
                head_sha = 'a' * 40
                check_suite = @{ id = 99 }
                app = @{ slug = 'github-actions'; id = 15368 }
                status = 'completed'
                conclusion = 'cancelled'
                output = @{ annotations_count = 1 }
            }
            $script:Annotations = @(@{
                annotation_level = 'failure'
                message = 'The job was not acquired by Runner of type hosted even after multiple attempts'
            })
            Set-GateFixture
            Mock Invoke-GateApi {
                if ($Path -ceq 'repos/example/action/actions/runs/42') { return $script:Run }
                if ($Path -ceq 'repos/example/action/actions/runs/42/jobs?filter=all&per_page=100&page=1') { return @{ jobs = $script:Jobs } }
                if ($Path -cmatch '^repos/example/action/check-runs/[0-9]+/annotations\?per_page=100&page=1$') { return ,$script:Annotations }
                if ($Path -cmatch '^repos/example/action/check-runs/[0-9]+$') { return $script:Check }
                throw "Unexpected API request: $Path"
            }
        }

        AfterEach {
            $env:GITHUB_API_URL = $script:OriginalApiUrl
        }

        It 'accepts successful <Profile> jobs using the PR head rather than its synthetic merge SHA' -ForEach @(
            @{ Profile = 'validation' }, @{ Profile = 'source' }, @{ Profile = 'published' }
        ) {
            Set-GateFixture -Profile $Profile
            { Assert-WorkflowGate @script:Arguments } | Should -Not -Throw
            Should -Invoke Invoke-GateApi -Times 2 -ParameterFilter { $Path -ceq 'repos/example/action/actions/runs/42' }
            Should -Invoke Invoke-GateApi -Times 0 -ParameterFilter { $Path -cmatch '/check-runs/' }
        }

        It 'warns about a proven unstarted cancellation in <Profile> without calling the job successful' -ForEach @(
            @{ Profile = 'validation' }, @{ Profile = 'source' }, @{ Profile = 'published' }
        ) {
            Set-GateFixture -Profile $Profile
            Set-CapacityCancellation
            Assert-WorkflowGate @script:Arguments -WarningVariable warnings -WarningAction SilentlyContinue
            $warnings | Should -Match 'Ignoring confirmed hosted macOS runner capacity cancellation'
            $script:Mac.conclusion | Should -BeExactly cancelled
        }

        It 'accepts the real acquisition failure with accompanying capacity notices, but not notices alone' {
            Set-CapacityCancellation
            $notice = @{
                annotation_level = 'notice'
                message = 'Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.'
            }
            $script:Annotations += @($notice, $notice, $notice)
            $script:Check.output.annotations_count = 4
            { Assert-WorkflowGate @script:Arguments -WarningAction SilentlyContinue } | Should -Not -Throw
            $script:Annotations = @($notice)
            $script:Check.output.annotations_count = 1
            { Assert-WorkflowGate @script:Arguments } | Should -Throw '*not confirmed*'
        }

        It 'rejects incomplete or contradictory capacity evidence: <Invalid>' -ForEach @(
            @{ Invalid = 'executed-step' }, @{ Invalid = 'missing-steps' }, @{ Invalid = 'null-steps' },
            @{ Invalid = 'failed-job' }, @{ Invalid = 'skipped-job' }, @{ Invalid = 'unfinished-job' },
            @{ Invalid = 'wrong-label' }, @{ Invalid = 'allocated-runner' },
            @{ Invalid = 'no-annotation' }, @{ Invalid = 'unrelated-cancellation' }, @{ Invalid = 'annotation-substring' },
            @{ Invalid = 'unrelated-extra-annotation' }, @{ Invalid = 'annotation-count' },
            @{ Invalid = 'wrong-check-head' }, @{ Invalid = 'wrong-check-suite' }, @{ Invalid = 'wrong-check-app' },
            @{ Invalid = 'wrong-check-name' }, @{ Invalid = 'wrong-check-result' }, @{ Invalid = 'foreign-check-url' }
        ) {
            Set-CapacityCancellation
            switch ($Invalid) {
                executed-step { $script:Mac.steps = @(@{ conclusion = 'failure' }) }
                missing-steps { $script:Mac.Remove('steps') }
                null-steps { $script:Mac.steps = $null }
                failed-job { $script:Mac.conclusion = 'failure' }
                skipped-job { $script:Mac.conclusion = 'skipped' }
                unfinished-job { $script:Mac.status = 'in_progress' }
                wrong-label { $script:Mac.labels = @('macos-15') }
                allocated-runner { $script:Mac.runner_id = 123 }
                no-annotation { $script:Check.output.annotations_count = 0; $script:Annotations = @() }
                unrelated-cancellation { $script:Annotations[0].message = 'The operation was canceled.' }
                annotation-substring { $script:Annotations[0].message += ' Extra untrusted text.' }
                unrelated-extra-annotation {
                    $script:Annotations += @{ annotation_level = 'failure'; message = 'Tests failed.' }
                    $script:Check.output.annotations_count = 2
                }
                annotation-count { $script:Check.output.annotations_count = 2 }
                wrong-check-head { $script:Check.head_sha = 'c' * 40 }
                wrong-check-suite { $script:Check.check_suite.id = 100 }
                wrong-check-app { $script:Check.app.id = 1 }
                wrong-check-name { $script:Check.name = 'other job' }
                wrong-check-result { $script:Check.conclusion = 'failure' }
                foreign-check-url { $script:Mac.check_run_url = 'https://attacker.example/check-runs/1' }
            }
            { Assert-WorkflowGate @script:Arguments } | Should -Throw
        }

        It 'does not excuse other jobs, absent evidence or skipped dependencies: <Invalid>' -ForEach @(
            @{ Invalid = 'non-mac-failure' }, @{ Invalid = 'non-mac-cancellation' }, @{ Invalid = 'dependency-skip' },
            @{ Invalid = 'missing-job' }, @{ Invalid = 'unknown-job' }, @{ Invalid = 'duplicate-job' },
            @{ Invalid = 'wrong-run' }, @{ Invalid = 'wrong-job-head' }, @{ Invalid = 'future-attempt' },
            @{ Invalid = 'wrong-run-head' }, @{ Invalid = 'wrong-run-attempt' }, @{ Invalid = 'unknown-caller' }
        ) {
            Set-CapacityCancellation
            switch ($Invalid) {
                non-mac-failure { $script:Jobs[0].conclusion = 'failure' }
                non-mac-cancellation { $script:Jobs[0].conclusion = 'cancelled' }
                dependency-skip { $script:Jobs[3].conclusion = 'skipped' }
                missing-job { $script:Jobs = @($script:Jobs | Where-Object name -CNE 'tests (macos-latest)') }
                unknown-job { $copy = $script:Jobs[0].Clone(); $copy.name = 'new required job'; $script:Jobs += $copy }
                duplicate-job { $script:Jobs += $script:Mac.Clone() }
                wrong-run { $script:Mac.run_id = 43 }
                wrong-job-head { $script:Mac.head_sha = 'c' * 40 }
                future-attempt { $script:Mac.run_attempt = 2 }
                wrong-run-head { $script:Run.head_sha = 'c' * 40 }
                wrong-run-attempt { $script:Run.run_attempt = 2 }
                unknown-caller { $script:Run.path = '.github/workflows/unrecognized.yml' }
            }
            { Assert-WorkflowGate @script:Arguments -WarningAction SilentlyContinue } | Should -Throw
        }

        It 'preserves successful jobs from prior attempts but makes the newest execution authoritative' {
            $script:Run.run_attempt = 2
            $script:Arguments.Attempt = 2
            $script:Jobs[-1].run_attempt = 2
            $older = $script:Mac.Clone()
            $script:Jobs += $older
            $script:Mac.run_attempt = 2
            $script:Mac.conclusion = 'failure'
            { Assert-WorkflowGate @script:Arguments } | Should -Throw
            $older.conclusion = 'failure'
            $script:Mac.conclusion = 'success'
            { Assert-WorkflowGate @script:Arguments } | Should -Not -Throw
        }

        It 'rejects a stale earlier capacity cancellation when the newest job really failed' {
            Set-CapacityCancellation
            $script:Run.run_attempt = 2
            $script:Arguments.Attempt = 2
            $script:Jobs[-1].run_attempt = 2
            $newer = $script:Mac.Clone()
            $newer.run_attempt = 2
            $newer.conclusion = 'failure'
            $newer.steps = @(@{ conclusion = 'failure' })
            $script:Jobs += $newer
            { Assert-WorkflowGate @script:Arguments } | Should -Throw
        }

        It 'reconciles exact reusable caller prefixes for <Profile>' -ForEach @(
            @{ Profile = 'validation' }, @{ Profile = 'source' }, @{ Profile = 'published' }
        ) {
            Set-GateFixture -Profile $Profile -Prefix "$Profile / "
            $script:Run.path = '.github/workflows/validate-release.yml'
            { Assert-WorkflowGate @script:Arguments } | Should -Not -Throw
        }

        It 'keeps native publication and manual published-installation validation strict' -ForEach @(
            @{ Event = 'push'; Path = '.github/workflows/publish-action.yml'; Prefix = 'availability / ' },
            @{ Event = 'workflow_dispatch'; Path = '.github/workflows/published-installation.yml'; Prefix = '' }
        ) {
            Set-GateFixture -Profile published -Prefix $Prefix
            Set-CapacityCancellation
            $script:Run.path = $Path
            $script:Run.event = $Event
            $script:Arguments.EventName = $Event
            $script:Arguments.Sha = 'a' * 40
            { Assert-WorkflowGate @script:Arguments } | Should -Throw '*did not succeed*'
        }

        It 'keeps published package and archive acquisition failures blocking on a macOS capacity cancellation' {
            Set-GateFixture -Profile published
            Set-CapacityCancellation
            foreach ($name in @('install (x86_64-unknown-linux-gnu)', 'binstall (x86_64-unknown-linux-gnu)')) {
                $linux = @($script:Jobs | Where-Object name -CEQ $name)[0]
                $linux.conclusion = 'failure'
                { Assert-WorkflowGate @script:Arguments } | Should -Throw '*did not succeed*'
                $linux.conclusion = 'success'
            }
        }

        It 'fails closed on unreadable API evidence' {
            Mock Invoke-GateApi { throw 'Authentication failed.' }
            { Assert-WorkflowGate @script:Arguments } | Should -Throw '*Authentication failed*'
        }

        It 'checks run identity again after reconciliation' {
            $script:Reads = 0
            Mock Invoke-GateApi {
                $script:Reads++
                $copy = $script:Run.Clone()
                if ($script:Reads -gt 1) { $copy.run_attempt = 2 }
                return $copy
            } -ParameterFilter { $Path -ceq 'repos/example/action/actions/runs/42' }
            { Assert-WorkflowGate @script:Arguments } | Should -Throw '*changed during*'
        }

        It 'paginates without losing the all-attempts query' {
            Mock Invoke-GateApi {
                if ($Path -ceq 'jobs?filter=all&per_page=100&page=1') { return @{ jobs = @(1..100) } }
                if ($Path -ceq 'jobs?filter=all&per_page=100&page=2') { return @{ jobs = @(101) } }
                throw "Unexpected pagination: $Path"
            }
            @(Get-GatePages 'jobs?filter=all' 'jobs').Count | Should -Be 101
        }
    }
}

#Requires -Version 7.6
# Release policy and retry ordering use in-process ports; native boundaries live
# in Release.Integration.Tests.ps1.
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Release.psm1') -Force
}

Describe 'Release-bearing paths' {
    It 'requires increments for runtime and consumer workflows' -ForEach @(
        'action.yml', 'release.json', 'scripts/Bootstrap.psm1', 'scripts/Invoke-ReleasePlan.ps1',
        'scripts/New-Runtime.ps1', '.github/workflows/release.yml', '.github/workflows/_release.yml',
        '.github/workflows/check.yml', '.github/workflows/identity-probe.yml',
        '.github/workflows/action-source.yml', '.github/workflows/identity.yml',
        '.github/actions/restore-controller/action.yml', '.github/actions/install-checker/action.yml'
    ) {
        Test-ReleaseBearingPath $_ | Should -BeTrue
    }

    It 'permits unchanged versions for documentation, tests and owned CI' -ForEach @(
        'README.md', 'docs/design.md', 'tests/Release.Tests.ps1',
        '.github/workflows/validate.yml', '.github/workflows/validate-release.yml',
        '.github/workflows/published-installation.yml', '.github/workflows/source-canary.yml',
        '.github/workflows/scheduling-canary.yml', '.github/workflows/_scheduling-unit.yml',
        '.github/workflows/publish-action.yml', 'scripts/Release.psm1', 'scripts/Publish-Release.ps1'
    ) {
        Test-ReleaseBearingPath $_ | Should -BeFalse
    }
}

Describe 'Stable action versions and baselines' {
    It 'orders numeric components rather than lexical tag names' {
        (ConvertTo-ReleaseVersion '0.10.0') | Should -BeGreaterThan (ConvertTo-ReleaseVersion '0.9.0')
    }

    It 'uses main rather than a pending feature or stacked PR increment' -ForEach @(
        @{ EventName = 'push'; Ref = 'refs/heads/feature' }
        @{ EventName = 'pull_request'; Ref = 'refs/pull/1/merge' }
        @{ EventName = 'workflow_dispatch'; Ref = 'refs/heads/feature' }
    ) {
        Get-ValidationReleaseBase -EventName $EventName -Ref $Ref `
            -EventData @{ before = ('a' * 40); pull_request = @{ base = @{ sha = ('b' * 40) } } } |
            Should -Be 'refs/remotes/origin/main'
    }

    It 'retains the previous main tip' {
        Get-ValidationReleaseBase -EventName push -Ref refs/heads/main `
            -EventData @{ before = ('a' * 40) } | Should -Be ('a' * 40)
    }

    It 'retains an explicitly supplied merge-group comparison base' {
        Get-ValidationReleaseBase -EventName merge_group -Ref refs/heads/gh-readonly-queue/main `
            -EventData @{ merge_group = @{ base_sha = ('b' * 40) } } | Should -Be ('b' * 40)
    }

    It 'permits only genuine first-push absence' {
        Get-ValidationReleaseBase -EventName push -Ref refs/heads/main `
            -EventData @{ before = ('0' * 40) } | Should -BeNullOrEmpty
        { Get-ValidationReleaseBase -EventName push -Ref refs/heads/main -EventData @{} } | Should -Throw
        { Get-ValidationReleaseBase -EventName merge_group -Ref refs/heads/queue `
                -EventData @{ merge_group = @{ base_sha = ('0' * 40) } } } | Should -Throw
        { Get-ValidationReleaseBase -EventName schedule -Ref refs/heads/main -EventData @{} } | Should -Throw
    }

    It 'rejects ambiguous or prerelease versions' -ForEach @('v1.0.0', '01.0.0', '1.0', '1.0.0-rc.1') {
        { ConvertTo-ReleaseVersion $_ } | Should -Throw
    }
}

Describe 'Action release reconciliation' {
    InModuleScope Release {
        BeforeEach {
            $script:version = '0.1.0'
            $script:baseVersion = '0.0.9'
            $script:tagTarget = $null
            $script:majorTarget = $null
            $script:majorVersion = '0.0.9'
            $script:tagContent = 'runtime'
            $script:releaseExists = $false
            $script:operations = [System.Collections.Generic.List[string]]::new()
            Mock Get-ReleaseManifestAtRef {
                param($Ref)
                $v = switch ($Ref) {
                    'base' { $script:baseVersion }
                    'major-commit' { $script:majorVersion }
                    default { $script:version }
                }
                [pscustomobject] @{ schema_version = 1; action_version = $v }
            }
            Mock Get-ReleaseContent {
                param($Ref)
                if ($Ref -eq 'base') { return 'baseline' }
                if ($Ref -eq 'original') { return $script:tagContent }
                return 'runtime'
            }
            Mock Invoke-ReleaseGit {
                param($Arguments)
                if ($Arguments[0] -eq 'rev-parse') {
                    switch ($Arguments[-1]) {
                        'HEAD^{commit}' { return 'candidate' }
                        'refs/tags/v0^{commit}' { return $script:majorTarget }
                        'refs/tags/v0' { return $script:majorTarget }
                        default { return $script:tagTarget }
                    }
                }
                if ($Arguments[0] -eq 'push') { $script:operations.Add("git $($Arguments -join ' ')") }
            }
            Mock Invoke-ReleaseGh {
                param($Arguments)
                if ($Arguments[0] -eq 'api') {
                    if ($script:releaseExists) {
                        return '[[{"tag_name":"v0.1.0","draft":false,"prerelease":false}]]'
                    }
                    return '[[]]'
                }
                $script:operations.Add("gh $($Arguments -join ' ')")
            }
        }

        It 'publishes full tag then generated release then major using default Latest behavior' {
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 3
            $script:operations[0] | Should -Be 'git push origin candidate:refs/tags/v0.1.0'
            $script:operations[1] | Should -Match '^gh release create v0\.1\.0 '
            $script:operations[1] | Should -Match '--verify-tag'
            $script:operations[1] | Should -Match '--generate-notes'
            $script:operations[1] | Should -Match '--notes \[Copilot speaking\]'
            $script:operations[1] | Should -Not -Match '--latest'
            $script:operations[2] | Should -Be 'git push --force-with-lease=refs/tags/v0: origin candidate:refs/tags/v0'
            Should -Invoke Invoke-ReleaseGit -Times 1 -ParameterFilter {
                $Arguments[0] -eq 'fetch' -and $Arguments -contains '+refs/tags/*:refs/tags/*'
            }
        }

        It 'preserves original identity for equivalent CI-only content' {
            $script:tagTarget = 'original'
            $script:majorTarget = 'original'
            Mock Get-ReleaseManifestAtRef { [pscustomobject] @{ schema_version = 1; action_version = '0.1.0' } }
            $script:releaseExists = $true
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 0
        }

        It 'retries after tag creation without moving it' {
            $script:tagTarget = 'original'
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 2
            $script:operations[0] | Should -Match '^gh release create '
            $script:operations[1] | Should -Match 'original:refs/tags/v0$'
        }

        It 'retries after release creation by reconciling only major' {
            $script:tagTarget = 'original'
            $script:releaseExists = $true
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 1
            $script:operations[0] | Should -Match 'original:refs/tags/v0$'
        }

        It 'finds an existing release on a later page' {
            $script:tagTarget = 'original'
            Mock Invoke-ReleaseGh {
                '[[{"tag_name":"v0.0.8","draft":false,"prerelease":false}],[{"tag_name":"v0.0.9","draft":false,"prerelease":false},{"tag_name":"v0.1.0","draft":false,"prerelease":false}]]'
            } -ParameterFilter { $Arguments[0] -eq 'api' }
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 1
            Should -Invoke Invoke-ReleaseGh -Times 0 -ParameterFilter { $Arguments[0] -eq 'release' }
        }

        It 'does not roll a newer major release backwards' {
            $script:majorTarget = 'major-commit'
            $script:majorVersion = '0.10.0'
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 2
            $script:operations | Should -Not -Match '--force'
        }

        It 'uses a lease to advance an existing major' {
            $script:majorTarget = 'major-commit'
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations[-1] | Should -Match '--force-with-lease=refs/tags/v0:major-commit'
        }

        It 'rejects changed runtime at an existing immutable version before writing' {
            $script:tagTarget = 'original'
            $script:tagContent = 'different'
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }

        It 'requires an increment from main even before its tag is published' {
            $script:baseVersion = '0.1.0'
            { Assert-ReleaseReadiness -RepositoryPath repo -BaseRef base } | Should -Throw
        }

        It 'does not mutate refs when release lookup fails' {
            Mock Invoke-ReleaseGh { throw 'API unavailable' }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }

        It 'rejects an existing release whose full-version tag is missing' {
            $script:releaseExists = $true
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw '*release but no tag*'
            $script:operations.Count | Should -Be 0
        }

        It 'does not move major after release creation fails' {
            Mock Invoke-ReleaseGh { throw 'creation failed' } -ParameterFilter { $Arguments[0] -eq 'release' }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 1
            $script:operations[0] | Should -Be 'git push origin candidate:refs/tags/v0.1.0'
        }

        It 'does not create a release after immutable tag push fails' {
            Mock Invoke-ReleaseGit { throw 'push rejected' } -ParameterFilter { $Arguments[0] -eq 'push' }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            Should -Invoke Invoke-ReleaseGh -Times 0 -ParameterFilter { $Arguments[0] -eq 'release' }
        }

        It 'rejects a major ref disagreeing with the same immutable version' {
            $script:majorTarget = 'major-commit'
            $script:majorVersion = '0.1.0'
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }

        It 'rejects unexpected draft or prerelease objects' -ForEach @('draft', 'prerelease') {
            $script:unexpectedRelease = @{ tag_name = 'v0.1.0'; draft = $_ -eq 'draft'; prerelease = $_ -eq 'prerelease' }
            Mock Invoke-ReleaseGh { ConvertTo-Json -InputObject @(@($script:unexpectedRelease)) -Depth 4 }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }
    }
}

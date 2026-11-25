#Requires -Version 7.6
# Same-run artifact preflight tests never contact GitHub or wait in real time.

Import-Module (Join-Path $PSScriptRoot '..\scripts\ArtifactPreflight.psm1') -Force

class ArtifactPreflightHttpException : System.Exception {
    [object] $Response

    ArtifactPreflightHttpException([int] $StatusCode) : base("HTTP $StatusCode") {
        $this.Response = [pscustomobject]@{ StatusCode = $StatusCode }
    }
}

InModuleScope ArtifactPreflight {
    Describe 'Same-run artifact preflight' {
        BeforeEach {
            $script:artifact = [pscustomobject]@{
                id = 41
                name = 'crp-scope-7-1-registry-outcome'
                expired = $false
                created_at = '2026-01-01T00:01:30Z'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:secondArtifact = [pscustomobject]@{
                id = 42
                name = 'crp-scope-7-1-github-outcome'
                expired = $false
                created_at = '2026-01-01T00:02:30Z'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:selectionCalls = 0
            Mock Start-Sleep {}
        }

        It 'waits for exact IDs through the authenticated run inventory' {
            Mock Select-GitHubArtifacts {
                $script:selectionCalls++
                if ($script:selectionCalls -eq 1) { return @() }
                return @($script:artifact)
            }

            $ids = @(Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -ArtifactIds '41' `
                -MaximumAttempts 2 -RetryDelaySeconds 0)

            $ids | Should -Be @(41)
            Should -Invoke Select-GitHubArtifacts -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'requires every exact ID before completing preflight' {
            Mock Get-GitHubRunArtifacts { @($script:artifact) }

            @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41,42') |
                Should -HaveCount 0
        }

        It 'selects the latest exact name and one artifact per distinct pattern name' {
            $duplicate = [pscustomobject]@{
                id = 43
                name = $script:artifact.name
                expired = $false
                created_at = '2026-01-01T00:03:30Z'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            Mock Get-GitHubRunArtifacts {
                @($script:artifact, $script:secondArtifact, $duplicate)
            }

            @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Name $script:artifact.name).id |
                Should -Be @(43)
            @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Pattern 'crp-scope-7-*-outcome').id |
                Should -Be @(42, 43)
        }

        It 'retains pattern names that differ only by case as distinct artifacts' {
            $caseArtifact = [pscustomobject]@{
                id = 43
                name = 'CRP-SCOPE-7-1-REGISTRY-OUTCOME'
                expired = $false
                created_at = '2026-01-01T00:03:30Z'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            Mock Get-GitHubRunArtifacts { @($script:artifact, $caseArtifact) }

            @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Pattern '*') |
                Should -HaveCount 2
        }

        It 'returns an empty inventory for a metadata 404' {
            Mock Invoke-RestMethod { throw [ArtifactPreflightHttpException]::new(404) }

            @(Get-GitHubRunArtifacts -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -Headers @{}) |
                Should -HaveCount 0
        }

        It 'paginates and preserves an empty run inventory' {
            Mock Invoke-RestMethod {
                if ($Uri -like '*page=1') {
                    return [pscustomobject]@{
                        total_count = 2
                        artifacts = @([pscustomobject]@{ id = 40; name = 'other' })
                    }
                }
                return [pscustomobject]@{
                    total_count = 2
                    artifacts = @($script:artifact)
                }
            }

            @(Get-GitHubRunArtifacts -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -Headers @{}) |
                Should -HaveCount 2
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly

            Mock Invoke-RestMethod {
                [pscustomobject]@{ total_count = 0; artifacts = @() }
            }
            @(Get-GitHubRunArtifacts -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -Headers @{}) |
                Should -HaveCount 0
        }

        It 'retries recognized transient metadata status <StatusCode>' -ForEach @(
            @{ StatusCode = 404 }
            @{ StatusCode = 408 }
            @{ StatusCode = 429 }
            @{ StatusCode = 500 }
            @{ StatusCode = 502 }
            @{ StatusCode = 503 }
            @{ StatusCode = 504 }
        ) {
            Mock Select-GitHubArtifacts {
                $script:selectionCalls++
                if ($script:selectionCalls -eq 1) {
                    throw [ArtifactPreflightHttpException]::new($StatusCode)
                }
                return @($script:artifact)
            }

            Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -ArtifactIds '41' `
                -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'propagates permanent metadata status <StatusCode>' -ForEach @(
            @{ StatusCode = 401 }
            @{ StatusCode = 403 }
            @{ StatusCode = 410 }
        ) {
            Mock Select-GitHubArtifacts {
                throw [ArtifactPreflightHttpException]::new($StatusCode)
            }

            {
                Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0
            } | Should -Throw "*HTTP $StatusCode*"
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'propagates statusless transport failures' {
            Mock Select-GitHubArtifacts {
                throw [System.IO.IOException]::new('transport failed')
            }

            {
                Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0
            } | Should -Throw '*transport failed*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'counts genuine scoped reruns but not reused successful job copies' {
            Mock Get-GitHubRunJobs {
                @(
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 1
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome for scope'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 2
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome for scope'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 2
                        started_at = '2026-01-01T00:02:10Z'
                        completed_at = '2026-01-01T00:03:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome for scope'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 2
                        started_at = '2026-01-01T00:02:10Z'
                        completed_at = '2026-01-01T00:03:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome for other-scope'
                                conclusion = 'success'
                            })
                    }
                )
            }

            @(Get-ExpectedArtifactProducers -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 `
                    -ProducerSteps 'Upload registry outcome for scope' -Headers @{}) |
                Should -HaveCount 2
        }

        It 'requires one distinct fresh artifact for every producer execution' {
            $oldArtifact = [pscustomobject]@{
                id = 40
                name = 'crp-scope-7-1-registry-outcome'
                expired = $false
                created_at = '2026-01-01T00:00:30Z'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $newArtifact = [pscustomobject]@{
                id = 44
                name = 'crp-scope-7-2-registry-outcome'
                expired = $false
                created_at = '2026-01-01T00:02:30Z'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:producers = @(
                [pscustomobject]@{
                    Marker = 'registry'
                    Step = 'Upload registry outcome for scope'
                    StartedAt = [DateTimeOffset]::Parse('2026-01-01T00:00:10Z')
                }
                [pscustomobject]@{
                    Marker = 'registry'
                    Step = 'Upload registry outcome for scope'
                    StartedAt = [DateTimeOffset]::Parse('2026-01-01T00:02:10Z')
                }
            )

            Test-ArtifactFreshness -Artifacts @($oldArtifact) -Producers $producers |
                Should -BeFalse
            Test-ArtifactFreshness -Artifacts @($oldArtifact, $newArtifact) -Producers $producers |
                Should -BeTrue
        }

        It 'waits for a delayed pattern artifact from a genuine rerun' {
            $oldArtifact = $script:artifact
            $oldArtifact.created_at = '2026-01-01T00:01:30Z'
            $newArtifact = $script:secondArtifact
            $newArtifact.created_at = '2026-01-01T00:03:30Z'
            $producers = @(
                [pscustomobject]@{
                    Marker = 'registry'
                    Step = 'Upload registry outcome for scope'
                    StartedAt = [DateTimeOffset]::Parse('2026-01-01T00:01:00Z')
                }
                [pscustomobject]@{
                    Marker = 'github'
                    Step = 'Upload GitHub outcome for scope'
                    StartedAt = [DateTimeOffset]::Parse('2026-01-01T00:03:00Z')
                }
            )
            Mock Get-ExpectedArtifactProducers { $script:producers }
            Mock Select-GitHubArtifacts {
                $script:selectionCalls++
                if ($script:selectionCalls -eq 1) { return @($oldArtifact) }
                return @($oldArtifact, $newArtifact)
            }

            Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Pattern 'crp-scope-7-*-outcome' `
                -ProducerSteps 'Upload registry outcome for scope', 'Upload GitHub outcome for scope' `
                -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'allows an optional empty pattern and rejects an empty required pattern' {
            Mock Get-ExpectedArtifactProducers { @() }
            Mock Select-GitHubArtifacts { @() }

            {
                Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Pattern 'crp-scope-7-*-outcome' `
                    -ProducerSteps 'Upload registry outcome for scope' -AllowEmpty
            } | Should -Not -Throw

            {
                Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Pattern 'crp-scope-7-*-outcome' `
                    -ProducerSteps 'Upload registry outcome for scope' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0
            } | Should -Throw '*still unavailable*2 attempts*'
        }

        It 'rejects artifacts owned by another run and expired artifacts' -ForEach @(
            @{ Mode = 'run' }
            @{ Mode = 'expired' }
        ) {
            $artifact = $script:artifact
            if ($Mode -ceq 'run') { $artifact.workflow_run.id = 8 }
            else { $artifact.expired = $true }
            Mock Get-GitHubRunArtifacts { @($artifact) }

            {
                Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41'
            } | Should -Throw
        }

        It 'bounds metadata requests to thirty seconds' {
            Mock Invoke-RestMethod {
                [pscustomobject]@{ total_count = 0; artifacts = @() }
            }

            Get-GitHubRunArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -Headers @{}

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $TimeoutSec -eq 30
            }
        }

        It 'uses the agreed twelve-attempt, five-second default budget' {
            Mock Select-GitHubArtifacts { @() }

            {
                Invoke-ArtifactPreflight -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41'
            } | Should -Throw '*12 attempts*'

            Should -Invoke Select-GitHubArtifacts -Times 12 -Exactly
            Should -Invoke Start-Sleep -Times 11 -Exactly -ParameterFilter {
                $Seconds -eq 5
            }
        }

        It 'checks every archive with the workflow token and retries only the delayed redirect' {
            Mock Get-ArtifactArchiveStatus {
                if ($Uri -like '*/42/zip' -and $script:selectionCalls++ -eq 0) { return 404 }
                return 302
            }

            Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' -Repository owner/repo `
                -GitHubToken 'job-token' -ArtifactIds 41,42 | Should -BeTrue

            Should -Invoke Get-ArtifactArchiveStatus -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.github.test/repos/owner/repo/actions/artifacts/41/zip' -and
                    $Headers.Authorization -ceq 'Bearer job-token'
            }
            Should -Invoke Get-ArtifactArchiveStatus -Times 2 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.github.test/repos/owner/repo/actions/artifacts/42/zip' -and
                    $Headers.Authorization -ceq 'Bearer job-token'
            }
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'chooses a final same-run transfer after persistent REST 404 for one immutable ID' {
            Mock Get-ArtifactArchiveStatus { 404 }

            Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' -Repository owner/repo `
                -GitHubToken 'job-token' -ArtifactIds 41 | Should -BeFalse
            Should -Invoke Get-ArtifactArchiveStatus -Times 12 -Exactly
            Should -Invoke Start-Sleep -Times 11 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'does not use a narrower artifact inventory for an incomplete multi-ID transfer' {
            Mock Get-ArtifactArchiveStatus { 404 }
            {
                Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' -Repository owner/repo `
                    -GitHubToken 'job-token' -ArtifactIds 41,42
            } | Should -Throw '*artifact 41*HTTP 404*attempt 12/12*'
        }

        It 'reports permanent archive status <Status> without waiting' -ForEach @(
            @{ Status = 401 }
            @{ Status = 403 }
            @{ Status = 410 }
        ) {
            Mock Get-ArtifactArchiveStatus { $status }
            {
                Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' -Repository owner/repo `
                    -GitHubToken 'job-token' -ArtifactIds 41
            } | Should -Throw "*HTTP $status*attempt 1/*"
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }
}

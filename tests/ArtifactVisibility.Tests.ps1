#Requires -Version 7.6
# Same-run download tests never contact GitHub or wait in real time.

Import-Module (Join-Path $PSScriptRoot '..\scripts\ArtifactDownload.psm1') -Force

class ArtifactDownloadHttpException : System.Exception {
    [object] $Response

    ArtifactDownloadHttpException([int] $StatusCode) : base("HTTP $StatusCode") {
        $this.Response = [pscustomobject]@{ StatusCode = $StatusCode }
    }
}

InModuleScope ArtifactDownload {
    Describe 'Same-run artifact downloads' {
        BeforeAll {
            $script:saveArchiveImplementation = ${function:Save-GitHubArtifactArchive}
        }

        BeforeEach {
            $script:artifact = [pscustomobject]@{
                id = 41
                name = 'crp-scope-7-1-registry-outcome'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/41/zip'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:secondArtifact = [pscustomobject]@{
                id = 42
                name = 'crp-scope-7-1-github-outcome'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/42/zip'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:selectionCalls = 0
            $script:archiveCalls = 0
            $script:originalRunnerTemp = $env:RUNNER_TEMP
            $env:RUNNER_TEMP = $TestDrive
            Mock Start-Sleep {}
            Mock Expand-Archive {}
            Mock Save-GitHubArtifactArchive {
                $script:archiveCalls++
                return $true
            }
        }

        AfterEach {
            $env:RUNNER_TEMP = $script:originalRunnerTemp
        }

        It 'retries an exact ID metadata 404 and then downloads the archive' {
            $script:inventoryCalls = 0
            Mock Invoke-RestMethod {
                $script:inventoryCalls++
                if ($script:inventoryCalls -eq 1) {
                    throw [ArtifactDownloadHttpException]::new(404)
                }
                return $script:artifact
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'metadata-retry') `
                -ArtifactIds '41' -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 1 -Exactly
            Should -Invoke Expand-Archive -Times 1 -Exactly
        }

        It 'returns an empty run inventory for a transient metadata 404' {
            Mock Invoke-RestMethod { throw [ArtifactDownloadHttpException]::new(404) }

            @(Get-GitHubRunArtifacts -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -Headers @{}) |
                Should -HaveCount 0
        }

        It 'preserves an empty artifact array from an empty run inventory' {
            Mock Invoke-RestMethod {
                return [pscustomobject]@{
                    total_count = 0
                    artifacts = @()
                }
            }

            @(Get-GitHubRunArtifacts -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -Headers @{}) |
                Should -HaveCount 0
        }

        It 'paginates the run inventory to a later artifact page' {
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
        }

        It 'retries an archive 404 only after metadata selection succeeds' {
            Mock Select-GitHubArtifacts { @($script:artifact) }
            Mock Save-GitHubArtifactArchive {
                $script:archiveCalls++
                return $script:archiveCalls -gt 1
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'archive-retry') `
                -ArtifactIds '41' -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Save-GitHubArtifactArchive -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Expand-Archive -Times 1 -Exactly
        }

        It 'does not extract until every selected archive is downloadable' {
            Mock Select-GitHubArtifacts { @($script:artifact, $script:secondArtifact) }
            Mock Get-ExpectedArtifactCount { 2 }
            Mock Save-GitHubArtifactArchive {
                if ((Get-ArtifactResponseProperty -Response $Artifact -Name 'id') -eq 42) {
                    return $false
                }
                return $true
            }

            {
                Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'staged') `
                    -Pattern 'crp-scope-7-*-outcome' `
                    -ProducerSteps 'Upload registry outcome', 'Upload GitHub outcome' `
                    -MaximumAttempts 1 -RetryDelaySeconds 0
            } | Should -Throw '*still unavailable*'

            Should -Invoke Expand-Archive -Times 0 -Exactly
        }

        It 'waits for a changing producer count to become complete' {
            Mock Get-ExpectedArtifactCount { 2 }
            Mock Select-GitHubArtifacts {
                $script:selectionCalls++
                if ($script:selectionCalls -eq 1) { return @($script:artifact) }
                return @($script:artifact, $script:secondArtifact)
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'pattern-complete') `
                -Pattern 'crp-scope-7-*-outcome' `
                -ProducerSteps 'Upload registry outcome', 'Upload GitHub outcome' `
                -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 2 -Exactly
            Should -Invoke Expand-Archive -Times 2 -Exactly
        }

        It 'does not count duplicate artifact names as distinct producers' {
            $duplicate = [pscustomobject]@{
                id = 43
                name = $script:artifact.name
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/43/zip'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            Mock Get-GitHubRunArtifacts { @($script:artifact, $duplicate) }

            @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Pattern 'crp-scope-7-*-outcome') |
                Should -HaveCount 1
        }

        It 'retains artifact names that differ only by case as distinct producers' {
            $caseArtifact = [pscustomobject]@{
                id = 43
                name = 'CRP-SCOPE-7-1-REGISTRY-OUTCOME'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/43/zip'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            Mock Get-GitHubRunArtifacts { @($script:artifact, $caseArtifact) }

            @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Pattern '*') |
                Should -HaveCount 2
        }

        It 'counts genuine reruns but not reused successful job copies' {
            Mock Get-GitHubRunJobs {
                @(
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 1
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 2
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'execute / registry'
                        run_attempt = 2
                        started_at = '2026-01-01T00:02:10Z'
                        completed_at = '2026-01-01T00:03:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload registry outcome'
                                conclusion = 'success'
                            })
                    }
                )
            }

            Get-ExpectedArtifactCount -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -ProducerSteps 'Upload registry outcome' -Headers @{} |
                Should -Be 2
        }

        It 'allows an optional empty pattern after successful producer filtering' {
            Mock Get-ExpectedArtifactCount { 0 }
            Mock Select-GitHubArtifacts { throw 'Empty pattern must not be selected.' }

            {
                Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'empty-pattern') `
                    -Pattern 'crp-scope-7-*-outcome' -ProducerSteps 'Upload registry outcome' `
                    -AllowEmpty -MaximumAttempts 1 -RetryDelaySeconds 0
            } | Should -Not -Throw
        }

        It 'fails after a complete producer set never stabilizes' {
            Mock Get-ExpectedArtifactCount { 2 }
            Mock Select-GitHubArtifacts { @($script:artifact) }

            {
                Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'unstable-pattern') `
                    -Pattern 'crp-scope-7-*-outcome' -ProducerSteps 'Upload registry outcome' `
                    -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw '*after 3 attempts*'

            Should -Invoke Select-GitHubArtifacts -Times 3 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 0 -Exactly
        }

        It 'rejects artifacts from another run and expired artifacts' -ForEach @(
            @{ Mode = 'run' }
            @{ Mode = 'expired' }
        ) {
            $artifact = $script:artifact
            if ($Mode -ceq 'run') {
                $artifact.workflow_run.id = 8
            }
            else {
                $artifact.expired = $true
            }
            Mock Get-GitHubArtifact { $artifact }

            { Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41' } |
                Should -Throw
        }

        It 'returns false for archive 404 and propagates other HTTP failures' {
            Mock Invoke-WebRequest { throw [ArtifactDownloadHttpException]::new(404) }
            & $script:saveArchiveImplementation -Artifact $script:artifact `
                -Path (Join-Path $TestDrive 'archive.zip') -GitHubToken 'token' |
                Should -BeFalse

            foreach ($status in @(401, 403, 410)) {
                Mock Invoke-WebRequest { throw [ArtifactDownloadHttpException]::new($script:status) }
                $script:status = $status
                { & $script:saveArchiveImplementation -Artifact $script:artifact `
                        -Path (Join-Path $TestDrive "archive-$status.zip") -GitHubToken 'token' } |
                    Should -Throw "*HTTP $status*"
            }
        }

        It 'propagates metadata HTTP 401, 403 and 410 plus statusless failures' {
            foreach ($status in @(401, 403, 410)) {
                Mock Invoke-RestMethod { throw [ArtifactDownloadHttpException]::new($script:status) }
                $script:status = $status
                { Get-GitHubArtifact -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                        -ArtifactId 41 -Headers @{} } |
                    Should -Throw "*HTTP $status*"
            }

            Mock Invoke-RestMethod { throw [System.IO.IOException]::new('transport failed') }
            { Get-GitHubArtifact -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -ArtifactId 41 -Headers @{} } |
                Should -Throw '*transport failed*'
        }

        It 'propagates a statusless archive transport failure' {
            Mock Invoke-WebRequest { throw [System.IO.IOException]::new('archive transport failed') }

            { & $script:saveArchiveImplementation -Artifact $script:artifact `
                    -Path (Join-Path $TestDrive 'transport.zip') -GitHubToken 'token' } |
                Should -Throw '*archive transport failed*'
        }

        It 'bounds metadata and archive requests' {
            Mock Invoke-RestMethod { $script:artifact }
            Get-GitHubArtifact -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -ArtifactId 41 -Headers @{}
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $TimeoutSec -eq $script:MetadataTimeoutSeconds
            }

            Mock Invoke-WebRequest {}
            & $script:saveArchiveImplementation -Artifact $script:artifact `
                -Path (Join-Path $TestDrive 'timeout.zip') -GitHubToken 'token'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $TimeoutSec -eq $script:ArchiveTimeoutSeconds
            }
        }
    }
}

#Requires -Version 7.6

BeforeAll {
    $script:WaitArtifact = Join-Path $PSScriptRoot '..\scripts\Wait-Artifact.ps1'
    $script:OriginalApiUrl = $env:GITHUB_API_URL
    $script:OriginalToken = $env:GH_TOKEN
}

AfterAll {
    $env:GITHUB_API_URL = $script:OriginalApiUrl
    $env:GH_TOKEN = $script:OriginalToken
    Remove-Variable ArtifactQueryCount -Scope Global -ErrorAction Ignore
}

Describe 'Artifact visibility retries' {
    BeforeEach {
        $env:GITHUB_API_URL = 'https://api.github.test'
        $env:GH_TOKEN = 'test-only-token'
        $global:ArtifactQueryCount = 0
        Mock Start-Sleep
    }

    It 'waits until an exact artifact ID is visible and then stops' {
        Mock Invoke-RestMethod {
            $global:ArtifactQueryCount++
            @{
                total_count = 1
                artifacts = @(@{
                    id = if ($global:ArtifactQueryCount -eq 1) { '99' } else { '123' }
                })
            }
        }

        & $script:WaitArtifact `
            -Repository owner/repository `
            -RunId 456 `
            -ArtifactId 123 `
            -AttemptLimit 2 `
            -DelaySeconds 1

        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.test/repos/owner/repository/actions/runs/456/artifacts?per_page=100&page=1' -and
            $Headers.Authorization -eq 'Bearer test-only-token'
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }

    It 'searches every run-artifact page for an exact ID' {
        Mock Invoke-RestMethod {
            if ([string] $Uri -like '*page=1') {
                @{
                    total_count = 2
                    artifacts = @(@{ id = '99' })
                }
            }
            else {
                @{
                    total_count = 2
                    artifacts = @(@{ id = '123' })
                }
            }
        }

        & $script:WaitArtifact `
            -Repository owner/repository `
            -RunId 456 `
            -ArtifactId 123 `
            -DelaySeconds 1

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*/artifacts?per_page=100&page=2'
        }
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'preserves final failure when an exact artifact ID remains unavailable' {
        Mock Invoke-RestMethod {
            $global:ArtifactQueryCount++
            @{
                total_count = 1
                artifacts = @(@{ id = '99' })
            }
        }

        {
            & $script:WaitArtifact `
                -Repository owner/repository `
                -RunId 456 `
                -ArtifactId 123 `
                -AttemptLimit 2 `
                -DelaySeconds 1
        } | Should -Throw '*retry budget*'

        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'finds exact names and wildcard patterns in the current workflow run' -ForEach @(
        @{ Selector = 'Name'; Value = 'controller-transfer'; Queries = 1; Sleeps = 0 }
        @{ Selector = 'Pattern'; Value = '*-controller'; Queries = 2; Sleeps = 1 }
    ) {
        Mock Invoke-RestMethod {
            $global:ArtifactQueryCount++
            @{
                total_count = 2
                artifacts = @(
                    @{ name = 'unrelated' }
                    @{ name = 'release-controller' }
                    @{ name = 'controller-transfer' }
                )
            }
        }

        if ($Selector -ceq 'Name') {
            & $script:WaitArtifact -Repository owner/repository -RunId 456 -Name $Value
        }
        else {
            & $script:WaitArtifact -Repository owner/repository -RunId 456 -Pattern $Value
        }

        Should -Invoke Invoke-RestMethod -Times $Queries -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.test/repos/owner/repository/actions/runs/456/artifacts?per_page=100&page=1'
        }
        Should -Invoke Start-Sleep -Times $Sleeps -Exactly
    }

    It 'does not retry unrelated GitHub API failures' {
        Mock Invoke-RestMethod { throw 'Forbidden' }

        {
            & $script:WaitArtifact `
                -Repository owner/repository `
                -RunId 456 `
                -ArtifactId 123 `
                -AttemptLimit 2 `
                -DelaySeconds 1
        } | Should -Throw '*Forbidden*'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

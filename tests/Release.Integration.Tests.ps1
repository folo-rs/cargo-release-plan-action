#Requires -Version 7.6
# Local repositories and a bare origin exercise real Git reads, pushes and leases.
# Only the GitHub API port is mocked; no production repository is contacted.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Release.psm1') -Force
    function Invoke-FixtureGit {
        param([string[]] $Arguments)
        $output = & git -C $script:repo -c user.name=Canary -c user.email=canary@example.invalid `
            -c commit.gpgsign=false -c tag.gpgsign=false -c gc.auto=0 @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $output" }
        return ($output -join "`n")
    }
    function Save-FixtureCommit {
        $null = Invoke-FixtureGit @('add', '.')
        $null = Invoke-FixtureGit @('commit', '--quiet', '-m', 'fixture')
        return Invoke-FixtureGit @('rev-parse', 'HEAD')
    }
    function Set-FixtureVersion {
        param([string] $Version)
        @{ schema_version = 1; action_version = $Version; tools = @{} } | ConvertTo-Json |
            Set-Content (Join-Path $script:repo 'release.json')
    }
    function Get-RemoteTag {
        param([string] $Tag)
        $line = Invoke-FixtureGit @('ls-remote', '--tags', 'origin', "refs/tags/$Tag")
        if ($line) { return ($line -split '\s+')[0] }
        return ''
    }
}

Describe 'Action release native boundaries' -Tag Integration {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:repo
        $script:oldGlobal = $env:GIT_CONFIG_GLOBAL
        $script:oldSystem = $env:GIT_CONFIG_NOSYSTEM
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'empty-gitconfig'
        Set-Content $env:GIT_CONFIG_GLOBAL '' -NoNewline
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $null = Invoke-FixtureGit @('init', '--quiet', '-b', 'main')
        Set-Content (Join-Path $script:repo 'README.md') 'initial repository'
        $script:initial = Save-FixtureCommit
        Set-FixtureVersion '0.1.0'
        Set-Content (Join-Path $script:repo 'action.yml') 'runtime'
        $script:original = Save-FixtureCommit
        $remote = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.git')
        $null = Invoke-FixtureGit @('init', '--quiet', '--bare', $remote)
        $null = Invoke-FixtureGit @('remote', 'add', 'origin', $remote)
        $null = Invoke-FixtureGit @('push', '--quiet', 'origin', 'HEAD:refs/heads/main')
        $script:releases = [System.Collections.Generic.List[object]]::new()
        $script:failRelease = $false
        Mock Invoke-ReleaseGh -ModuleName Release {
            param($Arguments)
            if ($Arguments[0] -eq 'api') {
                return ConvertTo-Json -InputObject @(@($script:releases)) -Depth 5 -Compress
            }
            if ($script:failRelease) { throw 'Simulated release API failure.' }
            $script:releases.Add(@{ tag_name = $Arguments[2]; draft = $false; prerelease = $false })
        }
    }

    AfterEach {
        $env:GIT_CONFIG_GLOBAL = $script:oldGlobal
        $env:GIT_CONFIG_NOSYSTEM = $script:oldSystem
    }

    It 'publishes first version from a baseline with no manifest and is idempotent' {
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local -BaseRef $script:initial
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
        Get-RemoteTag v0 | Should -Be $script:original
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local -BaseRef $script:initial
        $script:releases.Count | Should -Be 1
    }

    It 'retains original release identity after documentation and CI-only changes' {
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local
        $workflows = Join-Path $script:repo '.github\workflows'
        $null = New-Item -ItemType Directory $workflows -Force
        Set-Content (Join-Path $workflows 'publish-action.yml') 'internal publisher'
        Set-Content (Join-Path $script:repo 'README.md') 'documentation'
        $null = Save-FixtureCommit
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local -BaseRef $script:original
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
        Get-RemoteTag v0 | Should -Be $script:original
        $script:releases.Count | Should -Be 1
    }

    It 'rejects conflicting published content without moving either remote tag' {
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local
        Set-Content (Join-Path $script:repo 'action.yml') 'changed runtime'
        $null = Save-FixtureCommit
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $script:original } | Should -Throw
        { Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local } | Should -Throw '*conflicts*'
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
        Get-RemoteTag v0 | Should -Be $script:original
    }

    It 'completes a retry after immutable tag creation but failed GitHub release creation' {
        $script:failRelease = $true
        { Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local } | Should -Throw '*API failure*'
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
        Get-RemoteTag v0 | Should -Be ''
        $script:failRelease = $false
        Set-Content (Join-Path $script:repo 'README.md') 'retry from equivalent source'
        $null = Save-FixtureCommit
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
        Get-RemoteTag v0 | Should -Be $script:original
        $script:releases.Count | Should -Be 1
    }

    It 'recovers after release creation without recreating the release' {
        $null = Invoke-FixtureGit @('push', '--quiet', 'origin', "$($script:original):refs/tags/v0.1.0")
        $script:releases.Add(@{ tag_name = 'v0.1.0'; draft = $false; prerelease = $false })
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local
        Get-RemoteTag v0 | Should -Be $script:original
        $script:releases.Count | Should -Be 1
    }

    It 'does not regress major when an old invocation follows a newer publication' {
        Set-FixtureVersion '0.10.0'
        $newer = Save-FixtureCommit
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local -BaseRef $script:original
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local -Ref $script:original -BaseRef $script:initial
        Get-RemoteTag v0 | Should -Be $newer
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
        $script:releases.Count | Should -Be 2
    }

    It 'rejects a raced major update through the real force-with-lease boundary' {
        Mock Invoke-ReleaseGh -ModuleName Release {
            param($Arguments)
            if ($Arguments[0] -eq 'api') { return '[[]]' }
            $null = Invoke-FixtureGit @('push', '--quiet', 'origin', "$($script:initial):refs/tags/v0")
        }
        { Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local } | Should -Throw '*failed*'
        Get-RemoteTag v0 | Should -Be $script:initial
        Get-RemoteTag 'v0.1.0' | Should -Be $script:original
    }

    It 'uses an annotated major tag object for its lease' {
        $null = Invoke-FixtureGit @('tag', '-a', 'v0', '-m', 'major')
        $null = Invoke-FixtureGit @('push', '--quiet', 'origin', 'refs/tags/v0')
        $tagObject = Invoke-FixtureGit @('rev-parse', 'refs/tags/v0')
        Set-FixtureVersion '0.1.1'
        $head = Save-FixtureCommit
        $plan = Get-ReleasePlan -RepositoryPath $script:repo -BaseRef $script:original
        $plan.PreviousMajorTarget | Should -Be $tagObject
        $plan.PreviousMajorTarget | Should -Not -Be $script:original
        Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local -BaseRef $script:original
        Get-RemoteTag v0 | Should -Be $head
    }

    It 'retains a pending increment across additional feature commits' {
        $null = Invoke-FixtureGit @('update-ref', 'refs/remotes/origin/main', $script:original)
        Set-FixtureVersion '0.1.1'
        $pending = Save-FixtureCommit
        Set-Content (Join-Path $script:repo 'action.yml') 'additional feature work'
        $null = Save-FixtureCommit
        $base = Get-ValidationReleaseBase -EventName push -Ref refs/heads/feature -EventData @{ before = $pending }
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $base } | Should -Not -Throw
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $pending } | Should -Throw
    }

    It 'requires an increment for consumer workflows and pins' -ForEach @('consumer', 'pin') {
        if ($_ -eq 'consumer') {
            $workflows = Join-Path $script:repo '.github\workflows'
            $null = New-Item -ItemType Directory $workflows -Force
            Set-Content (Join-Path $workflows 'release.yml') 'consumer release'
        }
        else {
            Set-Content (Join-Path $script:repo 'release.json') '{"schema_version":1,"action_version":"0.1.0","tools":{"cargo-release-plan":{"version":"0.5.10"}}}'
        }
        $null = Save-FixtureCommit
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $script:original } | Should -Throw
    }

    It 'returns a successful process exit when the candidate version tag is absent' {
        $pwsh = Get-Command pwsh -CommandType Application | Select-Object -First 1
        $start = [Diagnostics.ProcessStartInfo]::new($pwsh.Source)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['CANARY_REPOSITORY'] = $script:repo
        $start.Environment['CANARY_PUBLISH_SCRIPT'] = Join-Path $PSScriptRoot '..\scripts\Publish-Release.ps1'
        $start.ArgumentList.Add('-NoProfile')
        $start.ArgumentList.Add('-Command')
        # Match GitHub's native exit propagation, without a wall-clock timeout.
        $start.ArgumentList.Add('& $env:CANARY_PUBLISH_SCRIPT -RepositoryPath $env:CANARY_REPOSITORY -CheckOnly; if (Test-Path variable:\LASTEXITCODE) { exit $LASTEXITCODE }')
        $process = [Diagnostics.Process]::Start($start)
        try {
            $output = $process.StandardOutput.ReadToEnd()
            $errorOutput = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $process.ExitCode | Should -Be 0 -Because "$output $errorOutput"
        }
        finally { $process.Dispose() }
    }

    It 'classifies non-ASCII runtime paths without Git quoting hiding their prefix' {
        $scripts = Join-Path $script:repo 'scripts'
        $null = New-Item -ItemType Directory $scripts
        Set-Content (Join-Path $scripts ("runtime-$([char]0xfc).ps1")) 'runtime'
        $null = Save-FixtureCommit
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $script:original } | Should -Throw '*newer than*'
    }

    It 'does not recreate a missing full tag at the current commit when its release survives' {
        $script:releases.Add(@{ tag_name = 'v0.1.0'; draft = $false; prerelease = $false })
        { Publish-ActionRelease -RepositoryPath $script:repo -Repository fixture/local } | Should -Throw '*release but no tag*'
        Get-RemoteTag 'v0.1.0' | Should -Be ''
        Get-RemoteTag v0 | Should -Be ''
    }
}

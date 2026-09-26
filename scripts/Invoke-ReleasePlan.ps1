#Requires -Version 7.6
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/Bootstrap.psm1" -Force

switch ($env:CRP_COMMAND) {
    version {
        Invoke-BootstrapCommand $env:CRP_EXECUTABLE @('--version')
    }
    check-publishing-identity {
        Invoke-BootstrapCommand $env:CRP_EXECUTABLE @('check-publishing-identity')
    }
    release-context {
        if ([string]::IsNullOrWhiteSpace($env:CRP_CONFIG)) { throw 'release-context requires configuration.' }
        $arguments = @('release-context', '--manifest-path', 'Cargo.toml', '--config', $env:CRP_CONFIG)
        if ($env:CRP_BASE) { $arguments += @('--base', $env:CRP_BASE) }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try { Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments }
        finally { Pop-Location }
    }
    check-compatibility {
        if (-not $env:CRP_OUTPUT) { throw 'check-compatibility requires a new output directory.' }
        if ($env:CRP_DENY_FINDINGS -cnotin @('true', 'false')) { throw 'deny-findings must be true or false.' }
        $arguments = @('check-compatibility', '--manifest-path', 'Cargo.toml', '--output', $env:CRP_OUTPUT)
        if ($env:CRP_PREPARED) { $arguments += @('--prepared', $env:CRP_PREPARED) }
        if ($env:CRP_PLAN) { $arguments += @('--plan', $env:CRP_PLAN) }
        if ($env:CRP_BASE) { $arguments += @('--base', $env:CRP_BASE) }
        if ($env:CRP_DENY_FINDINGS -ceq 'true') { $arguments += '--deny-findings' }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try { Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments }
        finally { Pop-Location }
    }
    check-published {
        $arguments = @('check-published', '--manifest-path', 'Cargo.toml')
        if ($env:CRP_PLAN) { $arguments += @('--plan', $env:CRP_PLAN) }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try { Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments }
        finally { Pop-Location }
    }
    { $_ -in @('version-readiness', 'check') } {
        if ($env:CRP_BASE -cnotmatch '^[0-9a-f]{40}$') {
            throw "$env:CRP_COMMAND requires an explicit immutable base commit."
        }
        $arguments = @('check', '--manifest-path', 'Cargo.toml', '--base', $env:CRP_BASE, '--format', 'github')
        if ($env:CRP_COMMAND -eq 'check') {
            if ([string]::IsNullOrWhiteSpace($env:CRP_CONFIG)) {
                throw 'check requires an explicit workspace-relative publication configuration.'
            }
            $arguments += @('--config', $env:CRP_CONFIG)
        }
        $workspace = Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY
        Push-Location $workspace
        try {
            # Neither offline operation substitutes for external API compatibility checking.
            Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments
        }
        finally {
            Pop-Location
        }
    }
    prepare-publish {
        if ($env:CRP_SOURCE -cnotmatch '^[0-9a-f]{40}$') {
            throw 'prepare-publish requires an explicit immutable source commit.'
        }
        if ([string]::IsNullOrWhiteSpace($env:CRP_CONFIG) -or [string]::IsNullOrWhiteSpace($env:CRP_OUTPUT)) {
            throw 'prepare-publish requires configuration and an output destination.'
        }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try {
            Invoke-BootstrapCommand $env:CRP_EXECUTABLE @(
                'prepare-publish', '--manifest-path', 'Cargo.toml',
                '--config', $env:CRP_CONFIG, '--source', $env:CRP_SOURCE,
                '--output', $env:CRP_OUTPUT
            )
        }
        finally {
            Pop-Location
        }
    }
    publish-registry {
        if ([string]::IsNullOrWhiteSpace($env:CRP_PUBLICATION) -or [string]::IsNullOrWhiteSpace($env:CRP_OUTPUT)) {
            throw 'publish-registry requires publication and a new outcome destination.'
        }
        if ($env:CRP_DRY_RUN -cnotin @('true', 'false')) {
            throw 'dry-run must be true or false.'
        }
        $arguments = @(
            'publish', 'registry', '--publication', $env:CRP_PUBLICATION,
            '--manifest-path', 'Cargo.toml', '--output', $env:CRP_OUTPUT
        )
        if ($env:CRP_DRY_RUN -ceq 'true') {
            $arguments += '--dry-run'
        }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try {
            # Rust validates immutable intent and records this attempt separately, even on failure.
            Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments
        }
        finally {
            Pop-Location
        }
    }
    publish-github {
        if (-not $env:CRP_PUBLICATION -or -not $env:CRP_OUTPUT -or -not $env:CRP_BATCHES) {
            throw 'publish-github requires publication, outcome and batch destinations.'
        }
        if ($env:CRP_DRY_RUN -cnotin @('true', 'false')) { throw 'dry-run must be true or false.' }
        $arguments = @('publish', 'github', '--publication', $env:CRP_PUBLICATION, '--manifest-path', 'Cargo.toml', '--output', $env:CRP_OUTPUT, '--batches', $env:CRP_BATCHES)
        if ($env:CRP_DRY_RUN -ceq 'true') { $arguments += '--dry-run' }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try { Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments }
        finally { Pop-Location }
    }
    publish-binaries {
        if (-not $env:CRP_PUBLICATION -or -not $env:CRP_BATCH -or -not $env:CRP_OUTPUT -or -not $env:CRP_ARTIFACTS) {
            throw 'publish-binaries requires publication, batch, outcome and staging destinations.'
        }
        if ($env:CRP_NO_UPLOAD -cnotin @('true', 'false')) { throw 'no-upload must be true or false.' }
        $arguments = @('publish', 'binaries', '--publication', $env:CRP_PUBLICATION, '--batch', $env:CRP_BATCH, '--manifest-path', 'Cargo.toml', '--output', $env:CRP_OUTPUT, '--artifacts', $env:CRP_ARTIFACTS)
        if ($env:CRP_NO_UPLOAD -ceq 'true') { $arguments += '--no-upload' }
        Push-Location (Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY)
        try { Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments }
        finally { Pop-Location }
    }
    publish-report {
        if (-not $env:CRP_REPOSITORY -or -not $env:CRP_OUTCOMES -or -not $env:CRP_JOBS -or -not $env:CRP_OUTPUT) {
            throw 'publish-report requires caller repository, outcomes, job results and report destination.'
        }
        if ($env:CRP_NO_ISSUE -cnotin @('true', 'false')) { throw 'no-issue must be true or false.' }
        $arguments = @('publish', 'report', '--repository', $env:CRP_REPOSITORY, '--outcomes', $env:CRP_OUTCOMES, '--jobs', $env:CRP_JOBS, '--output', $env:CRP_OUTPUT)
        if ($env:CRP_PUBLICATION) { $arguments += @('--publication', $env:CRP_PUBLICATION) }
        if ($env:CRP_NO_ISSUE -ceq 'true') { $arguments += '--no-issue' }
        Invoke-BootstrapCommand $env:CRP_EXECUTABLE $arguments
    }
    default {
        throw "Unsupported action command '$env:CRP_COMMAND'."
    }
}

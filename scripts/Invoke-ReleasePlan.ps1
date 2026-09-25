#Requires -Version 7.6
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/Bootstrap.psm1" -Force

switch ($env:CRP_COMMAND) {
    version {
        Invoke-BootstrapCommand $env:CRP_EXECUTABLE @('--version')
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
    default {
        throw "Unsupported action command '$env:CRP_COMMAND'."
    }
}

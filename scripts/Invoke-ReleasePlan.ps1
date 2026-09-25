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
    default {
        throw "Unsupported action command '$env:CRP_COMMAND'."
    }
}

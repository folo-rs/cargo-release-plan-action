#Requires -Version 7.6
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/Bootstrap.psm1" -Force

switch ($env:CRP_COMMAND) {
    version {
        Invoke-BootstrapCommand $env:CRP_EXECUTABLE @('--version')
    }
    version-readiness {
        if ($env:CRP_BASE -cnotmatch '^[0-9a-f]{40}$') {
            throw 'version-readiness requires an explicit immutable base commit.'
        }
        $workspace = Join-Path $env:GITHUB_WORKSPACE $env:CRP_WORKING_DIRECTORY
        Push-Location $workspace
        try {
            # Queue checks deliberately omit publication config and external API checks.
            Invoke-BootstrapCommand $env:CRP_EXECUTABLE @('check', '--manifest-path', 'Cargo.toml', '--base', $env:CRP_BASE, '--format', 'github')
        }
        finally {
            Pop-Location
        }
    }
    default {
        throw "Unsupported action command '$env:CRP_COMMAND'."
    }
}

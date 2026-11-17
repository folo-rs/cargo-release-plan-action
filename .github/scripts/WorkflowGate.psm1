#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GateApi {
    param([string] $Path)

    $PSNativeCommandUseErrorActionPreference = $false
    $json = & gh api --method GET $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot read workflow evidence at ${Path}: $json" }
    return ,(($json -join "`n") | ConvertFrom-Json -AsHashtable -NoEnumerate)
}

function Get-GatePages {
    param([string] $Path, [string] $Property)

    $page = 1
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    do {
        $response = Invoke-GateApi "$Path${separator}per_page=100&page=$page"
        $items = @(if ($Property) { $response[$Property] } else { $response })
        $items
        $page++
    } while ($items.Count -eq 100)
}

function Assert-CapacityCancellation {
    param(
        [System.Collections.IDictionary] $Job,
        [System.Collections.IDictionary] $Run,
        [System.Collections.IDictionary] $Check,
        [AllowEmptyCollection()][object[]] $Annotations
    )

    if ($Job.status -cne 'completed' -or $Job.conclusion -cne 'cancelled' -or
        -not $Job.Contains('steps') -or $null -eq $Job.steps -or @($Job.steps).Count -ne 0 -or
        @($Job.labels).Count -ne 1 -or $Job.labels[0] -cne 'macos-latest' -or
        $Job.runner_id -or $Job.runner_name) {
        throw "Job '$($Job.name)' is not an unstarted macos-latest cancellation."
    }

    if ($Check.name -cne $Job.name -or $Check.head_sha -cne $Run.head_sha -or
        $Check.check_suite.id -ne $Run.check_suite_id -or $Check.app.slug -cne 'github-actions' -or
        $Check.app.id -ne 15368 -or
        $Check.status -cne 'completed' -or $Check.conclusion -cne 'cancelled' -or
        $Check.output.annotations_count -lt 1) {
        throw 'Capacity evidence is not linked to the cancelled GitHub Actions job.'
    }
    if ($Annotations.Count -ne $Check.output.annotations_count) { throw 'Incomplete check annotations.' }
    $confirmed = $false
    foreach ($annotation in $Annotations) {
        if ($annotation.annotation_level -ceq 'failure' -and
            $annotation.message -ceq 'The job was not acquired by Runner of type hosted even after multiple attempts') {
            $confirmed = $true
        }
        elseif ($annotation.annotation_level -cne 'notice' -or
            $annotation.message -cne 'Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.') {
            throw 'Unrecognized cancellation annotation.'
        }
    }
    if (-not $confirmed) { throw 'Cancellation is not confirmed as hosted-runner acquisition failure.' }
}

function Assert-WorkflowGate {
    param(
        [Parameter(Mandatory)][ValidateSet('validation', 'source', 'published')][string] $Profile,
        [Parameter(Mandatory)][System.Collections.IDictionary] $EventData,
        [Parameter(Mandatory)][string] $EventName,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][long] $RunId,
        [Parameter(Mandatory)][int] $Attempt,
        [Parameter(Mandatory)][string] $Sha
    )

    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $RunId -lt 1 -or $Attempt -lt 1 -or $Sha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Invalid workflow identity.'
    }
    $head = if ($EventName -ceq 'pull_request') { $EventData.pull_request.head.sha } else { $Sha }
    $runPath = "repos/$Repository/actions/runs/$RunId"
    $run = Invoke-GateApi $runPath
    if ($head -cnotmatch '^[0-9a-f]{40}$' -or $run.id -ne $RunId -or
        $run.repository.full_name -cne $Repository -or $run.head_sha -cne $head -or
        $run.run_attempt -ne $Attempt -or $run.event -cne $EventName) {
        throw 'Workflow evidence does not match the current run, head and attempt.'
    }

    $prefix = ''
    switch -CaseSensitive ($run.path) {
        '.github/workflows/validate.yml' { if ($Profile -cne 'validation') { throw 'Wrong gate profile.' } }
        '.github/workflows/source-canary.yml' { if ($Profile -cne 'source') { throw 'Wrong gate profile.' } }
        '.github/workflows/published-installation.yml' { if ($Profile -cne 'published') { throw 'Wrong gate profile.' } }
        '.github/workflows/validate-release.yml' { $prefix = "$Profile / " }
        '.github/workflows/publish-action.yml' {
            if ($Profile -cne 'published') { throw 'Wrong gate profile.' }
            $prefix = 'availability / '
        }
        default { throw "Unrecognized workflow caller: $($run.path)." }
    }

    $gate = switch ($Profile) {
        validation { 'Action validation' }
        source { 'Source installation' }
        published { 'Published installation' }
    }
    $mac = @()
    $expected = switch ($Profile) {
        validation {
            'identity / rerun-prerequisite', 'identity / source / resolve', 'identity / verify', 'version-readiness', 'workflows'
            foreach ($runner in @('ubuntu-latest', 'windows-latest', 'macos-latest')) { "tests ($runner)" }
            $mac = @('tests (macos-latest)')
        }
        source {
            foreach ($runner in @('ubuntu-latest', 'ubuntu-24.04-arm', 'windows-latest', 'windows-11-arm', 'macos-latest')) { "install ($runner)" }
            $mac = @('install (macos-latest)')
        }
        published {
            'matrix'
            $release = Get-Content (Join-Path $PSScriptRoot '..\..\release.json') -Raw | ConvertFrom-Json
            foreach ($platform in $release.platforms) {
                foreach ($method in @('install', 'binstall')) {
                    $name = "$method ($($platform.target))"
                    $name
                    if ($platform.runner -ceq 'macos-latest' -and $platform.target -ceq 'aarch64-apple-darwin') { $mac += $name }
                }
            }
        }
    }
    $expected = @($expected | ForEach-Object { "$prefix$_" })
    $mac = @($mac | ForEach-Object { "$prefix$_" })
    $gate = "$prefix$gate"

    $jobs = @(Get-GatePages "$runPath/jobs?filter=all" 'jobs')
    # Keep successful earlier jobs on failed-job reruns, but never let them mask a newer execution.
    $scoped = @($jobs | Where-Object { -not $prefix -or $_.name.StartsWith($prefix, [StringComparison]::Ordinal) })
    foreach ($job in $scoped) {
        if ($job.id -lt 1 -or $job.run_id -ne $RunId -or $job.head_sha -cne $head -or
            $job.run_attempt -lt 1 -or $job.run_attempt -gt $Attempt -or
            ($job.name -cne $gate -and $job.name -cnotin $expected)) {
            throw "Unexpected or unrelated job evidence: $($job.name)."
        }
    }
    foreach ($name in @($expected) + @($gate)) {
        $executions = @($scoped | Where-Object name -CEQ $name | Sort-Object run_attempt -Descending)
        if (-not $executions.Count) { throw "Missing workflow job: $name." }
        $job = $executions[0]
        if (@($executions | Where-Object run_attempt -EQ $job.run_attempt).Count -ne 1) { throw "Ambiguous workflow job: $name." }
        if ($name -ceq $gate) {
            if ($job.run_attempt -ne $Attempt) { throw 'The aggregate job is not from this attempt.' }
            continue
        }
        if ($job.status -ceq 'completed' -and $job.conclusion -ceq 'success') { continue }
        # Publication and manual candidate validation still require every native execution.
        if ($name -cin $mac -and ($Profile -cne 'published' -or $EventName -ceq 'pull_request')) {
            $checkPrefix = "$($env:GITHUB_API_URL)/repos/$Repository/check-runs/"
            if ($job.check_run_url -cnotmatch ('^' + [regex]::Escape($checkPrefix) + '([1-9][0-9]*)$')) {
                throw 'Job does not identify a check run in this repository.'
            }
            $checkPath = "repos/$Repository/check-runs/$($Matches[1])"
            $check = Invoke-GateApi $checkPath
            $annotations = @(Get-GatePages "$checkPath/annotations")
            Assert-CapacityCancellation -Job $job -Run $run -Check $check -Annotations $annotations
            Write-Warning "Ignoring confirmed hosted macOS runner capacity cancellation: $($job.name) (job $($job.id), attempt $($job.run_attempt))."
            "::warning::Confirmed hosted macOS runner capacity cancellation; no steps executed: $($job.name) (job $($job.id), attempt $($job.run_attempt))." | Write-Host
        }
        else { throw "Required workflow job did not succeed: $name ($($job.conclusion))." }
    }
    $current = Invoke-GateApi $runPath
    if ($current.id -ne $RunId -or $current.head_sha -cne $head -or $current.run_attempt -ne $Attempt) {
        throw 'Workflow changed during result reconciliation.'
    }
}

Export-ModuleMember -Function Assert-WorkflowGate

#Requires -Version 7.6
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ContextRouting {
    param([Parameter(Mandatory)][string] $Json, [Parameter(Mandatory)][string] $Repository)

    $context = $Json | ConvertFrom-Json
    if ($context.schema_version -ne 2 -or $context.repository -ine $Repository -or
        $context.head -cnotmatch '^[0-9a-f]{40}$' -or
        $context.release_history -cnotmatch '^[0-9a-f]{40}$' -or
        ($null -ne $context.merge_target -and $context.merge_target -cnotmatch '^[0-9a-f]{40}$') -or
        $context.concurrency_group -cnotmatch '^cargo-release-plan-[0-9a-f]{64}$') {
        throw 'Release context does not identify this caller repository and immutable inputs.'
    }
    return $context
}

function Get-CheckMergeTarget {
    param([Parameter(Mandatory)][string] $EventName, [string] $EventJson)

    if ($EventName -notin @('pull_request', 'merge_group')) { return '' }
    $event = $EventJson | ConvertFrom-Json
    # The event supplies a tested target, not evidence that its commits have been released.
    $target = if ($EventName -eq 'pull_request') { $event.pull_request.base.sha } else { $event.merge_group.base_sha }
    if ($target -cnotmatch '^[0-9a-f]{40}$') { throw "Event $EventName does not identify an immutable merge target." }
    return $target
}

function Get-BatchRouting {
    param(
        [Parameter(Mandatory)][string] $Outcome,
        [Parameter(Mandatory)][string] $Publication,
        [Parameter(Mandatory)][string] $Batches,
        [Parameter(Mandatory)][string] $Target
    )

    $intent = Get-Content $Publication -Raw | ConvertFrom-Json
    $receipt = Get-Content $Outcome -Raw | ConvertFrom-Json
    if ($receipt.schema_version -ne 1 -or $receipt.phase -cne 'github' -or
        $receipt.publication_id -cne $intent.id -or $receipt.dry_run -ne $false) {
        throw 'GitHub routing receipt is not linked to this non-dry-run publication.'
    }
    $selected = @($receipt.batches | Where-Object target -CEQ $Target)
    if ($selected.Count -gt 1) { throw "GitHub routing repeats target $Target." }
    if ($selected.Count -eq 0) { return $null }
    $item = $selected[0]
    # Batch files are transported separately; routing may not escape their artifact directory.
    if ($item.path -cne "$Target.json" -or $item.batch_id -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid frozen batch routing for $Target."
    }
    $path = Join-Path $Batches $item.path
    $batch = Get-Content $path -Raw | ConvertFrom-Json
    if ($batch.publication_id -cne $intent.id -or $batch.batch_id -cne $item.batch_id -or $batch.target -cne $Target) {
        throw "Frozen batch does not match its routing receipt for $Target."
    }
    # Rust validates the content-derived identity before execution; this is only artifact routing.
    return $path
}

function Write-JobResults {
    param([Parameter(Mandatory)][string] $NeedsJson, [Parameter(Mandatory)][string] $Output)

    $needs = $NeedsJson | ConvertFrom-Json -AsHashtable
    $jobs = [ordered]@{}
    foreach ($phase in @('prepare', 'registry', 'github', 'binaries')) {
        $result = $needs[$phase].result
        if ($result -notin @('success', 'failure', 'cancelled', 'skipped')) {
            throw "Missing or invalid platform result for $phase."
        }
        $jobs[$phase] = $result
    }
    $jobs | ConvertTo-Json | Set-Content $Output
}

Export-ModuleMember -Function Get-ContextRouting, Get-CheckMergeTarget, Get-BatchRouting, Write-JobResults

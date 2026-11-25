#Requires -Version 7.6

# Implements the bounded metadata, completeness and freshness gate before the
# official artifact action downloads same-run archives.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# These values bound the observed artifact-inventory propagation window without
# turning missing evidence or API failures into an unbounded workflow wait.
$script:DefaultMaximumAttempts = 12
$script:DefaultRetryDelaySeconds = 5
$script:MetadataTimeoutSeconds = 30
$script:TransientStatuses = @(404, 408, 429, 500, 502, 503, 504)

function Get-ArtifactHttpStatusCode {
    # Extracts a response status when present; statusless transport failures remain
    # permanent because their retry semantics are not known.
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) { return $null }
    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if ($null -eq $statusProperty) { return $null }
    return [int] $statusProperty.Value
}

function Test-ArtifactTransientFailure {
    # Only absence, throttling and recognized service-side failures consume the
    # retry budget. Authentication, authorization, expiry and validation errors
    # remain immediately visible.
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $statusCode = Get-ArtifactHttpStatusCode -ErrorRecord $ErrorRecord
    return $null -ne $statusCode -and $statusCode -in $script:TransientStatuses
}

function Get-ArtifactResponseProperty {
    # Reads both mocked dictionaries and real PowerShell HTTP response objects.
    param([Parameter(Mandatory)] $Response, [Parameter(Mandatory)] [string] $Name)

    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.Contains($Name) -and $null -ne $Response[$Name]) {
            return $Response[$Name]
        }
    }
    else {
        $property = $Response.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    throw "GitHub artifact response omitted required property '$Name'."
}

function Get-ArtifactHeaders {
    # Keeps the token in request headers rather than process arguments.
    param([Parameter(Mandatory)] [string] $GitHubToken)

    return @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $GitHubToken"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Get-GitHubRunArtifacts {
    # Reads the same complete authenticated run inventory used by the pinned
    # download action for exact ID, name and pattern resolution.
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $artifacts = @()
    $page = 1
    $expected = $null

    while ($true) {
        try {
            $response = Invoke-RestMethod `
                -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page" `
                -Headers $Headers `
                -TimeoutSec $script:MetadataTimeoutSeconds `
                -ErrorAction Stop
        }
        catch {
            if ((Get-ArtifactHttpStatusCode -ErrorRecord $_) -eq 404) { return @() }
            throw
        }

        if ($null -eq $expected) {
            $expected = [int] (Get-ArtifactResponseProperty -Response $response -Name 'total_count')
        }
        $batch = @(Get-ArtifactResponseProperty -Response $response -Name 'artifacts')
        $artifacts += $batch
        if ($artifacts.Count -ge $expected) { return @($artifacts) }
        if ($batch.Count -eq 0) {
            throw "GitHub returned an incomplete artifact inventory for workflow run $RunId."
        }
        $page++
    }
}

function Get-GitHubRunJobs {
    # Lists successful upload steps from all attempts so partial reruns can reuse
    # unchanged producers without accepting missing or stale replacement uploads.
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $jobs = @()
    $page = 1
    $expected = $null

    while ($true) {
        $response = Invoke-RestMethod `
            -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/runs/$RunId/jobs?filter=all&per_page=100&page=$page" `
            -Headers $Headers `
            -TimeoutSec $script:MetadataTimeoutSeconds `
            -ErrorAction Stop
        if ($null -eq $expected) {
            $expected = [int] (Get-ArtifactResponseProperty -Response $response -Name 'total_count')
        }
        $batch = @(Get-ArtifactResponseProperty -Response $response -Name 'jobs')
        $jobs += $batch
        if ($jobs.Count -ge $expected) { return @($jobs) }
        if ($batch.Count -eq 0) {
            throw "GitHub returned an incomplete job inventory for workflow run $RunId."
        }
        $page++
    }
}

function Get-ArtifactJobMarker {
    # Reusable workflows prefix local job names; the final component is the stable
    # producer identity shared by each execution copy.
    param([Parameter(Mandatory)] $Job)

    $name = [string] (Get-ArtifactResponseProperty -Response $Job -Name 'name')
    $separator = $name.LastIndexOf(' / ', [StringComparison]::Ordinal)
    if ($separator -lt 0) { return $name }
    return $name.Substring($separator + 3)
}

function Get-ExpectedArtifactProducers {
    # Resolves genuine successful producer executions. A job copied into a later
    # partial rerun has the same marker, scoped step identity and timestamps, so
    # the copy cannot increase the expected artifact count.
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [string[]] $ProducerSteps,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $executions = @{}
    $producers = @()
    $jobs = @(Get-GitHubRunJobs -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId -Headers $Headers)

    foreach ($job in ($jobs | Sort-Object {
                [long] (Get-ArtifactResponseProperty -Response $_ -Name 'run_attempt')
            })) {
        $successfulSteps = @(
            Get-ArtifactResponseProperty -Response $job -Name 'steps' | Where-Object {
                (Get-ArtifactResponseProperty -Response $_ -Name 'name') -cin $ProducerSteps -and
                (Get-ArtifactResponseProperty -Response $_ -Name 'conclusion') -ceq 'success'
            }
        )
        if ($successfulSteps.Count -eq 0) { continue }

        $marker = Get-ArtifactJobMarker -Job $job
        $started = [string] (Get-ArtifactResponseProperty -Response $job -Name 'started_at')
        $completed = [string] (Get-ArtifactResponseProperty -Response $job -Name 'completed_at')
        $stepIdentity = @(
            $successfulSteps |
                ForEach-Object { [string] (Get-ArtifactResponseProperty -Response $_ -Name 'name') } |
                Sort-Object -CaseSensitive -Unique
        )
        $execution = ConvertTo-Json -InputObject @(
            $marker, $stepIdentity, $started, $completed
        ) -Compress
        if ($executions.ContainsKey($execution)) { continue }

        $executions[$execution] = $true
        foreach ($step in $successfulSteps) {
            $producers += [pscustomobject]@{
                Marker = $marker
                Step = [string] (Get-ArtifactResponseProperty -Response $step -Name 'name')
                StartedAt = [DateTimeOffset]::Parse(
                    $started,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
            }
        }
    }

    return @($producers)
}

function Select-GitHubArtifacts {
    # Selects from the same run inventory as the official action and validates
    # ownership and expiration before declaring the download preflight complete.
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [string] $GitHubToken,
        [string] $ArtifactIds,
        [string] $Name,
        [string] $Pattern
    )

    $selectors = @(
        if (-not [string]::IsNullOrWhiteSpace($ArtifactIds)) { 'artifact-ids' }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { 'name' }
        if (-not [string]::IsNullOrWhiteSpace($Pattern)) { 'pattern' }
    )
    if ($selectors.Count -ne 1) {
        throw 'Artifact preflight requires exactly one of artifact-ids, name or pattern.'
    }

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    $available = @(Get-GitHubRunArtifacts -ApiUrl $ApiUrl -Repository $Repository `
            -RunId $RunId -Headers $headers)
    $selected = @(
        if ($selectors[0] -ceq 'artifact-ids') {
            $ids = @($ArtifactIds -split ',' | ForEach-Object {
                    $value = $_.Trim()
                    if ($value -notmatch '^[1-9][0-9]*$') { throw "Invalid artifact ID '$value'." }
                    [long] $value
                })
            if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
                throw 'Artifact IDs must be unique.'
            }
            $matches = @(
                $available | Where-Object {
                    [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') -in $ids
                }
            )
            $missing = @($ids | Where-Object {
                    [long] $_ -notin @(
                        $matches | ForEach-Object {
                            [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id')
                        }
                    )
                })
            if ($missing.Count -gt 0) { return @() }
            $matches
        }
        elseif ($selectors[0] -ceq 'name') {
            @(
                $available |
                    Where-Object { (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $Name } |
                    Sort-Object { [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') } -Descending |
                    Select-Object -First 1
            )
        }
        else {
            @(
                $available |
                    Where-Object { (Get-ArtifactResponseProperty -Response $_ -Name 'name') -clike $Pattern } |
                    Sort-Object { [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') } -Descending
            ) | Group-Object -CaseSensitive {
                Get-ArtifactResponseProperty -Response $_ -Name 'name'
            } | ForEach-Object {
                $_.Group | Select-Object -First 1
            }
        }
    )

    foreach ($artifact in @($selected)) {
        $workflowRun = Get-ArtifactResponseProperty -Response $artifact -Name 'workflow_run'
        $artifactRun = [long] (Get-ArtifactResponseProperty -Response $workflowRun -Name 'id')
        if ($artifactRun -ne $RunId) {
            throw "Artifact '$((Get-ArtifactResponseProperty -Response $artifact -Name 'name'))' " +
                "belongs to workflow run $artifactRun, not $RunId."
        }
        if ([bool] (Get-ArtifactResponseProperty -Response $artifact -Name 'expired')) {
            throw "Artifact '$((Get-ArtifactResponseProperty -Response $artifact -Name 'name'))' has expired."
        }
    }

    return @($selected)
}

function Test-ArtifactFreshness {
    # Pairs each genuine producer execution with one distinct artifact created no
    # earlier than that producer's start. This rejects previous-attempt artifacts
    # that otherwise satisfy count-only pattern checks.
    param(
        [Parameter(Mandatory)] [object[]] $Artifacts,
        [Parameter(Mandatory)] [object[]] $Producers
    )

    if ($Artifacts.Count -lt $Producers.Count) { return $false }
    $unused = [Collections.Generic.List[object]]::new()
    foreach ($artifact in $Artifacts) { $unused.Add($artifact) }

    foreach ($producer in ($Producers | Sort-Object StartedAt -Descending)) {
        $match = @(
            $unused |
                Where-Object {
                    [DateTimeOffset]::Parse(
                        [string] (Get-ArtifactResponseProperty -Response $_ -Name 'created_at'),
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    ) -ge $producer.StartedAt
                } |
                Sort-Object {
                    [DateTimeOffset]::Parse(
                        [string] (Get-ArtifactResponseProperty -Response $_ -Name 'created_at'),
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind
                    )
                } |
                Select-Object -First 1
        )
        if ($match.Count -eq 0) { return $false }
        $null = $unused.Remove($match[0])
    }

    return $true
}

function Invoke-ArtifactPreflight {
    # Waits only for authenticated metadata visibility and producer freshness.
    # Archive transfer remains owned by the pinned official download action.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [ValidateRange(1, [long]::MaxValue)] [long] $RunId,
        [Parameter(Mandatory)] [string] $GitHubToken,
        [string] $ArtifactIds,
        [string] $Name,
        [string] $Pattern,
        [string[]] $ProducerSteps = @(),
        [switch] $AllowEmpty,
        [ValidateRange(1, 100)] [int] $MaximumAttempts = $script:DefaultMaximumAttempts,
        [ValidateRange(0, 60)] [int] $RetryDelaySeconds = $script:DefaultRetryDelaySeconds
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Expected GitHub repository in owner/name form.'
    }
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        throw 'Artifact preflight requires a GitHub token.'
    }

    $selector = @(
        if (-not [string]::IsNullOrWhiteSpace($ArtifactIds)) { 'artifact-ids' }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { 'name' }
        if (-not [string]::IsNullOrWhiteSpace($Pattern)) { 'pattern' }
    )
    if ($selector.Count -ne 1) {
        throw 'Artifact preflight requires exactly one of artifact-ids, name or pattern.'
    }
    if ($selector[0] -ceq 'pattern' -and $ProducerSteps.Count -eq 0) {
        throw 'Pattern downloads require successful producer upload-step names.'
    }
    if ($selector[0] -cne 'pattern' -and ($ProducerSteps.Count -ne 0 -or $AllowEmpty)) {
        throw 'Producer completeness and empty-result handling apply only to pattern downloads.'
    }

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $producers = @()
            if ($selector[0] -ceq 'pattern') {
                $producers = @(Get-ExpectedArtifactProducers -ApiUrl $ApiUrl -Repository $Repository `
                        -RunId $RunId -ProducerSteps $ProducerSteps -Headers $headers)
                if ($producers.Count -eq 0 -and $AllowEmpty) { return }
            }

            $selected = @(Select-GitHubArtifacts -ApiUrl $ApiUrl -Repository $Repository `
                    -RunId $RunId -GitHubToken $GitHubToken -ArtifactIds $ArtifactIds `
                    -Name $Name -Pattern $Pattern)
            $ready = $selected.Count -gt 0
            if ($selector[0] -ceq 'pattern') {
                $ready = $producers.Count -gt 0 -and
                    $selected.Count -gt 0 -and
                    $selected.Count -ge $producers.Count -and
                    (Test-ArtifactFreshness -Artifacts $selected -Producers $producers)
            }

            if ($ready) {
                Write-Host 'Artifact metadata is visible and fresh for the selected workflow run.'
                foreach ($artifact in $selected) {
                    [pscustomobject]@{
                        Id = [long] (Get-ArtifactResponseProperty -Response $artifact -Name 'id')
                        Name = [string] (Get-ArtifactResponseProperty -Response $artifact -Name 'name')
                    }
                }
                return
            }
        }
        catch {
            if (-not (Test-ArtifactTransientFailure -ErrorRecord $_)) { throw }
        }

        if ($attempt -eq $MaximumAttempts) {
            throw "Selected artifact metadata was still unavailable for workflow run $RunId " +
                "after $MaximumAttempts attempts."
        }
        Write-Host "Selected artifact metadata is not visible yet for workflow run $RunId; retrying."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}

function Get-ArtifactArchiveStatus {
    # The REST download endpoint returns a signed redirect. Read only headers and
    # disable redirects so neither the credential nor the signed URL leaves this request.
    param([uri] $Uri, [hashtable] $Headers)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($script:MetadataTimeoutSeconds)
    try {
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('cargo-release-plan-action')
        foreach ($header in $Headers.GetEnumerator()) {
            $client.DefaultRequestHeaders.Add($header.Key, $header.Value)
        }
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).
            GetAwaiter().GetResult()
        try {
            if ([int] $response.StatusCode -eq 302 -and -not $response.Headers.Location) {
                throw 'GitHub returned an archive redirect without a Location.'
            }
            return [int] $response.StatusCode
        }
        finally { $response.Dispose() }
    }
    finally { $client.Dispose() }
}

function Wait-ArtifactArchiveRedirect {
    # After an actual transfer failure, exercise the REST downloader's GET with the
    # workflow credential. A redirect authorizes a transfer, not access to the blob.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long[]] $ArtifactIds,
        [Parameter(Mandatory)] [string] $GitHubToken
    )

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    foreach ($id in $ArtifactIds) {
        $uri = "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/artifacts/$id/zip"
        for ($attempt = 1; $attempt -le $script:DefaultMaximumAttempts; $attempt++) {
            $status = Get-ArtifactArchiveStatus -Uri $uri -Headers $headers
            if ($status -eq 302) { break }
            $detail = "Archive GET for artifact $id in $Repository returned HTTP $status " +
                "with the workflow token (attempt $attempt/$script:DefaultMaximumAttempts)."
            if ($status -eq 404 -and $attempt -eq $script:DefaultMaximumAttempts -and $ArtifactIds.Count -eq 1) {
                # A masked REST denial may outlast retries. The official same-run
                # client can retry one immutable ID without accepting a partial set.
                Write-Warning "$detail Retrying the transfer with the same-run artifact service instead."
                return $false
            }
            if ($status -notin $script:TransientStatuses -or
                $attempt -eq $script:DefaultMaximumAttempts) {
                throw "$detail Check this job's artifact access; a 404 does not distinguish delay from denial."
            }
            Write-Warning "$detail Retrying in $script:DefaultRetryDelaySeconds seconds."
            Start-Sleep -Seconds $script:DefaultRetryDelaySeconds
        }
    }
    return $true
}

function Assert-ArtifactTransferComplete {
    # The pinned downloader fails for a missing single ID, but only warns when
    # some of several IDs disappear. Multi-artifact receipts must have exactly
    # the named directories from the frozen selection, not a flat receipt.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [object[]] $Selection)

    if ($Selection.Count -eq 1) { return }
    $missing = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Selection) {
        if (-not $missing.Add($item.Name)) {
            throw "Cannot distinguish multiple selected artifact IDs named '$($item.Name)'."
        }
    }
    foreach ($entry in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        if (-not $entry.PSIsContainer -or -not $missing.Remove($entry.Name)) {
            throw "Incomplete artifact transfer: unexpected staged entry '$($entry.Name)'."
        }
    }
    if ($missing.Count) { throw "Incomplete artifact transfer: missing $($missing -join ', ')." }
}

Export-ModuleMember -Function Invoke-ArtifactPreflight, Wait-ArtifactArchiveRedirect, Assert-ArtifactTransferComplete

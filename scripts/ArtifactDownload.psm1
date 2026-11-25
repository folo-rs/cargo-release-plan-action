#Requires -Version 7.6

# Implements the bounded metadata and archive retry boundary for same-run
# artifact transfers. Keeping both stages here prevents inventory visibility
# from masking a later archive-download 404.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# The short bounded cadence covers the observed upload propagation window
# without turning missing evidence into an unbounded wait.
$script:DefaultMaximumAttempts = 12
$script:DefaultRetryDelaySeconds = 5
# Metadata is small and should settle quickly; archives get a longer but finite
# transfer window because hosted redirects and actual bytes participate.
$script:MetadataTimeoutSeconds = 30
$script:ArchiveTimeoutSeconds = 60

function Get-ArtifactHttpStatusCode {
    # Extracts status only when the failed request supplied one; statusless transport
    # errors remain permanent so the retry policy cannot hide authentication issues.
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) { return $null }
    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if ($null -eq $statusProperty) { return $null }
    return [int] $statusProperty.Value
}

function Get-ArtifactResponseProperty {
    # Reads mocked dictionaries and real PowerShell HTTP objects without assuming
    # one response representation.
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
    # Builds authentication headers at the download boundary so tokens never
    # appear in process arguments.
    param([Parameter(Mandatory)] [string] $GitHubToken)

    return @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $GitHubToken"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Get-GitHubArtifact {
    # Resolves an exact immutable ID directly. Only eventual absence is retryable;
    # expiration, authentication and service failures remain visible.
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $ArtifactId,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    try {
        return Invoke-RestMethod `
            -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/artifacts/$ArtifactId" `
            -Headers $Headers `
            -TimeoutSec $script:MetadataTimeoutSeconds `
            -ErrorAction Stop
    }
    catch {
        if ((Get-ArtifactHttpStatusCode -ErrorRecord $_) -eq 404) { return $null }
        throw
    }
}

function Get-GitHubRunArtifacts {
    # Reads the complete run inventory used by name and pattern consumers. GitHub
    # can briefly return no inventory or 404 while a newly completed upload settles.
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
    # Lists all attempts so pattern completeness reflects genuine producer
    # executions rather than only the current attempt's job snapshot.
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
    # Reusable workflows prefix displayed job names. Only the final local component
    # participates in producer identity.
    param([Parameter(Mandatory)] $Job)

    $name = [string] (Get-ArtifactResponseProperty -Response $Job -Name 'name')
    $separator = $name.LastIndexOf(' / ', [StringComparison]::Ordinal)
    if ($separator -lt 0) { return $name }
    return $name.Substring($separator + 3)
}

function Get-ExpectedArtifactCount {
    # Counts successful upload-step executions across attempts. GitHub can copy an
    # untouched successful job into a later rerun; identical name and execution
    # timestamps identify that copy without requiring it to upload again.
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [string[]] $ProducerSteps,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $executions = @{}
    $expected = 0
    $jobs = @(Get-GitHubRunJobs -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId -Headers $Headers)

    foreach ($job in ($jobs | Sort-Object {
                [long] (Get-ArtifactResponseProperty -Response $_ -Name 'run_attempt')
            })) {
        $steps = @(Get-ArtifactResponseProperty -Response $job -Name 'steps')
        $successfulSteps = @($steps | Where-Object {
                (Get-ArtifactResponseProperty -Response $_ -Name 'name') -in $ProducerSteps -and
                (Get-ArtifactResponseProperty -Response $_ -Name 'conclusion') -ceq 'success'
            })
        if ($successfulSteps.Count -eq 0) { continue }

        $marker = Get-ArtifactJobMarker -Job $job
        $started = [string] (Get-ArtifactResponseProperty -Response $job -Name 'started_at')
        $completed = [string] (Get-ArtifactResponseProperty -Response $job -Name 'completed_at')
        $execution = ConvertTo-Json -InputObject @($marker, $started, $completed) -Compress
        if ($executions.ContainsKey($execution)) { continue }

        $executions[$execution] = $true
        $expected += $successfulSteps.Count
    }

    return $expected
}

function Select-GitHubArtifacts {
    # Selects one exact ID, name or complete pattern and verifies run ownership and
    # expiry before any archive transfer starts.
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
        throw 'Artifact download requires exactly one of artifact-ids, name or pattern.'
    }

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
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
            foreach ($id in $ids) {
                $artifact = Get-GitHubArtifact -ApiUrl $ApiUrl -Repository $Repository `
                    -ArtifactId $id -Headers $headers
                if ($null -eq $artifact) { return @() }
                $artifact
            }
        }
        else {
            $available = @(Get-GitHubRunArtifacts -ApiUrl $ApiUrl -Repository $Repository `
                    -RunId $RunId -Headers $headers)
            if ($selectors[0] -ceq 'name') {
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
        $null = Get-ArtifactResponseProperty -Response $artifact -Name 'archive_download_url'
    }

    return @($selected)
}

function Save-GitHubArtifactArchive {
    # Downloads one archive. A 404 is the only retryable archive result; all other
    # HTTP, extraction and transport failures preserve their final diagnostics.
    param(
        [Parameter(Mandatory)] $Artifact,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $GitHubToken
    )

    $uri = Get-ArtifactResponseProperty -Response $Artifact -Name 'archive_download_url'
    try {
        Invoke-WebRequest -Uri $uri -Headers (Get-ArtifactHeaders -GitHubToken $GitHubToken) `
            -OutFile $Path -TimeoutSec $script:ArchiveTimeoutSeconds -ErrorAction Stop
        return $true
    }
    catch {
        if ((Get-ArtifactHttpStatusCode -ErrorRecord $_) -eq 404) { return $false }
        throw
    }
}

function Get-ArtifactDestination {
    # Exact selectors flatten into their destination, while pattern results retain
    # one artifact-named directory per download.
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] $Artifact,
        [Parameter(Mandatory)] [string] $Selector
    )

    if ($Selector -cne 'pattern') { return $Root }
    $name = [string] (Get-ArtifactResponseProperty -Response $Artifact -Name 'name')
    if ([string]::IsNullOrWhiteSpace($name) -or $name -cin @('.', '..') -or $name -match '[\\/]') {
        throw "Artifact name '$name' cannot be used as a download directory."
    }
    return Join-Path $Root $name
}

function Invoke-ArtifactDownload {
    # Retries selection and archive transfer as one bounded unit. Archives remain
    # in a private staging directory until every selected producer is downloadable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [ValidateRange(1, [long]::MaxValue)] [long] $RunId,
        [Parameter(Mandatory)] [string] $Path,
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
        throw 'Artifact download requires a GitHub token.'
    }

    $selector = @(
        if (-not [string]::IsNullOrWhiteSpace($ArtifactIds)) { 'artifact-ids' }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { 'name' }
        if (-not [string]::IsNullOrWhiteSpace($Pattern)) { 'pattern' }
    )
    if ($selector.Count -ne 1) {
        throw 'Artifact download requires exactly one of artifact-ids, name or pattern.'
    }
    if ($selector[0] -ceq 'pattern' -and $ProducerSteps.Count -eq 0) {
        throw 'Pattern downloads require successful producer upload-step names.'
    }
    if ($selector[0] -cne 'pattern' -and ($ProducerSteps.Count -ne 0 -or $AllowEmpty)) {
        throw 'Producer completeness and empty-result handling apply only to pattern downloads.'
    }

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    $expectedCount = $null
    if ($selector[0] -ceq 'pattern') {
        $expectedCount = Get-ExpectedArtifactCount -ApiUrl $ApiUrl -Repository $Repository `
            -RunId $RunId -ProducerSteps $ProducerSteps -Headers $headers
    }

    $destination = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $downloadRoot = Join-Path $temporaryRoot "crp-artifacts-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null

    try {
        if ($expectedCount -eq 0 -and $AllowEmpty) {
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            return
        }

        for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
            $selected = @(Select-GitHubArtifacts -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId `
                    -GitHubToken $GitHubToken -ArtifactIds $ArtifactIds -Name $Name -Pattern $Pattern)
            $ready = $selected.Count -gt 0
            if ($selector[0] -ceq 'pattern') {
                $ready = $selected.Count -ge $expectedCount -and ($selected.Count -gt 0 -or $expectedCount -eq 0)
            }

            $archives = @()
            if ($ready) {
                $archiveDirectory = Join-Path $downloadRoot 'archives'
                Remove-Item -LiteralPath $archiveDirectory -Recurse -Force -ErrorAction SilentlyContinue
                New-Item -ItemType Directory -Path $archiveDirectory | Out-Null

                foreach ($artifact in $selected) {
                    $id = [long] (Get-ArtifactResponseProperty -Response $artifact -Name 'id')
                    $archivePath = Join-Path $archiveDirectory "$id.zip"
                    if (-not (Save-GitHubArtifactArchive -Artifact $artifact -Path $archivePath `
                                -GitHubToken $GitHubToken)) {
                        $ready = $false
                        break
                    }
                    $archives += @{ artifact = $artifact; path = $archivePath }
                }
            }

            if ($ready) {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                foreach ($archive in $archives) {
                    $target = Get-ArtifactDestination -Root $destination -Artifact $archive.artifact `
                        -Selector $selector[0]
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                    Expand-Archive -LiteralPath $archive.path -DestinationPath $target -Force
                }
                return
            }

            if ($attempt -eq $MaximumAttempts) {
                throw "Selected artifacts were still unavailable for workflow run $RunId " +
                    "after $MaximumAttempts attempts."
            }
            Write-Output "Selected artifacts are not visible yet for workflow run $RunId; retrying."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    finally {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-ArtifactDownload

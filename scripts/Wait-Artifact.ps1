#Requires -Version 7.6

# Waits for one exact ID, name or name pattern to become visible in a workflow run.
# Upload completion can precede artifact-listing consistency, so downloads first
# prove visibility through the same GitHub API that owns artifact lookup.
[CmdletBinding(DefaultParameterSetName = 'Id')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string] $Repository,

    [Parameter(Mandatory)]
    [ValidateRange(1, [long]::MaxValue)]
    [long] $RunId,

    [Parameter(Mandatory, ParameterSetName = 'Id')]
    [ValidatePattern('^[0-9]+$')]
    [string] $ArtifactId,

    [Parameter(Mandatory, ParameterSetName = 'Name')]
    [ValidateNotNullOrEmpty()]
    [string] $Name,

    [Parameter(Mandatory, ParameterSetName = 'Pattern')]
    [ValidateNotNullOrEmpty()]
    [string] $Pattern,

    # The defaults tolerate short upload-to-listing propagation without allowing
    # a producer or API failure to block the workflow indefinitely.
    [ValidateRange(1, 100)]
    [int] $AttemptLimit = 12,

    [ValidateRange(1, 300)]
    [int] $DelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if (-not $env:GITHUB_API_URL -or -not $env:GH_TOKEN) {
    throw 'Artifact visibility checks require GITHUB_API_URL and GH_TOKEN.'
}

$headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:GH_TOKEN"
    'X-GitHub-Api-Version' = '2022-11-28'
}

# A stalled API request remains part of the bounded retry operation rather than
# inheriting Invoke-RestMethod's effectively unbounded wait.
$requestTimeoutSeconds = 30

# Pattern downloads may span several producer artifacts. Requiring an unchanged
# nonempty inventory avoids starting after only the first result becomes visible.
$patternStabilityTarget = 2
$previousPatternCount = $null
$stablePatternObservations = 0

for ($attempt = 1; $attempt -le $AttemptLimit; $attempt++) {
    $visible = $false
    $page = 1
    $seen = 0
    $matchCount = 0

    do {
        $response = Invoke-RestMethod `
            -Uri "$env:GITHUB_API_URL/repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page" `
            -Headers $headers `
            -TimeoutSec $requestTimeoutSeconds
        $artifacts = @($response.artifacts)
        if ($PSCmdlet.ParameterSetName -ceq 'Id') {
            $matchCount += @($artifacts | Where-Object { [string] $_.id -ceq $ArtifactId }).Count
        }
        elseif ($PSCmdlet.ParameterSetName -ceq 'Name') {
            $matchCount += @($artifacts | Where-Object name -CEQ $Name).Count
        }
        else {
            $matchCount += @($artifacts | Where-Object name -CLike $Pattern).Count
        }

        $seen += $artifacts.Count
        $page++
    } while (($PSCmdlet.ParameterSetName -ceq 'Pattern' -or $matchCount -eq 0) -and
        $seen -lt [int] $response.total_count -and $artifacts.Count -gt 0)

    if ($PSCmdlet.ParameterSetName -cne 'Pattern') {
        $visible = $matchCount -gt 0
    }
    elseif ($matchCount -gt 0) {
        if ($null -ne $previousPatternCount -and $matchCount -eq $previousPatternCount) {
            $stablePatternObservations++
        }
        else {
            $stablePatternObservations = 1
            $previousPatternCount = $matchCount
        }

        $visible = $stablePatternObservations -ge $patternStabilityTarget
    }
    else {
        $previousPatternCount = $null
        $stablePatternObservations = 0
    }

    if ($visible) {
        Write-Output 'Artifact is visible to workflow-run downloads.'
        return
    }

    if ($attempt -lt $AttemptLimit) {
        Write-Output "Artifact is not visible yet; retrying after the bounded delay."
        Start-Sleep -Seconds $DelaySeconds
    }
}

$selector = if ($PSCmdlet.ParameterSetName -ceq 'Id') {
    "ID $ArtifactId"
}
elseif ($PSCmdlet.ParameterSetName -ceq 'Name') {
    "name '$Name'"
}
else {
    "pattern '$Pattern'"
}

throw "Artifact with $selector did not become visible in workflow run $RunId before the retry budget was exhausted."

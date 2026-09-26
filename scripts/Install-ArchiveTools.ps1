#Requires -Version 7.6
param([string] $Destination = (Join-Path $env:RUNNER_TEMP 'release-archive-tools'))

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) {
    foreach ($name in @('zip', 'unzip')) {
        $tool = Get-Command $name -CommandType Application -ErrorAction Stop | Select-Object -First 1
        & $tool.Source -v | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Required archive tool $name failed." }
    }
    return
}

$release = Get-Content "$PSScriptRoot/../release.json" -Raw | ConvertFrom-Json
$pin = $release.archive_tools.seven_zip
$executable = Join-Path $Destination '7za.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    $work = Join-Path $env:RUNNER_TEMP "release-7zip-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $archive = Join-Path $work $pin.asset
        Invoke-WebRequest -Uri "https://github.com/ip7z/7zip/releases/download/$($pin.version)/$($pin.asset)" -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha256) {
            throw 'Standalone 7-Zip archive checksum differs from the pinned official asset.'
        }
        # Windows libarchive reads 7z; Git's tar can misread a drive letter as a remote host.
        $tar = Join-Path $env:SystemRoot 'System32/tar.exe'
        & $tar -xf $archive -C $work
        if ($LASTEXITCODE -ne 0) { throw 'Cannot extract the standalone 7-Zip archive.' }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        # Official extra archives supply x64 7za; Windows ARM64 runs it under emulation.
        Copy-Item -LiteralPath (Join-Path $work 'x64/7za.exe') -Destination $executable
        Copy-Item -LiteralPath (Join-Path $work 'License.txt') -Destination (Join-Path $Destination '7zip-license.txt')
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
$identity = & $executable i | Out-String
if ($LASTEXITCODE -ne 0 -or $identity -notmatch "7-Zip.* $([regex]::Escape($pin.version)) ") {
    throw 'Standalone archive tool identity differs from the selected 7-Zip version.'
}
$env:PATH = $Destination + [IO.Path]::PathSeparator + $env:PATH
if ($env:GITHUB_PATH) { $Destination >> $env:GITHUB_PATH }

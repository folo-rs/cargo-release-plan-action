#Requires -Version 7.6

BeforeAll {
    Import-Module "$PSScriptRoot/../scripts/Bootstrap.psm1" -Force
    $script:ReleasePin = (Get-Content "$PSScriptRoot/../release.json" -Raw | ConvertFrom-Json).archive_tools.seven_zip
    $script:OriginalRunnerTemp = $env:RUNNER_TEMP
    $script:OriginalSystemRoot = $env:SystemRoot
    $script:OriginalRunnerArch = $env:RUNNER_ARCH
    $script:OriginalProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE

    function Get-FixtureHash([string] $Contents) {
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Contents))).ToLowerInvariant()
    }
}

AfterAll {
    $env:RUNNER_TEMP = $script:OriginalRunnerTemp
    $env:SystemRoot = $script:OriginalSystemRoot
    $env:RUNNER_ARCH = $script:OriginalRunnerArch
    $env:PROCESSOR_ARCHITECTURE = $script:OriginalProcessorArchitecture
}

Describe 'Standalone archive tool integrity' {
    BeforeEach {
        $env:RUNNER_TEMP = $TestDrive
        $env:SystemRoot = Join-Path $TestDrive 'windows'
        $script:Destination = Join-Path $TestDrive "installed-$([guid]::NewGuid().ToString('N'))"
        $script:Installed = Join-Path $script:Destination '7za.exe'
        $script:ExpectedArchitecture = 'X64'
        $script:Pin = $script:ReleasePin | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        # Controlled bytes exercise real hashing without executing a fixture as a native program.
        $script:ArchiveBytes = 'verified-archive-fixture'
        $script:PayloadBytes = @{ X64 = 'verified-x64-fixture'; Arm64 = 'verified-arm64-fixture' }
        $script:Pin.sha256 = Get-FixtureHash $script:ArchiveBytes
        $script:Pin.payloads.X64.sha256 = Get-FixtureHash $script:PayloadBytes.X64
        $script:Pin.payloads.Arm64.sha256 = Get-FixtureHash $script:PayloadBytes.Arm64
        $script:WrongArchive = $false
        $script:WrongPayload = $false

        Mock Invoke-WebRequest -ModuleName Bootstrap {
            $bytes = if ($script:WrongArchive) { 'wrong archive bytes' } else { $script:ArchiveBytes }
            [IO.File]::WriteAllText($OutFile, $bytes)
        }
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap -ParameterFilter { $Executable -like '*tar.exe' } {
            $archive = $Arguments[1]
            $work = $Arguments[3]
            (Get-FileHash $archive).Hash.ToLowerInvariant() | Should -Be $script:Pin.sha256
            foreach ($architecture in @('X64', 'Arm64')) {
                $path = Join-Path $work $script:Pin.payloads.$architecture.path
                New-Item (Split-Path $path) -ItemType Directory -Force | Out-Null
                $bytes = if ($script:WrongPayload) { 'wrong executable bytes' } else { $script:PayloadBytes[$architecture] }
                [IO.File]::WriteAllText($path, $bytes)
            }
            [IO.File]::WriteAllText((Join-Path $work 'License.txt'), 'fixture license')
        }
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap -ParameterFilter { $Executable -like '*7za.exe' } {
            $Arguments | Should -Be @('i')
            (Get-FileHash $Executable).Hash.ToLowerInvariant() |
                Should -Be $script:Pin.payloads.($script:ExpectedArchitecture).sha256
            "7-Zip $($script:Pin.version) (fixture)"
        }
    }

    It 'selects and verifies the fresh native payload before probing' -ForEach @(
        @{ Architecture = 'X64' }
        @{ Architecture = 'Arm64' }
    ) {
        $script:ExpectedArchitecture = $Architecture
        Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination -Architecture $Architecture
        [IO.File]::ReadAllText($script:Installed) | Should -Be $script:PayloadBytes[$Architecture]
        [IO.File]::ReadAllText((Join-Path $script:Destination '7zip-license.txt')) | Should -Be 'fixture license'
        Should -Invoke Invoke-WebRequest -ModuleName Bootstrap -Times 1 -ParameterFilter {
            $Uri -eq "https://github.com/ip7z/7zip/releases/download/$($script:Pin.version)/$($script:Pin.asset)"
        }
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter { $Executable -like '*7za.exe' }
        @(Get-ChildItem $TestDrive -Directory -Filter 'release-7zip-*').Count | Should -Be 0
    }

    It 'verifies reused payload bytes before probing without downloading' -ForEach @(
        @{ Architecture = 'X64' }
        @{ Architecture = 'Arm64' }
    ) {
        $script:ExpectedArchitecture = $Architecture
        New-Item $script:Destination -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText($script:Installed, $script:PayloadBytes[$Architecture])
        Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination -Architecture $Architecture
        Should -Invoke Invoke-WebRequest -ModuleName Bootstrap -Times 0
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter { $Executable -like '*7za.exe' }
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0 -ParameterFilter { $Executable -like '*tar.exe' }
    }

    It 'rejects a reused payload mismatch without executing even a version probe' -ForEach @(
        @{ Architecture = 'X64' }
        @{ Architecture = 'Arm64' }
    ) {
        New-Item $script:Destination -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText($script:Installed, 'changed same-version executable')
        { Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination -Architecture $Architecture } |
            Should -Throw '*payload checksum differs*'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0
        Should -Invoke Invoke-WebRequest -ModuleName Bootstrap -Times 0
    }

    It 'rejects a fresh extracted payload mismatch before any executable probe' -ForEach @(
        @{ Architecture = 'X64' }
        @{ Architecture = 'Arm64' }
    ) {
        $script:WrongPayload = $true
        { Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination -Architecture $Architecture } |
            Should -Throw '*payload checksum differs*'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 1 -ParameterFilter { $Executable -like '*tar.exe' }
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0 -ParameterFilter { $Executable -like '*7za.exe' }
        @(Get-ChildItem $TestDrive -Directory -Filter 'release-7zip-*').Count | Should -Be 0
    }

    It 'rejects a downloaded archive mismatch before extraction or probing' {
        $script:WrongArchive = $true
        { Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination } |
            Should -Throw '*archive checksum differs*'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0
        Test-Path $script:Installed | Should -BeFalse
        @(Get-ChildItem $TestDrive -Directory -Filter 'release-7zip-*').Count | Should -Be 0
    }

    It 'does not accept one architecture payload as the other' {
        New-Item $script:Destination -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText($script:Installed, $script:PayloadBytes.X64)
        { Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination -Architecture Arm64 } |
            Should -Throw '*payload checksum differs*'
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0
    }

    It 'uses actual process architecture rather than runner or OS environment labels' {
        $script:ExpectedArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        $opposite = if ($script:ExpectedArchitecture -eq 'X64') { 'ARM64' } else { 'X64' }
        $env:RUNNER_ARCH = $opposite
        $env:PROCESSOR_ARCHITECTURE = $opposite
        Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination
        [IO.File]::ReadAllText($script:Installed) | Should -Be $script:PayloadBytes[$script:ExpectedArchitecture]
    }

    It 'rejects unsupported process architectures without downloading or executing' {
        { Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination -Architecture X86 } |
            Should -Throw '*does not support process architecture*'
        Should -Invoke Invoke-WebRequest -ModuleName Bootstrap -Times 0
        Should -Invoke Invoke-BootstrapCommand -ModuleName Bootstrap -Times 0
    }

    It 'still rejects an unexpected version after a payload hash match' {
        Mock Invoke-BootstrapCommand -ModuleName Bootstrap -ParameterFilter { $Executable -like '*7za.exe' } { 'unexpected version' }
        { Install-StandaloneSevenZip -Pin $script:Pin -Destination $script:Destination } |
            Should -Throw '*identity differs*'
    }

    It 'retains the official archive and extracted payload pins' {
        $script:ReleasePin.version | Should -Be '26.03'
        $script:ReleasePin.asset | Should -Be '7z2603-extra.7z'
        $script:ReleasePin.sha256 | Should -Be '191894e6acb3647ffb69ce630479ff318523b2e2b9890aa7f05c1127c2e59b8f'
        $script:ReleasePin.payloads.X64.path | Should -Be 'x64/7za.exe'
        $script:ReleasePin.payloads.X64.sha256 | Should -Be 'edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0'
        $script:ReleasePin.payloads.Arm64.path | Should -Be 'arm64/7za.exe'
        $script:ReleasePin.payloads.Arm64.sha256 | Should -Be 'c26764813a01b9714687f29c94412401f2041852634e291c59d48484432e834b'
    }
}

#Requires -Version 5.1
<#
.SYNOPSIS
Downloads, verifies and installs Relay from its official GitHub releases.
.EXAMPLE
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/g1at/relay-updates/main/install.ps1)))
.EXAMPLE
.\install.ps1 -Version 3.0.0 -DownloadOnly
#>
[CmdletBinding()]
param(
    [ValidatePattern('^v?\d+\.\d+\.\d+$')][string]$Version,
    [switch]$DownloadOnly,
    [switch]$Interactive,
    [string]$DownloadDirectory
)

function Test-RelayEnvironment {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer supports Windows x64 only.'
    }
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') { throw 'A Windows x64 system is required for this release.' }
}

function Assert-RelayClosed {
    if (@(Get-Process -Name Relay -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Relay is running. Exit Relay (including the tray) and run this command again, or use -DownloadOnly.'
    }
}

function Get-RelayInstallations {
    # electron-builder UUID v5 for the stable appId com.relay.app.
    $guid = 'a5c32cb2-ebce-5411-8f64-015aaacf27f0'
    foreach ($scope in @('CurrentUser', 'LocalMachine')) {
        $base = $null; $install = $null; $uninstall = $null
        try {
            $hive = [Microsoft.Win32.RegistryHive]::$scope
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
            $install = $base.OpenSubKey("Software\$guid")
            $uninstall = $base.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Uninstall\$guid")
            if ($install -or $uninstall) {
                $location = ''; $displayVersion = ''
                if ($install) { $location = [string]$install.GetValue('InstallLocation', '') }
                if ($uninstall) { $displayVersion = [string]$uninstall.GetValue('DisplayVersion', '') }
                [pscustomobject]@{ Scope = $scope; Location = $location; Version = $displayVersion }
            }
        } finally {
            if ($uninstall) { $uninstall.Dispose() }
            if ($install) { $install.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }
}

function Assert-RelayInstallScope {
    param([object[]]$Installations, [string]$TargetVersion)
    if (@($Installations).Count -gt 1) {
        throw 'Both per-user and per-machine Relay installations are registered. Use -DownloadOnly and manage them with the installer manually.'
    }
    foreach ($item in $Installations) {
        $installed = $null
        if ([version]::TryParse($item.Version, [ref]$installed) -and $installed -gt [version]$TargetVersion) {
            throw "A newer Relay version ($($item.Version)) is already installed. Automatic downgrade is not supported."
        }
    }
}

function Get-RelayReleaseAsset {
    param([object]$Release, [string]$RequestedVersion)
    if ($Release.draft -or $Release.prerelease) { throw 'Only published stable Relay releases are supported.' }
    if ([string]$Release.tag_name -notmatch '^v?(\d+\.\d+\.\d+)$') { throw 'The release tag is invalid.' }
    $number = $Matches[1]
    if ($RequestedVersion -and $number -ne $RequestedVersion.TrimStart('v')) { throw 'The returned release does not match the requested version.' }
    $name = "Relay-$number-Setup.exe"
    $assets = @($Release.assets | Where-Object { $_.name -ceq $name })
    if ($assets.Count -ne 1) { throw "The release must contain exactly one $name asset." }
    $asset = $assets[0]
    $expectedUrl = "https://github.com/g1at/relay-updates/releases/download/$($Release.tag_name)/$name"
    if ($asset.state -ne 'uploaded' -or [long]$asset.size -le 0 -or $asset.browser_download_url -cne $expectedUrl) {
        throw 'The installer asset is incomplete or its download URL is unexpected.'
    }
    if ([string]$asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw 'GitHub did not provide a SHA-256 digest. The installer will not be executed without verification.'
    }
    [pscustomobject]@{ Version = $number; Name = $name; Url = $expectedUrl; Size = [long]$asset.size; Hash = $Matches[1].ToLowerInvariant() }
}

function Test-RelayDownload {
    param([string]$Path, [object]$Asset)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $Asset.Size) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Asset.Hash
}

function Save-RelayDownload {
    param([object]$Asset, [string]$Directory)
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $target = Join-Path $Directory $Asset.Name
    if (Test-RelayDownload $target $Asset) {
        Write-Host 'Using the verified cached installer.'
        return $target
    }
    $partial = Join-Path $Directory ($Asset.Name + '.' + [guid]::NewGuid().ToString('N') + '.part')
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -UseBasicParsing -Uri $Asset.Url -OutFile $partial -TimeoutSec 600 -ErrorAction Stop
                if (-not (Test-RelayDownload $partial $Asset)) { throw 'The downloaded installer failed size or SHA-256 verification.' }
                Move-Item -LiteralPath $partial -Destination $target -Force
                Write-Host 'SHA-256 verification passed.'
                return $target
            } catch {
                if ($attempt -eq 3) { throw }
                Write-Warning "Download attempt $attempt failed. Retrying..."
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Confirm-RelayInstallation {
    param([string]$ExpectedVersion, [string]$ExpectedScope)
    $items = @(Get-RelayInstallations | Where-Object { $_.Scope -eq $ExpectedScope -and $_.Version -eq $ExpectedVersion })
    if ($items.Count -ne 1 -or -not [IO.Path]::IsPathRooted($items[0].Location)) {
        throw 'The installer exited, but the expected Relay registration was not found. Installation may have been canceled.'
    }
    $exe = Join-Path $items[0].Location 'Relay.exe'
    $archive = Join-Path $items[0].Location 'resources\app.asar'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw 'The installed Relay files are incomplete.'
    }
    $productVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
    if ($productVersion -ne $ExpectedVersion -and $productVersion -ne "$ExpectedVersion.0") {
        throw 'The installed Relay executable version does not match the requested release.'
    }
    return $items[0].Location
}

function Install-Relay {
    [CmdletBinding()]
    param([string]$Version, [switch]$DownloadOnly, [switch]$Interactive, [string]$DownloadDirectory)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        Test-RelayEnvironment
        if (-not $DownloadOnly) { Assert-RelayClosed }
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        $endpoint = 'https://api.github.com/repos/g1at/relay-updates/releases/latest'
        if ($Version) { $endpoint = 'https://api.github.com/repos/g1at/relay-updates/releases/tags/v' + $Version.TrimStart('v') }
        Write-Host 'Checking the official Relay release...'
        $release = Invoke-RestMethod -Uri $endpoint -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Relay-Installer'; 'X-GitHub-Api-Version' = '2022-11-28' } -TimeoutSec 30
        $asset = Get-RelayReleaseAsset $release $Version
        $before = @()
        if (-not $DownloadOnly) {
            $before = @(Get-RelayInstallations)
            Assert-RelayInstallScope $before $asset.Version
        }
        if (-not $DownloadDirectory) { $DownloadDirectory = Join-Path $env:LOCALAPPDATA 'Relay\Installers' }
        $DownloadDirectory = [IO.Path]::GetFullPath($DownloadDirectory)
        Write-Host ("Downloading Relay {0} ({1:N1} MiB)..." -f $asset.Version, ($asset.Size / 1MB))
        $installer = Save-RelayDownload $asset $DownloadDirectory
        if ($DownloadOnly) { Write-Host "Download complete: $installer"; return $installer }
        Assert-RelayClosed
        $before = @(Get-RelayInstallations)
        Assert-RelayInstallScope $before $asset.Version
        # Recheck the exact file just before execution, including cached files.
        if (-not (Test-RelayDownload $installer $asset)) { throw 'Installer verification changed before execution.' }
        $scope = 'CurrentUser'
        if ($before.Count -eq 1) { $scope = $before[0].Scope }
        Write-Host 'Installing Relay. An existing machine-wide installation may require UAC approval...'
        $start = @{ FilePath = $installer; Wait = $true; PassThru = $true }
        if (-not $Interactive) { $start.ArgumentList = @('/S') }
        $process = Start-Process @start
        if ($process.ExitCode -ne 0) { throw "The Relay installer failed or was canceled (exit code $($process.ExitCode))." }
        $location = Confirm-RelayInstallation $asset.Version $scope
        Write-Host "Relay $($asset.Version) is installed at $location. Open Relay from the Start menu."
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
    }
}

Install-Relay @PSBoundParameters

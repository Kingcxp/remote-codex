[CmdletBinding()]
param(
    [string]$InstallPath,
    [switch]$SkipDependencyInstall
)

$previousRemoteCodexErrorAction = $ErrorActionPreference
$previousRemoteCodexProgressPreference = $ProgressPreference
try {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repository = 'Kingcxp/remote-codex'
$branch = 'main'
$minimumNodeVersion = [version]'22.12.0'
$repositoryApi = "https://api.github.com/repos/$repository"

function Refresh-UserPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Get-TailscaleCli {
    $command = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}

function Install-WingetPackage([string]$PackageId, [string]$DisplayName, [string]$DownloadUrl) {
    if ($SkipDependencyInstall) {
        throw "$DisplayName is missing. Install it from $DownloadUrl, then run Install.ps1 again."
    }
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host "winget is unavailable. Opening the official $DisplayName download page."
        Start-Process $DownloadUrl
        $null = Read-Host 'Install it, reopen PowerShell, then press Enter to continue'
        Refresh-UserPath
        return
    }
    Write-Host "The next step installs $DisplayName from the official winget source. Review and approve the installer if Windows prompts."
    $answer = (Read-Host 'Continue with installation? [Y/n]').Trim()
    if ($answer -match '^(n|no)$') {
        Start-Process $DownloadUrl
        $null = Read-Host 'Install it, reopen PowerShell, then press Enter to continue'
    } else {
        & $winget.Source install --exact --id $PackageId --source winget --accept-source-agreements --accept-package-agreements --interactive
        if ($LASTEXITCODE -ne 0) { throw "winget could not install $DisplayName (exit $LASTEXITCODE). Complete installation manually and rerun this script." }
    }
    Refresh-UserPath
}

Write-Host 'Remote Codex installer' -ForegroundColor Cyan
Write-Host 'This installs a local Windows bridge for the Codex desktop app. It does not ask for or upload model API credentials.'
Write-Host 'Tailscale installs a virtual network adapter and system service. Windows may request administrator approval for that package.'

if (-not (Get-TailscaleCli)) {
    Install-WingetPackage 'Tailscale.Tailscale' 'Tailscale' 'https://tailscale.com/download/windows'
}
$tailscalePath = Get-TailscaleCli
if (-not $tailscalePath) { throw 'Tailscale CLI was not found after installation. Reopen PowerShell and run Install.ps1 again.' }

$node = Get-Command node.exe -ErrorAction SilentlyContinue
$nodeVersion = $null
if ($node) {
    try { $nodeVersion = [version]((& $node.Source -p 'process.versions.node').Trim()) } catch { $nodeVersion = $null }
}
if (-not $nodeVersion -or $nodeVersion -lt $minimumNodeVersion) {
    Install-WingetPackage 'OpenJS.NodeJS.LTS' 'Node.js LTS' 'https://nodejs.org/en/download'
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Node.js was installed but is not visible in this PowerShell session. Reopen PowerShell and run Install.ps1 again.' }
    try { $nodeVersion = [version]((& $node.Source -p 'process.versions.node').Trim()) } catch { throw 'Could not read the installed Node.js version.' }
}
if ($nodeVersion -lt $minimumNodeVersion) { throw "Node.js $minimumNodeVersion or later is required; found $nodeVersion." }

$tailStatus = $null
try { $tailStatus = (& $tailscalePath status --json | ConvertFrom-Json) } catch { }
if (-not $tailStatus -or $tailStatus.BackendState -ne 'Running') {
    Write-Host 'Sign in to the private tailnet you will use on the Android/Linux clients.' -ForegroundColor Yellow
    Write-Host 'If Tailscale is not signed in yet, open its tray app and finish the browser login.'
    $null = Read-Host 'Press Enter after Tailscale shows Connected'
    try { $tailStatus = (& $tailscalePath status --json | ConvertFrom-Json) } catch { }
    if (-not $tailStatus -or $tailStatus.BackendState -ne 'Running') {
        throw 'Tailscale is not connected. Sign in from its Windows tray app and run Install.ps1 again.'
    }
}

if (-not $InstallPath) {
    $defaultPath = Join-Path $env:USERPROFILE 'Remote-Codex'
    $enteredPath = (Read-Host "Install folder [$defaultPath]").Trim().Trim('"')
    $InstallPath = if ($enteredPath) { $enteredPath } else { $defaultPath }
}
$InstallPath = [IO.Path]::GetFullPath($InstallPath)
if ($InstallPath -eq [IO.Path]::GetPathRoot($InstallPath)) { throw 'Choose a new folder below the drive root.' }

$existingSetup = Join-Path $InstallPath 'Setup.ps1'
if (Test-Path -LiteralPath $existingSetup -PathType Leaf) {
    Write-Host "An installation already exists at $InstallPath. No files will be overwritten."
    $null = Read-Host 'Press Enter to open its setup menu, or Ctrl+C to cancel'
    . $existingSetup
    return
}
if (Test-Path -LiteralPath $InstallPath) {
    if (@(Get-ChildItem -LiteralPath $InstallPath -Force).Count -gt 0) {
        throw "The destination folder is not empty and is not a Remote Codex installation: $InstallPath"
    }
} else {
    [void](New-Item -ItemType Directory -Path $InstallPath -Force)
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$temporaryRoot = Join-Path $env:TEMP ('remote-codex-install-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporaryRoot)
try {
    $release = Invoke-RestMethod -Uri ($repositoryApi + '/releases/latest') -Headers @{
        Accept='application/vnd.github+json'; 'X-GitHub-Api-Version'='2022-11-28'; 'User-Agent'='Remote-Codex-Installer'
    }
    if ($release.tag_name -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'The latest GitHub release tag is invalid.' }
    $archiveName = "Remote-Codex-$($release.tag_name).zip"
    $archiveAsset = @($release.assets | Where-Object name -eq $archiveName | Select-Object -First 1)[0]
    $checksumAsset = @($release.assets | Where-Object name -eq ($archiveName + '.sha256') | Select-Object -First 1)[0]
    if (-not $archiveAsset -or -not $checksumAsset) { throw 'The latest release does not include its deployment archive and SHA-256 file.' }
    $archive = Join-Path $temporaryRoot $archiveName
    $checksum = Join-Path $temporaryRoot ($archiveName + '.sha256')
    $expanded = Join-Path $temporaryRoot 'expanded'
    Write-Host "Downloading verified deployment archive $($release.tag_name) from GitHub..."
    Invoke-WebRequest -Uri $archiveAsset.browser_download_url -OutFile $archive -UseBasicParsing
    Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $checksum -UseBasicParsing
    $checksumLine = (Get-Content -LiteralPath $checksum -Raw).Trim()
    if ($checksumLine -notmatch ('^(?<hash>[a-fA-F0-9]{64})\s+' + [regex]::Escape($archiveName) + '$')) {
        throw 'The release checksum file is malformed.'
    }
    $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actualHash -ine $Matches.hash) { throw 'The downloaded deployment archive failed its SHA-256 check.' }
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force
    $package = Join-Path $expanded 'Remote-Codex'
    if (-not (Test-Path -LiteralPath (Join-Path $package 'Setup.ps1')) -or
        -not (Test-Path -LiteralPath (Join-Path $package 'runtime\app\build\server\server.js')) -or
        -not (Test-Path -LiteralPath (Join-Path $package 'runtime\app\dist\index.html'))) {
        throw 'The downloaded package is incomplete. No setup script was started.'
    }
    foreach ($item in Get-ChildItem -LiteralPath $package -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $InstallPath -Recurse
    }
} catch {
    if (@(Get-ChildItem -LiteralPath $InstallPath -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $InstallPath -Force -ErrorAction SilentlyContinue
    }
    throw
} finally {
    $resolvedTemporary = (Resolve-Path -LiteralPath $temporaryRoot).Path
    $resolvedTempRoot = (Resolve-Path -LiteralPath $env:TEMP).Path.TrimEnd('\') + '\'
    if ($resolvedTemporary.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
    }
}

Write-Host "Downloaded the package to $InstallPath. The normal-user setup wizard will start next." -ForegroundColor Green
. (Join-Path $InstallPath 'Setup.ps1')
} finally {
    $ErrorActionPreference = $previousRemoteCodexErrorAction
    $ProgressPreference = $previousRemoteCodexProgressPreference
}

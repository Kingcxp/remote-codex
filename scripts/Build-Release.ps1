[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$top = (& $git.Source -C $repositoryRoot rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($top) -ne [IO.Path]::GetFullPath($repositoryRoot)) {
    throw 'Run the release builder from a Git checkout of Remote Codex.'
}
$trackedFiles = @(& $git.Source -C $repositoryRoot ls-files)
if ($LASTEXITCODE -ne 0 -or -not $trackedFiles.Count) { throw 'Commit the release sources before building an archive.' }

$forbidden = @($trackedFiles | Where-Object {
    ($_ -match '(^|/)(state|node_modules|releases)/') -or
    ($_ -match '(^|/)(\.env|.*\.(pub|log))$') -or
    ($_ -match '^config/(existing-project-roots\.json|.*generated.*\.json|.*private.*)$') -or
    ($_ -match '^docs/(BUILD-INFO\.json|VALIDATION\.json|LOCAL-CHANGES\.patch)$')
})
if ($forbidden.Count) { throw ('Private or generated paths are tracked: ' + ($forbidden -join ', ')) }

foreach ($required in @(
    'Install.ps1', 'Setup.ps1', 'Start.ps1', 'LICENSE',
    'runtime/app/build/server/server.js', 'runtime/app/dist/index.html',
    'runtime/app/src/server/server.ts', 'docs/BUILD-INFO.template.json'
)) {
    if ($required -notin $trackedFiles -or -not (Test-Path -LiteralPath (Join-Path $repositoryRoot $required))) {
        throw "Required release file is missing: $required"
    }
}

$version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'VERSION must be a semantic version.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repositoryRoot 'releases' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$archivePath = Join-Path $OutputDirectory "Remote-Codex-v$version.zip"
$checksumPath = $archivePath + '.sha256'
if ((Test-Path -LiteralPath $archivePath) -and -not $Force) { throw "Release archive already exists. Use -Force to replace it: $archivePath" }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$temporaryPath = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N') + '.zip')
$archive = [IO.Compression.ZipFile]::Open($temporaryPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in ($trackedFiles | Sort-Object)) {
        $source = Join-Path $repositoryRoot $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Tracked release file is missing: $relative" }
        $entry = 'Remote-Codex/' + $relative.Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $source, $entry, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose() }

try {
    $archive = [IO.Compression.ZipFile]::OpenRead($temporaryPath)
    try {
        $names = @($archive.Entries | ForEach-Object FullName)
        foreach ($required in @('Remote-Codex/Setup.ps1','Remote-Codex/runtime/app/build/server/server.js','Remote-Codex/runtime/app/dist/index.html')) {
            if ($required -notin $names) { throw "Release archive is missing $required" }
        }
        if (@($names | Where-Object { $_ -match '(^|/)(state|node_modules|releases)/|\.pub$|(^|/)secrets\.dpapi$' }).Count) {
            throw 'The release archive contains private state or dependency caches.'
        }
    } finally { $archive.Dispose() }
    Move-Item -LiteralPath $temporaryPath -Destination $archivePath -Force
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, "$hash  $(Split-Path -Leaf $archivePath)`n", [Text.UTF8Encoding]::new($false))
} catch {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    throw
}

[pscustomobject]@{ Version=$version; Archive=$archivePath; SHA256=$hash; Files=$trackedFiles.Count } | ConvertTo-Json -Compress

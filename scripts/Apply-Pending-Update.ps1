[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$bundleRoot = Split-Path -Parent $PSScriptRoot
function Assert-BundlePath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if ($absolute -ne $bundleRoot -and -not $absolute.StartsWith($bundleRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Update path leaves this bundle.' }
    $ancestor = $absolute
    while ($ancestor -and ($ancestor -eq $bundleRoot -or $ancestor.StartsWith($bundleRoot + '\',[StringComparison]::OrdinalIgnoreCase))) {
        if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Update paths must not use directory links.' }
        if ($ancestor -eq $bundleRoot) { break }
        $ancestor = Split-Path -Parent $ancestor
    }
}
$pendingRoot = Join-Path $bundleRoot 'runtime\update'
$manifestPath = Join-Path $pendingRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { return }
foreach ($path in @($pendingRoot,(Join-Path $bundleRoot 'runtime\app'),(Join-Path $bundleRoot 'docs'),(Join-Path $bundleRoot 'state\update-backups'))) { Assert-BundlePath $path }
if ((Get-Item -LiteralPath $pendingRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update directory must be a regular directory.' }
$processPath = Join-Path $bundleRoot 'state\process.json'
if (Test-Path -LiteralPath $processPath) {
    $record = Get-Content -LiteralPath $processPath -Raw | ConvertFrom-Json
    $runtime = Join-Path $bundleRoot 'runtime\local-runtime.mjs'
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$record.pid)" -ErrorAction SilentlyContinue
    if ($process -and $process.CommandLine -and $process.CommandLine.IndexOf($runtime,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Stop the running bridge before applying the update.' }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (-not $manifest.sha256 -or @($manifest.sha256.PSObject.Properties).Count -eq 0) { throw 'Update manifest is empty.' }
$validationKey = if ($manifest.validationKey) { [string]$manifest.validationKey } else { 'remoteMessageQueue' }
if ($validationKey -notin @('remoteMessageQueue','remoteWorkspaceUpgrade')) { throw 'Invalid update validation section.' }
foreach ($entry in $manifest.sha256.PSObject.Properties) {
    if ($entry.Name -notmatch '^(build|dist)/[a-zA-Z0-9_./-]+$' -or $entry.Name -match '(^|/)\.\.(/|$)') { throw 'Invalid update path.' }
    $file = Join-Path $pendingRoot $entry.Name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ('Missing update file: ' + $entry.Name) }
    if ((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $entry.Value) { throw ('Update integrity check failed: ' + $entry.Name) }
}
foreach ($required in @('build/connector/message-queue.js','build/connector/index.js','build/server/server.js','dist/index.html')) {
    if (-not $manifest.sha256.PSObject.Properties[$required]) { throw ('Required update file is missing: ' + $required) }
}
foreach ($name in @('build','dist')) {
    $stagedDirectory = Join-Path $pendingRoot $name
    if ((Get-Item -LiteralPath $stagedDirectory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Staged application directory must be a regular directory.' }
    foreach ($item in Get-ChildItem -LiteralPath $stagedDirectory -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Update must not contain directory links.' }
        if ($item.PSIsContainer) { continue }
        $relative = $item.FullName.Substring($pendingRoot.Length + 1).Replace('\','/')
        if (-not $manifest.sha256.PSObject.Properties[$relative]) { throw ('Unrecorded update file: ' + $relative) }
    }
}
$backupRoot = Join-Path $bundleRoot ('state\update-backups\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$appRoot = Join-Path $bundleRoot 'runtime\app'
$validationPath = Join-Path $bundleRoot 'docs\VALIDATION.json'
$metadataPath = Join-Path $bundleRoot 'docs\BUILD-INFO.json'
$previousValidation = [IO.File]::ReadAllBytes($validationPath)
$previousMetadata = [IO.File]::ReadAllBytes($metadataPath)
$swapped = @()
$manifestMoved = $false
try {
    foreach ($name in @('build','dist')) {
        $installed = Join-Path $appRoot $name
        $staged = Join-Path $pendingRoot $name
        foreach ($path in @($installed,$staged,(Join-Path $backupRoot $name))) { Assert-BundlePath $path }
        if ((Get-Item -LiteralPath $installed).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installed application directory must be a regular directory.' }
        Move-Item -LiteralPath $installed -Destination (Join-Path $backupRoot $name)
        try { Move-Item -LiteralPath $staged -Destination $installed }
        catch { Move-Item -LiteralPath (Join-Path $backupRoot $name) -Destination $installed; throw }
        $swapped += $name
    }
    $validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
    if (-not $validation.PSObject.Properties[$validationKey]) { $validation | Add-Member -NotePropertyName $validationKey -NotePropertyValue ([pscustomobject]@{}) }
    $section = $validation.PSObject.Properties[$validationKey].Value
    $section | Add-Member -NotePropertyName status -NotePropertyValue 'installed; physical Android/Arch confirmation pending' -Force
    $section | Add-Member -NotePropertyName installedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($validationPath,($validation | ConvertTo-Json -Depth 20) + "`n",[Text.UTF8Encoding]::new($false))
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $hashes = [ordered]@{}
    foreach ($entry in $metadata.sha256.PSObject.Properties) {
        if ($entry.Name.StartsWith('runtime/app/build/') -or $entry.Name.StartsWith('runtime/app/dist/') -or $entry.Name.StartsWith('runtime/update/')) { continue }
        $hashes[$entry.Name] = (Get-FileHash -LiteralPath (Join-Path $bundleRoot $entry.Name)).Hash.ToLowerInvariant()
    }
    foreach ($entry in $manifest.sha256.PSObject.Properties) { $hashes['runtime/app/' + $entry.Name] = $entry.Value }
    $metadata.sha256 = $hashes
    $metadata | Add-Member -NotePropertyName updatedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($metadataPath,($metadata | ConvertTo-Json -Depth 20) + "`n",[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $manifestPath -Destination (Join-Path $backupRoot 'applied-manifest.json')
    $manifestMoved = $true
    # Both build directories were moved within this bundle. No recursive deletion.
    if (@(Get-ChildItem -LiteralPath $pendingRoot -Force).Count -eq 0) { Remove-Item -LiteralPath $pendingRoot }
    Write-Host 'Remote workspace update installed. Reload the remote webpage after the bridge starts.'
    Write-Host ('Previous build saved at ' + $backupRoot)
} catch {
    if ($manifestMoved) {
        New-Item -ItemType Directory -Path $pendingRoot -Force | Out-Null
        Move-Item -LiteralPath (Join-Path $backupRoot 'applied-manifest.json') -Destination $manifestPath
    }
    foreach ($name in $swapped) {
        $installed = Join-Path $appRoot $name
        Move-Item -LiteralPath $installed -Destination (Join-Path $pendingRoot $name)
        Move-Item -LiteralPath (Join-Path $backupRoot $name) -Destination $installed
    }
    [IO.File]::WriteAllBytes($validationPath,$previousValidation)
    [IO.File]::WriteAllBytes($metadataPath,$previousMetadata)
    throw
}

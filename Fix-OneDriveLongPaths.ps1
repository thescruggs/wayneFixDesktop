<#
.SYNOPSIS
    Finds files on the current user's Desktop whose OneDrive path + file name
    exceed OneDrive's maximum length, lists them, and shortens the file names
    after the user approves.

.DESCRIPTION
    OneDrive / SharePoint limit the whole decoded path (folders + file name,
    everything after the site host name) to 400 characters. For a work/school
    account that path starts with "personal/<user>/Documents/", which this
    script reads from the OneDrive registry settings so the count matches what
    OneDrive actually sees.

    Only file names are shortened (the extension is kept). Folders are never
    renamed. Files that sit in a folder path so deep that no reasonable file
    name would fit are reported separately and left alone.

    A CSV log of every rename (old path, new path) is written so changes can
    be reviewed or undone.

.PARAMETER MaxLength
    Maximum allowed path length. Default 400 (OneDrive / SharePoint Online).

.PARAMETER Path
    Folder to scan. Defaults to the current user's Desktop (follows OneDrive
    Known Folder Move redirection automatically).

.PARAMETER MinBaseLength
    Shortest file name (without extension) the script is allowed to produce.

.PARAMETER ReportOnly
    List the offending files and proposed names, then exit without prompting.

.EXAMPLE
    .\Fix-OneDriveLongPaths.ps1

.EXAMPLE
    .\Fix-OneDriveLongPaths.ps1 -ReportOnly
#>
[CmdletBinding()]
param(
    [int]$MaxLength = 400,
    [string]$Path,
    [int]$MinBaseLength = 8,
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'

# --- 1. Locate the Desktop ---------------------------------------------------
if (-not $Path) { $Path = [Environment]::GetFolderPath('Desktop') }
if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Could not find the folder to scan: '$Path'"
}
$root = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')

# --- 2. Work out how OneDrive sees that folder --------------------------------
# Find the OneDrive account whose sync folder contains the Desktop.
$oneDriveRoot = $null
$serverPrefix = ''          # e.g. "personal/user_contoso_com/Documents/"
$accountLabel = $null

$accountsKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
if (Test-Path $accountsKey) {
    foreach ($key in Get-ChildItem $accountsKey) {
        $acct = Get-ItemProperty -Path $key.PSPath
        if (-not $acct.UserFolder) { continue }
        $folder = $acct.UserFolder.TrimEnd('\')
        if ($root -eq $folder -or $root.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $oneDriveRoot = $folder
            $accountLabel = $key.PSChildName
            if ($acct.ServiceEndpointUri) {
                # https://tenant-my.sharepoint.com/personal/user_contoso_com/_api
                try {
                    $sitePath = ([Uri]$acct.ServiceEndpointUri).AbsolutePath
                    $sitePath = [Uri]::UnescapeDataString($sitePath) -replace '/_api/?$', ''
                    $serverPrefix = $sitePath.Trim('/') + '/Documents/'
                } catch { }
            }
            break
        }
    }
}

# Fall back to the environment variables if the registry gave us nothing.
if (-not $oneDriveRoot) {
    foreach ($candidate in @($env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer)) {
        if (-not $candidate) { continue }
        $folder = $candidate.TrimEnd('\')
        if ($root -eq $folder -or $root.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $oneDriveRoot = $folder
            break
        }
    }
}

if ($oneDriveRoot) {
    $rootRelative = $root.Substring($oneDriveRoot.Length).TrimStart('\')   # e.g. "Desktop"
} else {
    # Desktop is not synced by OneDrive (yet). Measure it as if it were backed
    # up to the top of OneDrive under its own folder name.
    $rootRelative = Split-Path -Leaf $root
}

$serverRoot = $serverPrefix + ($rootRelative -replace '\\', '/')   # no trailing slash

Write-Host ''
Write-Host "Scanning : $root"
if ($oneDriveRoot) {
    Write-Host "OneDrive : $oneDriveRoot $(if ($accountLabel) { "($accountLabel)" })"
} else {
    Write-Host 'OneDrive : this folder is NOT inside a OneDrive sync folder - lengths are an estimate' -ForegroundColor Yellow
}
Write-Host "Measured as : /$serverRoot/<folders>/<file>   (limit $MaxLength characters)"
Write-Host ''

# --- 3. Scan -----------------------------------------------------------------
# The \\?\ prefix lets Windows PowerShell 5.1 read paths longer than 260 chars.
$lp = '\\?\'
if ($root.StartsWith('\\')) { $lp = '' }      # UNC-redirected desktop: no prefix

$scanErrors = @()
$files = Get-ChildItem -LiteralPath ($lp + $root) -File -Recurse -Force `
            -ErrorAction SilentlyContinue -ErrorVariable +scanErrors

$taken   = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$fixable = New-Object System.Collections.Generic.List[object]
$stuck   = New-Object System.Collections.Generic.List[object]
$total   = 0

foreach ($f in $files) {
    $total++
    $full = $f.FullName
    if ($lp -and $full.StartsWith($lp)) { $full = $full.Substring($lp.Length) }

    $rel       = $full.Substring($root.Length).TrimStart('\')          # folders\file.ext
    $serverLen = $serverRoot.Length + 1 + $rel.Length
    if ($serverLen -le $MaxLength) { continue }

    $dir     = Split-Path -Parent $full
    $ext     = $f.Extension
    $base    = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    # Characters available for the file name once the folder path is counted.
    $allowed = $MaxLength - ($serverLen - $f.Name.Length)
    $maxBase = $allowed - $ext.Length

    $newName = $null
    if ($maxBase -ge $MinBaseLength) {
        $n = 0
        do {
            $suffix = ''
            if ($n -gt 0) { $suffix = "~$n" }
            $keep    = [Math]::Min($base.Length, $maxBase - $suffix.Length)
            $newName = $base.Substring(0, $keep).TrimEnd(' ', '.') + $suffix + $ext
            $target  = Join-Path $dir $newName
            $clash   = $taken.Contains($target) -or
                       [IO.File]::Exists($lp + $target) -or
                       [IO.Directory]::Exists($lp + $target)
            $n++
        } while ($clash -and $n -lt 1000)
        if ($clash) { $newName = $null }
    }

    $entry = [pscustomobject]@{
        Length   = $serverLen
        Over     = $serverLen - $MaxLength
        FullPath = $full
        Relative = $rel
        Folder   = $dir
        OldName  = $f.Name
        NewName  = $newName
    }

    if ($newName) {
        [void]$taken.Add((Join-Path $dir $newName))
        $fixable.Add($entry)
    } else {
        $stuck.Add($entry)
    }
}

foreach ($e in $scanErrors) { Write-Warning "Could not read: $($e.TargetObject)" }

# --- 4. Report ---------------------------------------------------------------
Write-Host "Checked $total files."

if ($fixable.Count -eq 0 -and $stuck.Count -eq 0) {
    Write-Host "No files exceed the $MaxLength character limit. Nothing to do." -ForegroundColor Green
    return
}

if ($fixable.Count -gt 0) {
    Write-Host ''
    Write-Host "$($fixable.Count) file(s) are too long and can be fixed by shortening the file name:" -ForegroundColor Yellow
    $i = 0
    foreach ($e in ($fixable | Sort-Object Length -Descending)) {
        $i++
        Write-Host ''
        Write-Host ("{0}. {1} characters ({2} over)" -f $i, $e.Length, $e.Over) -ForegroundColor Yellow
        Write-Host "   Folder  : $($e.Folder)"
        Write-Host "   Current : $($e.OldName)"
        Write-Host "   New     : $($e.NewName)" -ForegroundColor Cyan
    }
}

if ($stuck.Count -gt 0) {
    Write-Host ''
    Write-Host "$($stuck.Count) file(s) CANNOT be fixed by renaming the file - the folders above them are too long." -ForegroundColor Red
    Write-Host 'Shorten or move the folders by hand:' -ForegroundColor Red
    foreach ($e in ($stuck | Sort-Object Length -Descending)) {
        Write-Host ("   [{0} chars, {1} over] {2}" -f $e.Length, $e.Over, $e.FullPath)
    }
}

if ($ReportOnly -or $fixable.Count -eq 0) { return }

# --- 5. Approve --------------------------------------------------------------
Write-Host ''
$answer = Read-Host "Rename these $($fixable.Count) file(s) as shown above? Type Y to proceed, anything else to cancel"
if ($answer -notmatch '^\s*y(es)?\s*$') {
    Write-Host 'Cancelled. No files were changed.'
    return
}

# --- 6. Rename ---------------------------------------------------------------
$logPath = Join-Path $env:USERPROFILE ("OneDriveLongPathFix_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
$log     = New-Object System.Collections.Generic.List[object]
$ok = 0; $failed = 0

foreach ($e in $fixable) {
    $status = 'Renamed'; $message = ''
    try {
        Rename-Item -LiteralPath ($lp + $e.FullPath) -NewName $e.NewName -ErrorAction Stop
        $ok++
    } catch {
        $status = 'FAILED'; $message = $_.Exception.Message
        $failed++
        Write-Warning "Could not rename '$($e.FullPath)': $message"
    }
    $log.Add([pscustomobject]@{
        Status  = $status
        OldPath = $e.FullPath
        NewPath = (Join-Path $e.Folder $e.NewName)
        Error   = $message
    })
}

$log | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "Renamed $ok file(s)." -ForegroundColor Green
if ($failed -gt 0) { Write-Host "$failed file(s) could not be renamed (open in another program?)." -ForegroundColor Red }
Write-Host "Log of changes: $logPath"

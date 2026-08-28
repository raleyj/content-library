[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = 'E:\',

    [Parameter(Position = 1)]
    [string]$DestinationRoot = 'E:\ContentLibrary',

    [ValidateSet('iso', 'ova')]
    [string[]]$Extensions = @('iso', 'ova')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-SafeFolderName {
    param([Parameter(Mandatory)][string]$Name)

    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $escapedCharacters = [regex]::Escape((-join $invalidCharacters))
    $safeName = $Name -replace "[$escapedCharacters]", '_'
    $safeName = $safeName.Trim().TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($safeName)) {
        throw "The filename '$Name' does not produce a valid folder name."
    }

    return $safeName
}

$resolvedSource = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
    throw "Source path '$resolvedSource' is not a directory."
}

if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
    $resolvedDestination = $resolvedSource
}
else {
    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($DestinationRoot, 'Create destination root directory')) {
            New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
        }
    }

    if (Test-Path -LiteralPath $DestinationRoot -PathType Container) {
        $resolvedDestination = (Resolve-Path -LiteralPath $DestinationRoot).Path
    }
    else {
        # With -WhatIf, the destination is intentionally not created.
        $resolvedDestination = [System.IO.Path]::GetFullPath($DestinationRoot)
    }
}

$normalizedExtensions = $Extensions | ForEach-Object { "." + $_.TrimStart('.').ToLowerInvariant() }
$sourceFiles = Get-ChildItem -LiteralPath $resolvedSource -File |
    Where-Object { $normalizedExtensions -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object Name

if (-not $sourceFiles) {
    Write-Warning "No matching ISO or OVA files were found directly in '$resolvedSource'."
    return
}

$results = foreach ($file in $sourceFiles) {
    $folderName = Get-SafeFolderName -Name $file.BaseName
    $itemDirectory = Join-Path $resolvedDestination $folderName
    $destinationFile = Join-Path $itemDirectory $file.Name

    if (Test-Path -LiteralPath $destinationFile) {
        Write-Warning "Skipped '$($file.FullName)' because '$destinationFile' already exists."
        [pscustomobject]@{
            Source      = $file.FullName
            ItemFolder  = $itemDirectory
            Destination = $destinationFile
            Status      = 'Skipped - destination exists'
        }
        continue
    }

    if ($PSCmdlet.ShouldProcess($itemDirectory, "Create item directory for '$($file.Name)'")) {
        New-Item -ItemType Directory -Path $itemDirectory -Force | Out-Null
    }

    if ($PSCmdlet.ShouldProcess($file.FullName, "Move to '$destinationFile'")) {
        Move-Item -LiteralPath $file.FullName -Destination $destinationFile
        $status = 'Moved'
    }
    else {
        $status = 'WhatIf'
    }

    [pscustomobject]@{
        Source      = $file.FullName
        ItemFolder  = $itemDirectory
        Destination = $destinationFile
        Status      = $status
    }
}

$results

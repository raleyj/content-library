#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceRoot = 'E:\',
    [string]$ContentRoot = 'E:\ContentLibrary',
    [string]$AppPoolName = 'vCenter-Content-Library'
)
$ErrorActionPreference = 'Stop'
$source = Get-Item -LiteralPath $SourceRoot
$destination = Get-Item -LiteralPath $ContentRoot
if (-not $source.PSIsContainer -or -not $destination.PSIsContainer -or $source.FullName.TrimEnd('\') -eq $destination.FullName.TrimEnd('\')) { throw 'Source and destination must be different existing directories.' }
if (($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($destination.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Source/destination links are not supported.' }
$files = @(Get-ChildItem -LiteralPath $source.FullName -File | Where-Object { $_.Extension -in '.iso','.ova' })
foreach ($file in $files) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "File links are not supported: $file" }
    $folder = Join-Path $destination.FullName $file.BaseName
    if (($files | Where-Object { $_.BaseName -eq $file.BaseName }).Count -gt 1 -or (Test-Path -LiteralPath $folder)) {
        Write-Warning "Skipping collision/existing folder: $($file.Name)"
        continue
    }
    if ($PSCmdlet.ShouldProcess($file.FullName, "Move to $folder and grant the IIS pool read access")) {
        # Refuse a file held open by a copier. The caller must still ensure copying is complete.
        $handle = [IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
        $handle.Dispose()
        New-Item -ItemType Directory -Path $folder | Out-Null
        $target = Join-Path $folder ($file.BaseName + $file.Extension.ToLowerInvariant())
        Move-Item -LiteralPath $file.FullName -Destination $target -ErrorAction Stop
        # Same-volume moves can preserve the source ACL. Explicitly allow IIS reads.
        $acl = Get-Acl -LiteralPath $target
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("IIS AppPool\$AppPoolName", 'ReadAndExecute', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')), 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $target -AclObject $acl
        Write-Output $target
    }
}

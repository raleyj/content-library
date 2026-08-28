#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$mutex = New-Object System.Threading.Mutex($false, 'Global\VCSPCatalogPublisher')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Another catalog generation is running.' }
    $root = Get-Item -LiteralPath $config.ContentRoot
    if (-not $root.PSIsContainer) { throw 'ContentRoot is not a directory.' }
    foreach ($folder in Get-ChildItem -LiteralPath $root.FullName -Directory -Force) {
        if ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Links are not supported: $folder" }
        $children = @(Get-ChildItem -LiteralPath $folder.FullName -Force)
        if (@($children | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) {
            throw "Nested directories or links are not supported: $folder"
        }
        if (-not @($children | Where-Object { $_.Name -ne 'item.json' }).Count) { throw "Empty item folder: $folder" }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $outLog = Join-Path $config.LogDirectory "$stamp.stdout.log"
    $errLog = Join-Path $config.LogDirectory "$stamp.stderr.log"
    # All arguments are quoted; reject embedded quotes and avoid trailing backslashes.
    $arguments = @($config.Generator, '--name', $config.LibraryName, '--type', 'local', '--path', $root.FullName.TrimEnd('\'), '--etag', 'true')
    foreach ($argument in $arguments) {
        if ($argument -match '["\r\n]' -or $argument.EndsWith('\')) { throw 'Unsupported quote, newline or trailing slash in argument.' }
    }
    $commandLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $process = Start-Process -FilePath $config.Python -ArgumentList $commandLine -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    if ($process.ExitCode -ne 0) { throw "Generator failed: exit $($process.ExitCode). See $errLog" }
    foreach ($name in 'lib.json', 'items.json') {
        Get-Content -LiteralPath (Join-Path $root.FullName $name) -Raw | ConvertFrom-Json | Out-Null
    }
    Write-Output "Catalog generated. Logs: $outLog ; $errLog"
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

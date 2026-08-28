#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LibraryName,
    [Parameter(Mandatory)][string]$PythonPath,
    [string]$ContentRoot = 'E:\ContentLibrary',
    [string]$InstallRoot = 'C:\ProgramData\VCSPCatalog',
    [string]$TaskName = 'Regenerate vCenter VCSP Catalog',
    [ValidateRange(1,24)][int]$RunEveryHours = 2,
    [switch]$RunImmediately
)
$ErrorActionPreference = 'Stop'
foreach ($value in $LibraryName, $ContentRoot, $InstallRoot, $PythonPath) {
    if ($value -match '["\r\n]') { throw 'Quotes and newlines are not supported in parameters.' }
}
$ContentRoot = [IO.Path]::GetFullPath($ContentRoot).TrimEnd('\')
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if (-not (Test-Path -LiteralPath $ContentRoot -PathType Container)) { throw 'Create the content directory first.' }
if ($ContentRoot -eq [IO.Path]::GetPathRoot($ContentRoot).TrimEnd('\')) { throw 'Do not use a drive root as ContentRoot.' }
if ($InstallRoot.StartsWith($ContentRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $InstallRoot -eq $ContentRoot) { throw 'Automation must be outside the web root.' }
if (Test-Path -LiteralPath $InstallRoot) { throw 'InstallRoot already exists. Review/migrate the existing installation; this installer will not overwrite it.' }
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { throw 'Task already exists; refusing to overwrite it.' }
if ($PythonPath -like '*\WindowsApps\*' -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { throw 'Supply the full path to a real, all-users Python interpreter, not a Store alias.' }
& $PythonPath --version
if ($LASTEXITCODE -ne 0) { throw 'Python cannot run.' }
$bundle = Split-Path $PSScriptRoot -Parent
$generator = Join-Path $bundle 'make_vcsp_2022.py'
if ((Get-FileHash -LiteralPath $generator -Algorithm SHA256).Hash -ne '893F2188D4EF998600C0F0450DCEC82481093FB0E1C449F1BD80E9FB61037444') { throw 'Upstream generator hash mismatch.' }
New-Item -ItemType Directory -Path $InstallRoot | Out-Null
# Replace inherited access on this NEW dedicated directory with admin/SYSTEM only.
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
    $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
Set-Acl -LiteralPath $InstallRoot -AclObject $acl
foreach ($dir in 'Scripts','Logs') { New-Item -ItemType Directory -Path (Join-Path $InstallRoot $dir) | Out-Null }
$venv = Join-Path $InstallRoot 'PythonVenv'
& $PythonPath -m venv $venv
if ($LASTEXITCODE -ne 0) { throw 'venv creation failed.' }
$python = Join-Path $venv 'Scripts\python.exe'
& $python -m pip install -r (Join-Path $bundle 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
$installedGenerator = Join-Path $InstallRoot 'Scripts\make_vcsp_2022.py'
$runner = Join-Path $InstallRoot 'Scripts\Run-VCSPCatalog.ps1'
Copy-Item -LiteralPath $generator -Destination $installedGenerator
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Run-VCSPCatalog.ps1') -Destination $runner
& $python $installedGenerator --help
if ($LASTEXITCODE -ne 0) { throw 'Generator dependency/import check failed.' }
$configPath = Join-Path $InstallRoot 'config.json'
@{ Python=$python; Generator=$installedGenerator; LibraryName=$LibraryName; ContentRoot=$ContentRoot; LogDirectory=(Join-Path $InstallRoot 'Logs') } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runner`" -ConfigPath `"$configPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours $RunEveryHours)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
if ($RunImmediately) { Start-ScheduledTask -TaskName $TaskName }
Write-Output "Task registered: $TaskName. Interval: $RunEveryHours hours. Check task status and $InstallRoot\Logs; registration does not prove generation succeeded."

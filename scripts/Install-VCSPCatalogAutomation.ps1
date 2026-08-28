#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LibraryName,

    [ValidatePattern('^[A-Za-z]:\\')]
    [string]$ContentRoot = 'D:\ContentLibrary',

    [ValidatePattern('^$|^[A-Za-z]:\\')]
    [string]$StagingRoot = '',

    [ValidatePattern('^[A-Za-z]:\\')]
    [string]$InstallRoot = 'C:\ProgramData\VCSPCatalog',

    [string]$TaskName = 'Regenerate vCenter VCSP Catalog',

    [ValidateRange(1, 24)]
    [int]$RunEveryHours = 2,

    [string]$PythonInstallerUrl = 'https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe',

    [string]$VcspScriptUrl = 'https://raw.githubusercontent.com/lamw/vmware-scripts/master/python/make_vcsp_2022.py',

    [string]$ExpectedVcspSha256 = '893F2188D4EF998600C0F0450DCEC82481093FB0E1C449F1BD80E9FB61037444',

    [switch]$RunImmediately
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
    }
}

function Find-CompatiblePython {
    $candidates = [System.Collections.Generic.List[string]]@(
        'C:\Program Files\Python312\python.exe',
        'C:\Program Files\Python311\python.exe',
        'C:\Program Files\Python310\python.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe')
    )

    $registryRoots = @(
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Python\PythonCore',
        'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Python\PythonCore',
        'Registry::HKEY_CURRENT_USER\SOFTWARE\Python\PythonCore'
    )
    foreach ($registryRoot in $registryRoots) {
        if (-not (Test-Path -LiteralPath $registryRoot)) {
            continue
        }
        foreach ($versionKey in Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue) {
            $installPathKey = Join-Path $versionKey.PSPath 'InstallPath'
            if (Test-Path -LiteralPath $installPathKey) {
                $installDirectory = (Get-Item -LiteralPath $installPathKey).GetValue('')
                if ($installDirectory) {
                    $candidates.Add((Join-Path $installDirectory 'python.exe'))
                }
            }
        }
    }

    $searchPatterns = @(
        (Join-Path $env:ProgramFiles 'Python*\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\python.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $searchPatterns += Join-Path ${env:ProgramFiles(x86)} 'Python*\python.exe'
    }
    foreach ($pattern in $searchPatterns) {
        foreach ($match in Get-Item -Path $pattern -ErrorAction SilentlyContinue) {
            $candidates.Add($match.FullName)
        }
    }

    $pathPython = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pathPython) {
        $candidates.Add($pathPython.Source)
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        # Windows may expose a Microsoft Store application-execution alias named
        # python.exe even when Python is not installed. It is not a usable runtime.
        if ($candidate -match '[\\/]Microsoft[\\/]WindowsApps[\\/]') {
            continue
        }

        $probeId = [guid]::NewGuid().ToString('N')
        $probeOut = Join-Path $env:TEMP "python-probe-$probeId.out"
        $probeErr = Join-Path $env:TEMP "python-probe-$probeId.err"
        try {
            $probe = Start-Process `
                -FilePath $candidate `
                -ArgumentList @('--version') `
                -RedirectStandardOutput $probeOut `
                -RedirectStandardError $probeErr `
                -WindowStyle Hidden `
                -Wait `
                -PassThru
            $pythonExitCode = $probe.ExitCode
            $versionText = if (Test-Path -LiteralPath $probeOut) {
                (Get-Content -LiteralPath $probeOut -Raw).Trim()
            }
            else {
                ''
            }

            # Some Python releases write --version to stderr instead of stdout.
            if (-not $versionText -and (Test-Path -LiteralPath $probeErr)) {
                $versionText = (Get-Content -LiteralPath $probeErr -Raw).Trim()
            }

            if ($pythonExitCode -ne 0) {
                $probeError = if (Test-Path -LiteralPath $probeErr) {
                    (Get-Content -LiteralPath $probeErr -Raw).Trim()
                }
                else {
                    ''
                }
                Write-Warning "Python candidate '$candidate' failed its runtime probe with exit code $pythonExitCode. Error: $probeError"
            }
        }
        catch {
            Write-Warning "Python candidate '$candidate' could not start: $($_.Exception.Message)"
            continue
        }
        finally {
            Remove-Item -LiteralPath $probeOut, $probeErr -Force -ErrorAction SilentlyContinue
        }

        if ($pythonExitCode -eq 0) {
            try {
                $parsedVersion = $versionText -replace '^Python\s+', ''
                if ([version]$parsedVersion -ge [version]'3.10') {
                    return $candidate
                }
            }
            catch {
                continue
            }
        }
    }

    return $null
}

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install VCSP catalog automation task '$TaskName'")) {
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptRoot = Join-Path $InstallRoot 'Scripts'
$venvRoot = Join-Path $InstallRoot 'PythonVenv'
$logRoot = Join-Path $InstallRoot 'Logs'
$vcspScript = Join-Path $scriptRoot 'make_vcsp_2022.py'
$runnerScript = Join-Path $scriptRoot 'Run-VCSPCatalog.ps1'

New-Item -ItemType Directory -Path $ContentRoot -Force | Out-Null
New-Item -ItemType Directory -Path $scriptRoot -Force | Out-Null
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

$contentParent = Split-Path -Path $ContentRoot -Parent
$contentLeaf = Split-Path -Path $ContentRoot -Leaf
if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    $StagingRoot = Join-Path $contentParent "${contentLeaf}-Staging"
}

$nestedStaging = Join-Path $ContentRoot '_staging'
if (Test-Path -LiteralPath $nestedStaging) {
    if (Test-Path -LiteralPath $StagingRoot) {
        throw "Cannot relocate '$nestedStaging' because '$StagingRoot' already exists. Merge or rename those staging directories manually, then run this installer again."
    }
    Write-Host "Relocating nested staging directory to '$StagingRoot'..."
    Move-Item -LiteralPath $nestedStaging -Destination $StagingRoot
}
New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null

$python = Find-CompatiblePython
if (-not $python) {
    $installer = Join-Path $env:TEMP 'python-3.12.10-amd64.exe'
    $installerLog = Join-Path $env:TEMP 'python-3.12.10-install.log'
    $pythonTarget = 'C:\Program Files\Python312'
    Write-Host 'A compatible Python installation was not found. Downloading Python 3.12.10...'
    Invoke-WebRequest -Uri $PythonInstallerUrl -OutFile $installer -UseBasicParsing

    $signature = Get-AuthenticodeSignature -FilePath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
        throw "Python installer signature validation failed. Status: $($signature.Status); signer: $($signature.SignerCertificate.Subject)"
    }

    $installArguments = @(
        '/quiet',
        '/log',
        $installerLog,
        'InstallAllUsers=1',
        'PrependPath=1',
        'Include_test=0',
        'Include_pip=1',
        'Include_venv=1',
        "TargetDir=`"$pythonTarget`""
    )

    Write-Host "Installing Python to '$pythonTarget'. Installer log: $installerLog"
    $installProcess = Start-Process `
        -FilePath $installer `
        -ArgumentList $installArguments `
        -Wait `
        -PassThru

    if ($installProcess.ExitCode -notin @(0, 3010)) {
        Write-Warning "Python setup failed with exit code $($installProcess.ExitCode)."
        if (Test-Path -LiteralPath $installerLog) {
            Write-Warning "Review the full installer log at: $installerLog"
            Write-Host 'Last 40 lines of the Python installer log:'
            Get-Content -LiteralPath $installerLog -Tail 40 | Write-Host
        }
        throw "Python installation failed with exit code $($installProcess.ExitCode). The installer and log were retained in '$env:TEMP'."
    }

    Remove-Item -LiteralPath $installer -Force
    if ($installProcess.ExitCode -eq 3010) {
        Write-Warning 'Python installed successfully, but Windows reports that a restart is required.'
    }

    $python = Find-CompatiblePython
    if (-not $python) {
        Write-Host 'Python-related files discovered after installation:'
        $diagnosticPatterns = @(
            'C:\Program Files\Python*\python*.exe',
            (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\python*.exe')
        )
        foreach ($pattern in $diagnosticPatterns) {
            Get-Item -Path $pattern -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty FullName |
                Write-Host
        }
        Write-Warning "Review the Python installation log at: $installerLog"
        throw 'Python installation completed, but a compatible python.exe could not be located.'
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $venvRoot 'Scripts\python.exe'))) {
    Invoke-NativeCommand -FilePath $python -ArgumentList @('-m', 'venv', $venvRoot)
}

$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
Invoke-NativeCommand -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip')
Invoke-NativeCommand -FilePath $venvPython -ArgumentList @(
    '-m', 'pip', 'install', '--upgrade',
    'boto3>=1.34,<2',
    'python-dateutil>=2.9,<3',
    'azure-storage-blob>=12.19,<13'
)

$downloadedScript = Join-Path $env:TEMP 'make_vcsp_2022.py.download'
Invoke-WebRequest -Uri $VcspScriptUrl -OutFile $downloadedScript -UseBasicParsing
$actualHash = (Get-FileHash -LiteralPath $downloadedScript -Algorithm SHA256).Hash
if ($ExpectedVcspSha256 -and $actualHash -ne $ExpectedVcspSha256) {
    Remove-Item -LiteralPath $downloadedScript -Force
    throw "VCSP script SHA-256 mismatch. Expected $ExpectedVcspSha256 but downloaded $actualHash. Review the upstream change before updating the expected hash."
}
Move-Item -LiteralPath $downloadedScript -Destination $vcspScript -Force

# Starting the VCSP script with --help validates its imports as well as the
# downloaded script itself. Avoid python -c here because Windows PowerShell's
# native argument quoting can strip the quotes inside inline Python code.
Invoke-NativeCommand -FilePath $venvPython -ArgumentList @($vcspScript, '--help')

$qPython = ConvertTo-SingleQuotedLiteral $venvPython
$qVcspScript = ConvertTo-SingleQuotedLiteral $vcspScript
$qLibraryName = ConvertTo-SingleQuotedLiteral $LibraryName
$qContentRoot = ConvertTo-SingleQuotedLiteral $ContentRoot
$qLogRoot = ConvertTo-SingleQuotedLiteral $logRoot

$runnerContent = @"
# Generated by Install-VCSPCatalogAutomation.ps1
`$ErrorActionPreference = 'Stop'
`$python = $qPython
`$vcspScript = $qVcspScript
`$libraryName = $qLibraryName
`$contentRoot = $qContentRoot
`$logRoot = $qLogRoot

New-Item -ItemType Directory -Path `$logRoot -Force | Out-Null
`$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
`$logFile = Join-Path `$logRoot "make-vcsp-`$timestamp.log"

try {
    & `$python `$vcspScript -n `$libraryName -t local -path `$contentRoot --etag true --skip-cert true *>> `$logFile
    if (`$LASTEXITCODE -ne 0) {
        throw "make_vcsp_2022.py returned exit code `$LASTEXITCODE"
    }
}
catch {
    "`$(Get-Date -Format o) ERROR: `$(`$_.Exception.Message)" | Add-Content -LiteralPath `$logFile
    exit 1
}

# Retain 30 days of task logs.
Get-ChildItem -LiteralPath `$logRoot -Filter 'make-vcsp-*.log' -File -ErrorAction SilentlyContinue |
    Where-Object LastWriteTime -LT (Get-Date).AddDays(-30) |
    Remove-Item -Force
"@

Set-Content -LiteralPath $runnerScript -Value $runnerContent -Encoding UTF8

$taskPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerScript`""
$action = New-ScheduledTaskAction `
    -Execute $taskPowerShell `
    -Argument $taskArguments `
    -WorkingDirectory $scriptRoot

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Hours $RunEveryHours)

$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Regenerates the '$LibraryName' local VCSP Content Library catalog every $RunEveryHours hours."

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

if ($RunImmediately) {
    Start-ScheduledTask -TaskName $TaskName
}

[pscustomobject]@{
    TaskName         = $TaskName
    TaskAccount      = 'NT AUTHORITY\SYSTEM'
    IntervalHours    = $RunEveryHours
    ContentRoot      = $ContentRoot
    StagingRoot      = $StagingRoot
    PythonExecutable = $venvPython
    VcspScript       = $vcspScript
    RunnerScript     = $runnerScript
    LogDirectory     = $logRoot
    FirstRun         = (Get-Date).AddMinutes(2)
}

#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) { throw ($errors | Out-String) }
    Write-Output "PASS syntax: $($file.Name)"
}
if ((Get-FileHash (Join-Path $root 'make_vcsp_2022.py')).Hash -ne '893F2188D4EF998600C0F0450DCEC82481093FB0E1C449F1BD80E9FB61037444') { throw 'Generator hash mismatch' }
Write-Output 'PASS upstream SHA-256'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('vcsp-check-' + [guid]::NewGuid().ToString('N'))
$source = New-Item -ItemType Directory -Path (Join-Path $testRoot 'Source')
$dest = New-Item -ItemType Directory -Path (Join-Path $testRoot 'Content')
# Tiny fixture only, not installation media.
$fixture = New-Item -ItemType File -Path (Join-Path $source.FullName 'Sample.ISO')
& (Join-Path $root 'scripts\Organize-VCSPContent.ps1') -SourceRoot $source.FullName -ContentRoot $dest.FullName -WhatIf
if (-not (Test-Path $fixture.FullName) -or @(Get-ChildItem $dest.FullName).Count -ne 0) { throw 'WhatIf unexpectedly changed files.' }
Write-Output 'PASS organizer WhatIf leaves source and destination unchanged'
# Exact fixture paths only; never recursively delete a computed directory tree.
Remove-Item -LiteralPath $fixture.FullName
Remove-Item -LiteralPath $source.FullName
Remove-Item -LiteralPath $dest.FullName
Remove-Item -LiteralPath $testRoot

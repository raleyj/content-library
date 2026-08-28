#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$SiteName = 'vCenter-Content-Library',
    [ValidatePattern('^[A-Za-z]:\\')]
    [string]$ContentRoot = 'E:\ContentLibrary'
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    throw "IIS site '$SiteName' was not found. Run Get-Website to identify its actual name."
}

$applicationPool = (Get-Website -Name $SiteName).applicationPool
if (-not $applicationPool) {
    throw "The IIS site '$SiteName' does not have an application pool assigned."
}

# Empty userName/password tells IIS anonymous authentication to use the
# application-pool identity rather than the built-in IUSR account.
Set-WebConfigurationProperty `
    -PSPath 'MACHINE/WEBROOT/APPHOST' `
    -Location $SiteName `
    -Filter 'system.webServer/security/authentication/anonymousAuthentication' `
    -Name enabled `
    -Value $true

Set-WebConfigurationProperty `
    -PSPath 'MACHINE/WEBROOT/APPHOST' `
    -Location $SiteName `
    -Filter 'system.webServer/security/authentication/anonymousAuthentication' `
    -Name userName `
    -Value ''

Set-WebConfigurationProperty `
    -PSPath 'MACHINE/WEBROOT/APPHOST' `
    -Location $SiteName `
    -Filter 'system.webServer/security/authentication/anonymousAuthentication' `
    -Name password `
    -Value ''

& icacls.exe $ContentRoot /grant `
    "IIS AppPool\${applicationPool}:(OI)(CI)(RX)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to grant the IIS application-pool identity access to '$ContentRoot'."
}

Restart-WebAppPool -Name $applicationPool

[pscustomobject]@{
    SiteName          = $SiteName
    ApplicationPool   = $applicationPool
    ContentRoot       = $ContentRoot
    AnonymousIdentity = "IIS AppPool\$applicationPool"
    TestUrl           = 'https://library.example.com/lib.json'
}

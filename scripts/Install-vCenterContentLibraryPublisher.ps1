#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PublisherFqdn,

    [string]$SiteName = 'vCenter-Content-Library',

    [ValidatePattern('^[A-Za-z]:\\')]
    [string]$ContentRoot = 'D:\ContentLibrary',

    [ValidateRange(1, 65535)]
    [int]$HttpsPort = 443,

    [string]$CertificateThumbprint,

    [switch]$CreateSelfSignedCertificate,

    [ValidateRange(1, 2147483647)]
    [int]$MaxAllowedContentLength = 2147483647
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($CreateSelfSignedCertificate -and $CertificateThumbprint) {
    throw 'Specify either -CertificateThumbprint or -CreateSelfSignedCertificate, not both.'
}

if (-not $CreateSelfSignedCertificate -and -not $CertificateThumbprint) {
    throw 'Specify -CertificateThumbprint or -CreateSelfSignedCertificate.'
}

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Install and configure the vCenter Content Library IIS publisher')) {
    Install-WindowsFeature `
        Web-Server, `
        Web-Static-Content, `
        Web-Http-Logging, `
        Web-Request-Monitor, `
        Web-Mgmt-Console `
        -IncludeManagementTools | Out-Null

    Import-Module WebAdministration

    $stagingRoot = Join-Path $ContentRoot '_staging'
    New-Item -ItemType Directory -Path $ContentRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    if ($CreateSelfSignedCertificate) {
        $certificate = New-SelfSignedCertificate `
            -DnsName $PublisherFqdn `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -FriendlyName 'vCenter Content Library Publisher' `
            -NotAfter (Get-Date).AddYears(2)
        $CertificateThumbprint = $certificate.Thumbprint
    }
    else {
        $CertificateThumbprint = $CertificateThumbprint.Replace(' ', '')
        $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction Stop
        if ($certificate.NotAfter -le (Get-Date)) {
            throw "Certificate $CertificateThumbprint is expired."
        }
        if (-not $certificate.HasPrivateKey) {
            throw "Certificate $CertificateThumbprint does not have a private key."
        }
    }

    if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
        New-WebAppPool -Name $SiteName | Out-Null
    }

    Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion -Value ''
    Set-ItemProperty "IIS:\AppPools\$SiteName" -Name processModel.identityType -Value ApplicationPoolIdentity

    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
        throw "An IIS site named '$SiteName' already exists. Remove it or choose another -SiteName."
    }

    New-Website `
        -Name $SiteName `
        -PhysicalPath $ContentRoot `
        -ApplicationPool $SiteName `
        -Port $HttpsPort `
        -HostHeader $PublisherFqdn `
        -Ssl | Out-Null

    $binding = Get-WebBinding `
        -Name $SiteName `
        -Protocol https `
        -Port $HttpsPort `
        -HostHeader $PublisherFqdn
    $binding.AddSslCertificate($CertificateThumbprint, 'My')

    Set-WebConfigurationProperty `
        -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Location $SiteName `
        -Filter 'system.webServer/security/requestFiltering/requestLimits' `
        -Name maxAllowedContentLength `
        -Value $MaxAllowedContentLength

    $mimeTypes = [ordered]@{
        '.json' = 'application/json'
        '.ova'  = 'application/octet-stream'
        '.ovf'  = 'application/xml'
        '.vmdk' = 'application/octet-stream'
        '.iso'  = 'application/octet-stream'
        '.mf'   = 'text/plain'
    }

    foreach ($extension in $mimeTypes.Keys) {
        $existing = Get-WebConfigurationProperty `
            -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Location $SiteName `
            -Filter 'system.webServer/staticContent/mimeMap' `
            -Name '.' | Where-Object fileExtension -EQ $extension

        if (-not $existing) {
            Add-WebConfigurationProperty `
                -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Location $SiteName `
                -Filter 'system.webServer/staticContent' `
                -Name '.' `
                -Value @{ fileExtension = $extension; mimeType = $mimeTypes[$extension] }
        }
    }

    Set-WebConfigurationProperty `
        -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Location $SiteName `
        -Filter 'system.webServer/directoryBrowse' `
        -Name enabled `
        -Value $false

    & icacls.exe $ContentRoot /inheritance:r | Out-Null
    & icacls.exe $ContentRoot /grant:r `
        'BUILTIN\Administrators:(OI)(CI)(F)' `
        'NT AUTHORITY\SYSTEM:(OI)(CI)(F)' `
        "IIS AppPool\${SiteName}:(OI)(CI)(RX)" | Out-Null

    $firewallRuleName = "vCenter Content Library HTTPS ($HttpsPort)"
    if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName $firewallRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $HttpsPort `
            -Profile Domain,Private | Out-Null
    }

    Start-Website -Name $SiteName

    [pscustomobject]@{
        SiteName               = $SiteName
        ContentRoot            = $ContentRoot
        StagingRoot            = $stagingRoot
        SubscriptionUrl        = "https://${PublisherFqdn}:$HttpsPort/lib.json"
        CertificateThumbprint  = $CertificateThumbprint
        Status                 = (Get-Website -Name $SiteName).State
    }
}

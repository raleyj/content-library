#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$PublisherFqdn,
    [Parameter(Mandatory)][string]$CertificateThumbprint,
    [string]$ContentRoot = 'E:\ContentLibrary',
    [string]$SiteName = 'vCenter-Content-Library',
    [string[]]$AllowedRemoteAddress = @('LocalSubnet'),
    [switch]$EnableDirectoryBrowsing,
    [switch]$EnableHttp
)
$ErrorActionPreference = 'Stop'
$ContentRoot = [IO.Path]::GetFullPath($ContentRoot).TrimEnd('\')
if ($ContentRoot -eq [IO.Path]::GetPathRoot($ContentRoot).TrimEnd('\')) { throw 'Do not publish a drive root.' }
$thumbprint = $CertificateThumbprint -replace '\s',''
$certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint"
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date)) { throw 'Certificate must have a private key and must not be expired.' }
Write-Warning 'Verify that the certificate SAN covers PublisherFqdn and clients trust its issuing CA.'
$features = @('Web-Server','Web-Static-Content','Web-Http-Logging','Web-Mgmt-Console','Web-Scripting-Tools')
if ($EnableDirectoryBrowsing) { $features += 'Web-Dir-Browsing' }
$result = Install-WindowsFeature -Name $features
if (-not $result.Success) { throw 'IIS feature installation failed.' }
if ($result.RestartNeeded -eq 'Yes') { throw 'Restart Windows to finish feature installation, then rerun.' }
Import-Module WebAdministration
$pool = $SiteName
$site = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
if ($site -and ([IO.Path]::GetFullPath($site.PhysicalPath).TrimEnd('\') -ne $ContentRoot -or $site.ApplicationPool -ne $pool)) { throw 'Existing site has a different path or pool. Review it manually.' }
if (-not (Test-Path -LiteralPath "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
if ((Get-Item "IIS:\AppPools\$pool").processModel.identityType -ne 'ApplicationPoolIdentity') { throw 'Existing pool uses a different identity; refusing to change it.' }
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
if (-not (Test-Path -LiteralPath $ContentRoot)) { New-Item -ItemType Directory -Path $ContentRoot | Out-Null }
if ((Get-Item -LiteralPath $ContentRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'ContentRoot cannot be a link.' }
$acl = Get-Acl -LiteralPath $ContentRoot
foreach ($entry in @(@("IIS AppPool\$pool",'ReadAndExecute'), @('S-1-5-18','FullControl'))) {
    $identity = if ($entry[0] -like 'S-1-*') { New-Object System.Security.Principal.SecurityIdentifier($entry[0]) } else { New-Object System.Security.Principal.NTAccount($entry[0]) }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, $entry[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
Set-Acl -LiteralPath $ContentRoot -AclObject $acl
if (-not $site) {
    New-Website -Name $SiteName -PhysicalPath $ContentRoot -ApplicationPool $pool -Port 443 -HostHeader $PublisherFqdn -Ssl -SslFlags 1 | Out-Null
}
$https = Get-WebBinding -Name $SiteName -Protocol https | Where-Object { $_.bindingInformation -eq "*:443:$PublisherFqdn" }
if (-not $https) {
    New-WebBinding -Name $SiteName -Protocol https -Port 443 -HostHeader $PublisherFqdn -SslFlags 1
    $https = Get-WebBinding -Name $SiteName -Protocol https | Where-Object { $_.bindingInformation -eq "*:443:$PublisherFqdn" }
}
$https.AddSslCertificate($thumbprint, 'My')
$settings = @{PSPath='MACHINE/WEBROOT/APPHOST'; Location=$SiteName}
$anonymous = 'system.webServer/security/authentication/anonymousAuthentication'
Set-WebConfigurationProperty @settings -Filter $anonymous -Name enabled -Value $true
Set-WebConfigurationProperty @settings -Filter $anonymous -Name userName -Value ''
Set-WebConfigurationProperty @settings -Filter $anonymous -Name password -Value ''
$mimeTypes = @{'.json'='application/json'; '.iso'='application/octet-stream'; '.ova'='application/octet-stream'; '.ovf'='application/octet-stream'; '.vmdk'='application/octet-stream'; '.mf'='text/plain'; '.cert'='application/octet-stream'}
foreach ($extension in $mimeTypes.Keys) {
    $existing = Get-WebConfigurationProperty @settings -Filter "system.webServer/staticContent/mimeMap[@fileExtension='$extension']" -Name mimeType
    if (-not $existing) { Add-WebConfigurationProperty @settings -Filter 'system.webServer/staticContent' -Name '.' -Value @{fileExtension=$extension; mimeType=$mimeTypes[$extension]} }
}
if ($EnableDirectoryBrowsing) { Set-WebConfigurationProperty @settings -Filter 'system.webServer/directoryBrowse' -Name enabled -Value $true }
if ($EnableHttp) {
    if (-not (Get-WebBinding -Name $SiteName -Protocol http | Where-Object { $_.bindingInformation -eq "*:80:$PublisherFqdn" })) {
        New-WebBinding -Name $SiteName -Protocol http -Port 80 -HostHeader $PublisherFqdn
    }
    Write-Warning 'HTTP is unencrypted. Existing Require SSL or redirect rules are not removed; review them if HTTP is blocked or redirects.'
}
$ports = @(443)
if ($EnableHttp) { $ports += 80 }
foreach ($port in $ports) {
    $rule = "VCSP-$SiteName-TCP-$port"
    if (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $rule -Enabled True -Action Allow -RemoteAddress $AllowedRemoteAddress -Profile Domain,Private | Out-Null
    } else {
        New-NetFirewallRule -Name $rule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress $AllowedRemoteAddress -Profile Domain,Private | Out-Null
    }
}
Start-Website -Name $SiteName
Write-Output "Publisher configured: https://$PublisherFqdn/lib.json (available after catalog generation)."

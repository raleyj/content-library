#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SiteName = 'vCenter-Content-Library',

    [string]$HostName = 'library.example.com',

    [ValidateRange(1, 65535)]
    [int]$Port = 80
)

$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$site = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
if (-not $site) {
    throw "IIS site '$SiteName' was not found. Run Get-Website to identify its actual name."
}

$existingBinding = Get-WebBinding `
    -Name $SiteName `
    -Protocol http `
    -Port $Port `
    -HostHeader $HostName `
    -ErrorAction SilentlyContinue

if (-not $existingBinding) {
    if ($PSCmdlet.ShouldProcess("${HostName}:$Port", "Add HTTP binding to IIS site '$SiteName'")) {
        New-WebBinding `
            -Name $SiteName `
            -Protocol http `
            -IPAddress '*' `
            -Port $Port `
            -HostHeader $HostName | Out-Null
    }
}

$firewallRuleName = "vCenter Content Library HTTP ($Port)"
if (-not (Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess("TCP $Port", 'Create inbound Windows Firewall rule')) {
        New-NetFirewallRule `
            -DisplayName $firewallRuleName `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -Profile Domain,Private | Out-Null
    }
}

if ($site.State -ne 'Started') {
    Start-Website -Name $SiteName
}

[pscustomobject]@{
    SiteName       = $SiteName
    HttpUrl        = "http://${HostName}:$Port/"
    CatalogUrl     = "http://${HostName}:$Port/lib.json"
    ExistingHttps = [bool](Get-WebBinding -Name $SiteName -Protocol https -ErrorAction SilentlyContinue)
}

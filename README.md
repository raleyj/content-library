# Windows-hosted vCenter Content Library

These are the five PowerShell scripts Justin used for his Windows Server Content Library deployment—not the reconstructed scripts previously uploaded here. Original behavior is preserved; the internal hostname in two scripts is replaced with `library.example.com`. See [VALIDATION.md](VALIDATION.md) for scope and [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) before running.

## Scripts

| Script | Purpose |
| --- | --- |
| [Install-vCenterContentLibraryPublisher.ps1](scripts/Install-vCenterContentLibraryPublisher.ps1) | Install IIS and create the HTTPS publisher using an existing or self-signed certificate. |
| [Install-VCSPCatalogAutomation.ps1](scripts/Install-VCSPCatalogAutomation.ps1) | Discover/install Python, install dependencies, generate the runner, and register the two-hour SYSTEM task. |
| [Repair-VCSPPublisherAccess.ps1](scripts/Repair-VCSPPublisherAccess.ps1) | Configure anonymous authentication to use the actual application pool and grant read access. |
| [Organize-VCSPContent.ps1](scripts/Organize-VCSPContent.ps1) | Move top-level ISO/OVA files into folders named after their base names. |
| [Enable-VCSPHttp.ps1](scripts/Enable-VCSPHttp.ps1) | Add HTTP access while retaining HTTPS. |

The automation installer generates `C:\ProgramData\VCSPCatalog\Scripts\Run-VCSPCatalog.ps1`. Do not use the previous standalone runner/config.json workflow.

## Deployment order for a new server

Use elevated **Windows PowerShell 5.1** on Windows Server. Prepare DNS, routing, disk capacity, and an existing certificate in `Cert:\LocalMachine\My` with its private key, matching SAN, and trusted issuing CA.

The installers retain their original **D:** defaults; the other scripts use **E:**. Pass the paths explicitly as below. Review the warnings before running. These commands configure the server; they are not a dry run.

```powershell
Set-Location C:\Setup\content-library

.\scripts\Install-vCenterContentLibraryPublisher.ps1 `
    -PublisherFqdn 'library.example.com' `
    -ContentRoot 'E:\ContentLibrary' `
    -CertificateThumbprint 'REPLACE_WITH_YOUR_CERTIFICATE_THUMBPRINT'

.\scripts\Install-VCSPCatalogAutomation.ps1 `
    -LibraryName 'Published Content Library' `
    -ContentRoot 'E:\ContentLibrary' `
    -StagingRoot 'E:\ContentLibrary-Staging'

.\scripts\Repair-VCSPPublisherAccess.ps1 `
    -ContentRoot 'E:\ContentLibrary'

# Copy COMPLETE files to E:\ first. Use distinct base names and lowercase extensions.
.\scripts\Organize-VCSPContent.ps1 `
    -SourcePath 'E:\' -DestinationRoot 'E:\ContentLibrary' -WhatIf

.\scripts\Organize-VCSPContent.ps1 `
    -SourcePath 'E:\' -DestinationRoot 'E:\ContentLibrary'

Start-ScheduledTask -TaskName 'Regenerate vCenter VCSP Catalog'
Get-ScheduledTaskInfo -TaskName 'Regenerate vCenter VCSP Catalog'
Get-ChildItem C:\ProgramData\VCSPCatalog\Logs
Invoke-WebRequest 'https://library.example.com/lib.json' -UseBasicParsing
```

The publisher creates nested `_staging`; run automation second so it relocates that folder outside the web root. If the destination staging directory already exists, automation stops for manual reconciliation. Never scan incomplete uploads. The task begins approximately two minutes after registration; wait for it to finish before starting another run.

Create a **Subscribed Content Library** in vCenter with `https://library.example.com/lib.json`, select its datastore/download policy, then synchronize and verify an actual item. Windows hosts the publisher; it is not an iSCSI target or the subscribed library's datastore.

## Optional directory browsing

This was a separate configuration step in the lab and is not enabled by the five original scripts:

```powershell
Install-WindowsFeature Web-Dir-Browsing
Import-Module WebAdministration
Set-WebConfigurationProperty `
    -PSPath 'MACHINE/WEBROOT/APPHOST' `
    -Location 'vCenter-Content-Library' `
    -Filter 'system.webServer/directoryBrowse' `
    -Name enabled -Value $true
```

Browse to `https://library.example.com/`. No `Restart-Website` command is needed. Browsing exposes filenames to users who can reach the anonymous website.

## Optional HTTP

```powershell
.\scripts\Enable-VCSPHttp.ps1 -HostName 'library.example.com'
```

HTTP is unencrypted. Keep vCenter subscribed through HTTPS. Existing Require SSL, redirects, or browser HTTPS-only settings can still prevent HTTP access. The original firewall rules are not restricted to specific remote addresses; review and scope network access yourself.

## Python and scheduling

- Python discovery skips Store aliases and probes real interpreters. If none qualifies, the original fallback installs **Python 3.12.10** after signature verification. This historical fallback is preserved, not recommended as the latest patched runtime. Prefer a maintained all-users installation and verify compatibility.
- The installer downloads the upstream generator and checks its expected SHA-256. The unchanged reference copy here has the same hash; see [third-party notices](THIRD_PARTY_NOTICES.md).
- Dependencies are installed/upgraded by the installer. `requirements.txt` documents the same version ranges but is not read by that installer.
- Task: SYSTEM, every two hours, overlapping scheduled instances ignored, one-hour execution limit, 30-day log retention after a successful generation.
- Rerunning automation can upgrade dependencies, overwrite its generator/runner, and replace the task. Back up before rerunning; avoid doing so during an active run.
- Do not rerun the publisher against an existing site: it can alter prerequisites before rejecting the existing site.

## Safety

Keep automation, Python, logs, and staging outside the served directory. Ensure only administrators/SYSTEM can modify the task's scripts and runtime; the original automation installer does not harden those ACLs for you. Never upload credentials, private keys, or ISO/OVA payloads to this repository.

The associated article is being prepared for [JustinRaley.com](https://justinraley.com/). This README is the current script usage reference.

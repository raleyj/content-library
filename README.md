# Windows-hosted vCenter Content Library

A Windows Server / IIS publisher for a **subscribed vCenter Content Library**, using a static VCSP catalog instead of iSCSI or SMB storage.

Read the [deployment blog](BLOG.md) for the walkthrough and the troubleshooting lessons from the lab.

## Included files

- `scripts/Configure-VCSPWeb.ps1`: configure IIS, an existing certificate, anonymous read access, optional browsing and HTTP.
- `scripts/Install-VCSPCatalogAutomation.ps1`: create a Python virtual environment, install dependencies, and schedule catalog generation every two hours.
- `scripts/Run-VCSPCatalog.ps1`: generate the catalog with logging.
- `scripts/Organize-VCSPContent.ps1`: move completed ISO/OVA files from `E:\` into individual folders under `E:\ContentLibrary`.
- `make_vcsp_2022.py`: unchanged, pinned upstream generator. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Quick start

Use an elevated **Windows PowerShell 5.1** prompt on the Windows Server. Review scripts first. Replace the hostname, certificate thumbprint and network scope below.

Install a supported 64-bit Python runtime from [python.org](https://www.python.org/downloads/windows/) for all users. The original lab used Python 3.12.10; that is historical information, not a recommendation to install an old patch release. These scripts accept an explicit interpreter path and deliberately do not silently download an old runtime.

```powershell
Set-Location C:\Setup\content-library

.\scripts\Configure-VCSPWeb.ps1 `
    -PublisherFqdn 'library.example.com' `
    -CertificateThumbprint 'REPLACE_WITH_EXISTING_CERTIFICATE_THUMBPRINT' `
    -AllowedRemoteAddress 'LocalSubnet' `
    -EnableDirectoryBrowsing

.\scripts\Install-VCSPCatalogAutomation.ps1 `
    -LibraryName 'Published Content Library' `
    -PythonPath 'C:\Program Files\Python312\python.exe' `
    -RunImmediately

# Copy complete ISO/OVA files to E:\ first. Preview before moving them.
.\scripts\Organize-VCSPContent.ps1 -WhatIf
.\scripts\Organize-VCSPContent.ps1

Start-ScheduledTask -TaskName 'Regenerate vCenter VCSP Catalog'
Get-ScheduledTaskInfo -TaskName 'Regenerate vCenter VCSP Catalog'
Invoke-WebRequest 'https://library.example.com/lib.json' -UseBasicParsing
```

Create a **Subscribed Content Library** in vCenter using `https://library.example.com/lib.json`. Choose the vCenter datastore and download policy, then synchronize and test one item. A successful HTTP response alone does not validate vCenter synchronization.

`LocalSubnet` is the Windows Firewall scope, not every network in your lab. Supply the required management/client CIDRs or IP addresses if vCenter or clients are elsewhere. Ensure DNS and routing work from those networks.

## Optional HTTP access

Rerun `Configure-VCSPWeb.ps1` with the same settings and `-EnableHttp`. Existing HTTPS bindings are retained. HTTP is unencrypted; keep the vCenter subscription on HTTPS and use HTTP only on trusted networks. See the blog for redirect and Require SSL troubleshooting.

## Safety and validation

This is a reconstructed, reviewed lab bundle, not a production-tested installer. See [VALIDATION.md](VALIDATION.md) for the exact checks performed. Back up IIS configuration and existing catalogs before changing an established deployment.

The automation installer refuses to replace an existing installation or scheduled task. This avoids silently overwriting an earlier working deployment. Existing users should compare the scripts and migrate deliberately, not run the quick start blindly.

Do not store upload credentials, private keys, certificate exports, logs, virtual environments, or ISO/OVA binaries in Git. Keep automation files administrator-controlled because the scheduled task runs as SYSTEM. Only the content directory is served by IIS.

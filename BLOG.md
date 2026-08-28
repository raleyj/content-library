# Building a Windows Server Content Library Publisher for vCenter

The goal for this lab was straightforward: keep ISOs and virtual appliances on a Windows Server and let vCenter subscribe to them as a Content Library. No iSCSI target, no new shared datastore, and no manual import of every file into every vCenter.

The solution combines IIS, an existing domain-issued certificate, a Python catalog generator, and a scheduled task. IIS hosts the files; the generator creates the metadata that makes the directory usable as a third-party VCSP publisher.

This post walks through the deployment and the problems encountered along the way. The accompanying PowerShell files are cleaned-up reconstructions, not an assertion that this exact bundle has been deployed unchanged on the original server.

## What we are building

```text
Completed ISO/OVA files
        |
        v
E:\ContentLibrary\<one folder per item>
        |
        +-- Python catalog generation every two hours
        |       lib.json / items.json / item.json
        |
        +-- IIS HTTPS publisher
                  |
                  +-- vCenter subscribed library --> selected vCenter datastore
                  |
                  +-- browser --> direct ISO download
```

Windows is the publisher, not the backing datastore for vCenter. The subscribed library still needs storage selected in vCenter for downloaded/cached content. The publisher URL points at `lib.json`, not merely the website homepage.

The original server ran Windows Server 2025 Datacenter, build 26100. Python 3.12.10 was verified working during troubleshooting. Use an appropriately maintained Python installation for a new deployment rather than treating that historical patch version as a requirement.

All hostnames in this post are examples. Replace `library.example.com` with your own DNS name.

## 1. Prepare the server and certificate

Before running the scripts, prepare:

- A Windows Server with the `E:` volume and sufficient capacity for the library.
- DNS resolving the publisher name to the server.
- Network access from vCenter and intended download clients.
- An existing certificate in `Cert:\LocalMachine\My`, with a private key and a SAN matching the publisher name.
- Trust in the certificate's issuing CA on the clients that will use it.
- An all-users, 64-bit Python installation and outbound access to the Python package index for initial dependency installation.

Use an elevated Windows PowerShell 5.1 console. This matters because the IIS management module and the original troubleshooting were based on Windows PowerShell.

Find the certificate thumbprint without exporting its private key:

```powershell
Get-ChildItem Cert:\LocalMachine\My |
    Select-Object Subject, Thumbprint, NotAfter, HasPrivateKey
```

Download this repository to a setup directory such as `C:\Setup\content-library`. Do not put its scripts or Python environment inside the IIS content directory.

## 2. Configure IIS for HTTPS and optional browsing

```powershell
Set-Location C:\Setup\content-library

.\scripts\Configure-VCSPWeb.ps1 `
    -PublisherFqdn 'library.example.com' `
    -CertificateThumbprint 'REPLACE_WITH_YOUR_THUMBPRINT' `
    -ContentRoot 'E:\ContentLibrary' `
    -AllowedRemoteAddress 'LocalSubnet' `
    -EnableDirectoryBrowsing
```

The script installs the IIS features, creates a dedicated application pool and site, binds the existing certificate, adds explicit static-file MIME mappings, and grants the pool read access to the content directory. It does not create a new certificate or modify the certificate's private key permissions.

Anonymous authentication is configured to use the application pool identity. This avoids a common mismatch: granting access to the application pool while IIS actually attempts the read as `IUSR`. Microsoft documents the default anonymous account and the empty-username application-pool behavior in its [anonymous authentication reference](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/authentication/anonymousauthentication/).

The firewall rules created by the script apply to Domain and Private profiles. `LocalSubnet` is intentionally limited: replace it with the necessary IPs or CIDRs when vCenter or download clients are on other networks. Review existing IIS-created firewall rules too; a new narrow rule does not cancel an existing broader allow rule.

Directory browsing is optional. It makes the homepage useful for a person who wants to select and download a specific ISO, but it also exposes file names to anyone who can reach the anonymous site. Keep it on a trusted network.

## 3. Use one folder per library item

The target layout looks like this:

```text
E:\ContentLibrary\
    lib.json
    items.json
    Windows-Server\
        Windows-Server.iso
        item.json
    Appliance\
        Appliance.ova
        item.json
```

The Python script treats each immediate child directory as a library item. Keep all files for an OVF package together in its item directory. Do not put another layer of subdirectories inside it.

Keep temporary uploads in a sibling location such as `E:\ContentLibrary-Staging`, not `E:\ContentLibrary\_staging`. A staging folder inside the published directory will be scanned as another item.

For this lab, the desired workflow was to drop completed ISO/OVA files at the top of `E:` and then organize them automatically:

```powershell
.\scripts\Organize-VCSPContent.ps1 -WhatIf
.\scripts\Organize-VCSPContent.ps1
```

The organizer scans only top-level ISO/OVA files. It creates a folder from each file's base name and moves the file into it. Existing destinations and name collisions are skipped, not overwritten. Extensions are normalized to lowercase for the upstream generator. Run it only after copying finishes; being able to open a file exclusively is useful but is not proof that a paused transfer is complete.

There is a subtle Windows permission issue here: moving a file within the same volume can preserve its old ACL. The organizer explicitly grants the IIS application pool read access and SYSTEM access after the move. It does not erase other ACL entries or override explicit deny rules. If an ACL change fails after a move, the file may already be in its destination; inspect it before retrying.

## 4. Install the catalog automation

The generator is the [Windows-oriented `make_vcsp_2022.py` from lamw/vmware-scripts](https://github.com/lamw/vmware-scripts/blob/2c2ce7b967f2e810a932ec34536e0b513e23a3d6/python/make_vcsp_2022.py). The repository includes an unchanged, pinned copy and its upstream license.

Even when using local storage, this version imports AWS and Azure modules at startup. That is why the requirements include `boto3`, `python-dateutil`, and `azure-storage-blob`. Local publishing does not require AWS or Azure credentials.

Verify the real Python executable first:

```powershell
& 'C:\Program Files\Python312\python.exe' --version
```

Then install the automation, substituting your actual interpreter path:

```powershell
.\scripts\Install-VCSPCatalogAutomation.ps1 `
    -LibraryName 'Published Content Library' `
    -ContentRoot 'E:\ContentLibrary' `
    -PythonPath 'C:\Program Files\Python312\python.exe' `
    -RunImmediately
```

This creates a dedicated virtual environment, installs dependencies, checks that the generator can load, and registers **Regenerate vCenter VCSP Catalog** as a SYSTEM task repeating every two hours. The task ignores overlapping scheduled instances; the runner also uses a mutex to prevent simultaneous runs through that runner.

Automation lives under `C:\ProgramData\VCSPCatalog`, outside the web root. The new installation directory is restricted to SYSTEM and administrators because allowing an upload user to edit a SYSTEM-run script would be a privilege-escalation path. Keep the underlying Python installation administrator-controlled as well.

The installer intentionally refuses to overwrite an existing installation or task. For a server already running an earlier version, back up the configuration and compare/migrate it manually. A failed fresh installation can leave a partial directory; inspect it rather than repeatedly rerunning the installer.

The package constraints are version ranges, not a reproducible lockfile. Capture and review exact installed versions if you need a controlled production build. The installer accepts an existing interpreter instead of silently installing the old runtime used in this lab; Python's [Windows documentation](https://docs.python.org/3.12/using/windows.html) explains installer options if you manage Python separately.

## 5. Verify generation before subscribing

Task registration and a successful `--help` output are not proof that the catalog was generated. Check the task and its log files:

```powershell
Get-ScheduledTaskInfo -TaskName 'Regenerate vCenter VCSP Catalog'
Get-ChildItem C:\ProgramData\VCSPCatalog\Logs |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 6

Get-Content E:\ContentLibrary\lib.json -Raw | ConvertFrom-Json
Get-Content E:\ContentLibrary\items.json -Raw | ConvertFrom-Json

Invoke-WebRequest 'https://library.example.com/lib.json' -UseBasicParsing
```

The original deployment reached HTTP 200 with JSON content returned from the publisher. That demonstrated the catalog endpoint was being served. It did not, by itself, demonstrate successful vCenter synchronization or deployment of an appliance.

Test a real ISO URL as well. A working `lib.json` does not guarantee every content file has the right permissions and MIME mapping.

## 6. Create the subscribed library in vCenter

In the vSphere Client, open Content Libraries and create a new library. Select the subscribed-library option and enter:

```text
https://library.example.com/lib.json
```

Select the download policy and the vCenter datastore that will hold downloaded content. Review certificate prompts carefully and verify the publisher's identity. Do not make certificate-validation bypasses the normal deployment procedure.

Synchronize the library, confirm the items appear, and download or use a test item. Exact labels vary by vSphere release. If subscription metadata fails, inspect `lib.json`, `items.json`, and the item-level `item.json` files; Broadcom documents a third-party publisher failure involving a missing [`selfHref` field](https://knowledge.broadcom.com/external/article/397243/subscribed-content-library-synchronizati.html).

Remember there are two schedules: Windows regenerates the publisher catalog, and vCenter synchronizes its subscription. For immediate visibility after adding files, run the Windows task, wait for it to finish successfully, and then synchronize in vCenter.

## 7. Allow HTTP as well, if needed

HTTPS remains the recommended subscription endpoint. For browser access on a trusted network, HTTP can coexist with it:

```powershell
.\scripts\Configure-VCSPWeb.ps1 `
    -PublisherFqdn 'library.example.com' `
    -CertificateThumbprint 'REPLACE_WITH_YOUR_THUMBPRINT' `
    -AllowedRemoteAddress 'LocalSubnet' `
    -EnableDirectoryBrowsing `
    -EnableHttp
```

This adds a host-header binding on TCP 80 and a scoped firewall rule without removing HTTPS. Browse to `http://library.example.com/` using the hostname, not the server IP.

If HTTP still fails, inspect the site's **SSL Settings → Require SSL**, HTTP Redirect settings, and URL Rewrite rules. The script deliberately does not silently remove existing security or redirect policies. Browser HTTPS-only mode or cached HSTS may also upgrade an HTTP URL; test the response with `curl.exe -I http://library.example.com/` to separate server behavior from browser behavior.

## Troubleshooting lessons from the deployment

| Symptom | What to check |
| --- | --- |
| Python opens the Microsoft Store or reports it was not found | A WindowsApps execution alias is not the actual interpreter. Use an explicit executable path. |
| Installer says Python is missing even though `python.exe` exists | Run that exact executable with `--version`. The lab showed a healthy runtime being rejected by earlier discovery logic. |
| `SyntaxError: '(' was never closed` in a `python -c` check | Windows PowerShell native argument quoting can alter embedded quotes. The scripts avoid that inline-code validation pattern. |
| Python installer reports confusing exit status | Use a waited process and installer logs; don't infer the cause from a stale native exit-code variable. |
| HTTP 401.3 / `0x80070005` | Check the actual anonymous identity and NTFS permissions, including ACLs retained by moved files. |
| Root homepage returns 403 but `lib.json` returns 200 | Directory browsing may be disabled and no default document exists. Check the IIS substatus; not every 403 is the same issue. |
| `Restart-Website` is not recognized | That cmdlet does not exist. Use `Stop-Website` / `Start-Website` when a restart is needed; most configuration changes apply immediately. |
| A new file is absent from vCenter | Check organization, catalog task completion, then subscription synchronization—in that order. |

## Operational limits worth knowing

This is a useful lab publisher, not a transactional content-management system. The upstream generator hashes content and rewrites catalog files in place. Large libraries can take time to scan, and a reader can overlap a metadata update. Keep copies complete before publishing, avoid changing files during generation, and design a stronger atomic/versioned publication process if your environment needs that guarantee.

The scheduled task has a 12-hour execution limit in this bundle. Measure real scan time and adjust it; recurring runs are skipped while a previous one remains active. Logs are retained, so establish a retention policy and monitor disk capacity. Back up the generated metadata as well as the payloads to preserve library identities across recovery.

Do not increase IIS `maxAllowedContentLength` to fix large downloads: that setting limits incoming request bodies, not outgoing ISO responses. Investigate actual disk, network, proxy, and timeout behavior instead.

Finally, anonymous browsing and downloads should not be exposed broadly just because the files are easy to host. Restrict network reachability, review existing firewall rules, protect scripts and keys, and keep HTTPS for the vCenter subscription.

## The result

The deployment provides a simple separation of responsibilities: Windows stores and serves the files, Python maintains the VCSP metadata, and vCenter consumes the subscribed library. The important finishing step is verification—not just seeing the task exist, but confirming a generated catalog, a downloadable payload, and a successful vCenter synchronization.

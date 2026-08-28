# Validation record

Checks performed on 2026-08-28 in the authoring workspace:

- All four deployment PowerShell scripts parsed successfully with Windows PowerShell 5.1.
- `tests/Test-LocalChecks.ps1` passed: script parsing, pinned generator SHA-256, and an organizer `-WhatIf` test proving the fixture stayed in place and no destination folder was created.
- `python -m py_compile make_vcsp_2022.py` passed with the locally available Python 3.14 interpreter. This is a syntax check, not dependency or runtime compatibility validation.
- The upstream Python file was kept byte-for-byte unchanged and its BSD-2-Clause license was included.

Not performed in this workspace:

- Windows Server role installation, IIS/certificate/firewall changes, or scheduled-task registration.
- Installation of the Python dependency set or full generator execution against a real media library.
- Real file moves/ACL changes, remote downloads, vCenter subscription synchronization, or appliance deployment.

The original conversation supplied evidence that Python 3.12.10 ran on Windows Server 2025 and that the publisher returned HTTP 200 with catalog JSON. Those observations apply to that earlier lab deployment, not an end-to-end test of this reconstructed bundle.

## Server acceptance checklist

1. Back up existing IIS configuration and catalog metadata; review parameter defaults.
2. Confirm certificate SAN, expiry, private key, and client CA trust.
3. Confirm content ACLs and network/firewall scope; inspect other existing allow rules.
4. Run catalog generation; inspect task exit status and both log files.
5. Fetch `lib.json`, `items.json`, an item JSON, and its payload from the actual client network.
6. Synchronize the subscribed library in vCenter and verify one usable item.
7. Add one new item, regenerate, and verify it appears after subscription sync.
8. Measure scan time, set log retention, and test backup/recovery before broader use.

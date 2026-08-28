# Validation record

## Provenance

On 2026-08-28, Justin supplied the five original scripts and confirmed he ran them on his server. They replace the earlier reconstructed bundle.

The public copies preserve their original logic, defaults, parameter names, and task behavior. Only the internal hostname in Enable-VCSPHttp.ps1 and Repair-VCSPPublisherAccess.ps1 is replaced by library.example.com. Line endings/trailing whitespace may differ.

The original files on Justin's computer were not modified.

## Evidence and checks

- User-reported use of these originals on the Windows Server.
- Earlier screenshots showed Python 3.12.10 running on Windows Server 2025 and an HTTP 200 catalog JSON response.
- All five originals passed Windows PowerShell 5.1 parsing.
- The restored public copies are compared with the originals after hostname substitution and whitespace normalization.
- The local test checks all five scripts' syntax, the reference generator hash, and the organizer's WhatIf behavior.

These checks are not a new end-to-end Windows Server deployment. The supplied evidence does not independently prove every optional path, vCenter synchronization, or appliance deployment.

## Acceptance checks for another environment

Confirm certificate identity/trust, content permissions, protected automation ACLs, network scope, successful task completion/logs, actual payload downloads, and vCenter subscription synchronization. Check at least one newly added item. Measure generation time against the one-hour task limit.

See [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md). Preserving a working lab baseline does not mean all edge cases are fixed.

# Known limitations of the working baseline

These are documented rather than silently changing the scripts Justin ran.

- **Paths:** installers default to D:\ContentLibrary; organizer and repair use E:\ContentLibrary. Pass explicit paths consistently.
- **Staging:** publisher creates _staging inside the root; automation relocates it. Do not rerun publisher or configure a staging path inside the root. The installer does not comprehensively validate path containment or links.
- **Anonymous access:** run the separate repair script after publisher setup. It assumes the pool identity created by the publisher. It grants access to the supplied path without checking it matches the site's actual physical path.
- **Moved files:** organizer preserves names/ACLs, performs no copy-completion check, and can combine same-basename ISO/OVA files in an existing directory. Use completed files, distinct base names, and lowercase .iso/.ova extensions. Inspect payload ACLs; granting inherited permissions on the root may not fix protected child ACLs.
- **Browsing:** explicitly disabled by publisher; enable separately if wanted.
- **HTTP:** its script can start a stopped website even with -WhatIf. It does not disable Require SSL/redirects.
- **Firewall:** rules allow inbound ports on Domain/Private profiles without remote-address restrictions. Scope them for your environment; inspect other allow rules too.
- **Automation security:** script/venv/underlying Python must be administrator-controlled because the task runs as SYSTEM. The installer also accepts per-user Python candidates; review permissions and SYSTEM access before using those.
- **Runtime provisioning:** original fallback is Python 3.12.10. Installer log paths containing spaces may require additional quoting. Dependency upgrades are not locked. A master-branch download can fail the pinned hash check if upstream changes; review rather than disabling verification.
- **Catalog generation:** one-hour task timeout may be too short for large media. Metadata is written in place, not atomically. Avoid concurrent edits and concurrent direct/manual generator invocations. Log cleanup occurs only after successful generation.
- **Publisher re-runs:** prerequisite changes happen before the existing-site check. ACL command exit codes and Windows feature installation results are not fully checked. Do not treat publisher setup as transactional or safely repeatable.
- **Certificates/bindings:** check SAN/trust yourself. Original HTTPS binding does not explicitly enable SNI, so review shared-server certificate bindings.
- **Request size:** maxAllowedContentLength is an upload/request-body limit, not an ISO download limit.
- **Hardening:** these lab scripts are not an internet-facing production publishing service. Back up catalogs and IIS configuration, restrict access, and test your own subscription/download workflow.

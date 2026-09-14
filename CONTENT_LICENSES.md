# ArkFile iOS Content Licenses

Application code licensing is separate from content licensing.

ArkFile iOS can display bundled sample content, preview catalog metadata, and downloaded ArkFile Essentials and Complete content. ArkFile maintains a private artifact-level ledger and distributes required notices with the app, title, reader, map, or package as appropriate.

## Current Content Areas

| Category | Typical Sources | License Notes |
|---|---|---|
| ZIM archives | Wikipedia/Wikimedia/Kiwix ZIM sources | Creative Commons Attribution-ShareAlike or source-specific terms commonly apply. |
| Books and documents | Public domain books, government/public-domain PDFs, curated guides | Public-domain status and source-specific terms must be verified per item. |
| Maps | OpenStreetMap, PMTiles/Protomaps-derived packages | Open Database License and visible attribution requirements may apply. |
| Preview catalog | Metadata generated from ArkFile Desktop catalog | Must not imply rights beyond the underlying content licenses. |
| Future AI/source maps | Model and content-derived indexes | Must include model license, source-map attribution, and no placeholder provenance before shipment. |

## Release Requirement

The normal release gate is risk-based:

- hard-block known prohibited, noncommercial, incompatible, red, or retired content and any concrete unmet source, attribution, notice, share-alike, modification, or redistribution obligation;
- review the report-mode ledger output, including non-catalog and bundled assets;
- require a private ledger review for every new or materially changed distributed artifact;
- permit an existing yellow/evidence-incomplete artifact only when the owner records risk acceptance and review confirms that its actual required notices are already present in the artifact or product; and
- do not represent the whole catalog as fully cleared while the evidence backlog remains incomplete.

The public website is a minimal index and correction route, not a public audit dump or a promise that every distributed title has completed green metadata. Green rows receive public title-level metadata. Accepted-yellow titles rely on the source/license/attribution paths already present in the artifact or product until the private evidence record is completed. Strict zero-yellow validation remains available as an optional full-coverage/deep-audit mode.

## Local Sharing Posture

Local Sharing uses the `installed-readable-open-library` product mode. After the
user explicitly starts a session, ArkFile shares every regular, readable,
non-retired item currently represented in the on-device library, including
bundled samples, downloaded content, legacy installs, and readable opened ZIM
imports. Missing license projection data, a missing install commit, storage
location, or a missing checksum does not remove an otherwise readable item from
the session. Verified refunds stop affected future downloads and updates, but
do not lock reading or Local Sharing of valid installed copies. Empty
entitlement snapshots, account changes, expired tokens, and service failures
also do not narrow the readable installed library.

The license and disposition records remain release-review evidence and may
provide receiver notices or checksum-based ETags when available. They are not a
runtime Local Sharing allowlist. ArkFile does not claim that user-imported
content was reviewed, licensed, or owned by ArkFile.

The session remains explicit, foreground-only, local-network-only, and
read-only. ArkFile freezes the exact regular-file identity for the session,
opens served files without following symlinks, contains child resources to
their selected roots, and stops or rejects a request when a file changes or
becomes unavailable. These serving-integrity rules protect the operation of the
local server; they do not narrow the installed library by license,
verification, or storage provenance.

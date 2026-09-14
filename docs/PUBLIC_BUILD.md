# Public Build Notes

ArkFile iOS uses XcodeGen and does not commit `Kiwix.xcodeproj`. Public source
contains the app source, project configuration, notices, dependency evidence,
and public build scripts. It excludes Apple credentials/signing material,
private release operations, paid content, generated map payloads, local
artifacts, and private repository history.

## Supported build

For a distribution-bound source release, run:

```sh
scripts/arkfile-public-build.sh
```

The script reads the reusable CoreKiwix source-and-relink URL and SHA-256 from
format-4 `SOURCE_RELEASE_MANIFEST.json`. That archive contains the controlled
framework as well as the corresponding source, build inputs, notices, and
relink material. The script safely downloads and extracts it, checks the
framework and native evidence against the reviewed certification receipt,
restores the SwiftPM lock, generates the project, and performs an unsigned
Release build for a generic iOS Simulator. The expensive five-target relink was
performed when the receipt was created and is not repeated for every build.

For a local review build, supply the same archive directly:

```sh
scripts/arkfile-public-build.sh \
  --xcodegen-archive /path/to/xcodegen.zip \
  --corekiwix-source-archive /path/to/CoreKiwix-14.2.0+arkfile.1-source-and-relink.tar.gz \
  --corekiwix-source-archive-sha256 <source-archive-sha256>
```

There is no separate framework download and no fallback to the old upstream
prebuilt archive. Changing the framework after verification invalidates the
native evidence.

Requirements are Xcode with the iOS SDK, `curl`, Git, Node.js, Perl, `plutil`,
Python 3, `shasum`, `tar`, `unzip`, Gitleaks 8.30.1, and TruffleHog 3.95.9.
Use `scripts/arkfile-install-secret-scanners.sh` to install the exact scanner
versions into a dedicated directory.

## Native recertification after a native change

```sh
scripts/arkfile-certify-corekiwix.sh \
  /path/to/CoreKiwix-14.2.0+arkfile.1-source-and-relink.tar.gz
```

This runs the full verifier and all five relinks, then writes the tracked byte
receipt used by routine checks. Commit the receipt with the native change.

## Other pinned inputs

`Dependencies/Package.resolved` is the reviewed SwiftPM resolution. The build
restores it into the generated workspace and verifies that it did not drift.
XcodeGen 2.45.4 is independently bound by
`Dependencies/XcodeGen-2.45.4.sha256`.

Public builds validate the checked-in content catalog without publishing paid
payloads or generated maps. Those payloads are separate from app corresponding
source and are represented by placeholder directories.

The exported project validates public notice and catalog data using
`--public-build`, without a private owner memo. A code-only build accepts the
exact generated sample README as the only file in its sample folder. Adding any
sample payload requires the complete reviewed inventory and matching hashes;
unexpected files and partial sample sets fail. Shipping builds always retain
full sample validation. These code-only builds omit the separately distributed
sample content and map payloads.

## Distribution boundary

A format-4 manifest with
`nativeCorrespondingSource.mode=complete-controlled-build` is distribution
evidence only when it is bound to the exact Build 360-or-later IPA and the
single published CoreKiwix archive URL/SHA. The same versioned native asset may
serve multiple app manifests while its identity is unchanged.
`review-only-unbound` is for local
inspection and must not be represented as matching source for a distributed
binary.

Public exports remove ArkFile's signing team. Use unsigned simulator builds or
provide your own signing configuration locally; never commit signing material.

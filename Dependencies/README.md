# Dependency Evidence

This directory keeps release dependency evidence in source control, outside
the generated and ignored `Kiwix.xcodeproj`.

## Swift Package Manager

`Package.resolved` is the reviewed lock for the current source line. Xcode
normally stores this file inside the generated project, which is ignored in
this repository. After running XcodeGen, restore the reviewed lock before
resolving or building:

```sh
scripts/arkfile-swiftpm-lock.sh restore
xcodebuild \
  -project Kiwix.xcodeproj \
  -scheme Kiwix \
  -resolvePackageDependencies \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile
```

Run `scripts/arkfile-swiftpm-lock.sh verify` after dependency resolution. A
package update is intentional release work: update `project.yml`, resolve once,
review the generated lock and upstream license changes, then replace this
source-controlled lock in the same change.

## CoreKiwix

Production Build 360 and later use controlled `CoreKiwix 14.2.0+arkfile.1`.
The reviewed exception policy, generated build manifest, source lock, SPDX
SBOM, ordered object map, curated notices, and exact secret-scan policy bind the
linked components and retained source/relink material. The three exact evidence
exceptions document two stale Xapian 1.4.26 directory labels around verified
1.4.23 source and one ICU data-only generated object. Every declared exception
must be used and every finding must be declared.

`scripts/arkfile-verify-corekiwix.sh` validates and binds the portable evidence
to the exact source-and-relink archive and installed framework, matches the
pinned Gitleaks/TruffleHog finding policy, and relinks all five targets. It does
not claim to regenerate private pre-normalization `BUILD_*` evidence and does
not accept the old upstream prebuilt archive. See `docs/UPSTREAM_PROVENANCE.md`.

The source-and-relink archive also contains the matching controlled framework.
For external distribution it is published once per exact native build in
`TheArkFile/arkfile-ios` and reused by matching app source releases. A self-only
internal TestFlight build retains and verifies it locally.

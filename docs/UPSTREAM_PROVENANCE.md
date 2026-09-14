# Upstream Provenance

ArkFile iOS is a modified downstream distribution based on Kiwix Apple. It is
independent and is not affiliated with, sponsored by, or endorsed by Kiwix,
openZIM, Wikimedia CH, Wikimedia Foundation, Apple, or Posit PBC.

## App source base

- Kiwix Apple: https://github.com/kiwix/kiwix-apple
- ArkFile base commit: `46f2e8655dfcbab069a1718b185e887473dd2de1`
- libkiwix source: `30adab733771835f25697e4f2ea18dc2eec4e92d` (`14.2.0`)
- libzim source: `8e51607a1866f9a2ec6eb428b136c5184974afe7` (`9.6.0`)

ArkFile-specific work includes branding, StoreKit and account flows, durable
content installs, offline maps, Saved Weather, Local
Sharing, preparedness tools, and product-specific UI.

## Controlled CoreKiwix build

Production Build 360 and later use `CoreKiwix 14.2.0+arkfile.1`, rebuilt from
the `kiwix-build` `r_103` recipe at
`23200d831c6070b3c90d5da78c05887b70f0d831`. The retained source/relink
archive covers the five thin targets used to create the distributed iOS,
iOS-simulator, and macOS XCFramework slices.

The exact linked component set is recorded in:

- `Dependencies/CoreKiwixNativeExceptions.json`
- `Dependencies/CoreKiwixNativeBuildManifest.json`
- `Dependencies/CoreKiwixNativeSource.lock.json`
- `Dependencies/CoreKiwixNativeSBOM.spdx.json`
- `Dependencies/CoreKiwixNativeObjectMap.jsonl`
- `Dependencies/CoreKiwixNativeSecretScanPolicy.json`
- `Dependencies/CoreKiwixNativeNotices/`

The reviewed exception policy records only two stale Xapian directory labels
around verified 1.4.23 source and one generated ICU data object without a
standalone compiler-source record. The evidence tool enforces two-sided use:
undeclared findings and unused exceptions both fail. The generated manifest
records the recipe/tool identity, all source inputs, component archives,
architectures, symbols, five thin archives, three distributed slices,
two-sided exception use, notices, and complete ordered object-member inventory
for the distributed iOS archive. Of 991 object records, 976 have one candidate
source, 14 retain multiple candidates, and one generated ICU data object has an
explicit reviewed exception because it has no standalone compiler-source
record. The evidence therefore claims neither complete candidate-source
coverage nor unique compiler-output-to-source attribution. The hash-bound
`source/ARCHIVE` inputs are authoritative; `source/SOURCE` is a review
convenience tree.

The exact CoreKiwix source-and-relink archive SHA-256 is a local release input.
For external distribution, publish that archive once in the versioned
`corekiwix-v14.2.0-arkfile.1` release in `TheArkFile/arkfile-ios`. Format-4
`SOURCE_RELEASE_MANIFEST.json` records its exact reusable URL and SHA-256. A
self-only internal TestFlight build retains and verifies the archive locally
and requires no public URL.

Create the single native source-and-relink archive after the evidence and notice
index are final:

```sh
node scripts/arkfile-package-corekiwix-source.mjs \
  --build-work /path/to/build-work \
  --framework CoreKiwix.xcframework \
  --recipe-root /path/to/kiwix-build \
  --recipe-lock Dependencies/CoreKiwixNativeBuildRecipe.lock.json \
  --tool-input-root /path/to/frozen-tool-inputs \
  --exceptions Dependencies/CoreKiwixNativeExceptions.json \
  --notices Dependencies/CoreKiwixNativeNotices \
  --evidence Dependencies \
  --secret-scan-policy Dependencies/CoreKiwixNativeSecretScanPolicy.json \
  --gitleaks "$(command -v gitleaks)" \
  --trufflehog "$(command -v trufflehog)" \
  --output /path/to/CoreKiwix-14.2.0+arkfile.1-source-and-relink.tar.gz
```

The packager refuses overwrite, links, special files, stale upstream hashes,
tree drift, and nondeterministic archive metadata. It includes the controlled
framework and relinks and verifies all five thin targets before retaining its
output. For external distribution, publish it once in the same public repository
and reuse it while the controlled native identity is unchanged. Each app-source
release manifest and one plain release-note line point to it. There is no
separate framework asset, native-artifact repository, or per-app reupload.

Install the two exact scanner versions used by the release policy when they are
not already available:

```sh
scripts/arkfile-install-secret-scanners.sh /path/to/dedicated/scanner-bin
export PATH="/path/to/dedicated/scanner-bin:$PATH"
```

Verify the exact installed framework against the exact source/relink archive:

```sh
scripts/arkfile-verify-corekiwix.sh \
  --framework CoreKiwix.xcframework \
  --source-archive /path/to/CoreKiwix-14.2.0+arkfile.1-source-and-relink.tar.gz \
  --source-archive-sha256 <exact-lowercase-sha256> \
  --evidence-dir Dependencies \
  --exceptions Dependencies/CoreKiwixNativeExceptions.json \
  --secret-scan-policy Dependencies/CoreKiwixNativeSecretScanPolicy.json
```

The verifier first pins and safely inventories the archive. It then binds the
checked evidence and policies, reconstructs the recipe Git tree, validates the
exact source/tool inputs and portable compiled/normalized evidence, checks the
framework/object/member/symbol identities, matches the exact reviewed scanner
baseline with network verification intentionally disabled, and relinks all five
targets. The 141 TruffleHog records are an exact reviewed candidate multiset;
their unverified status is not evidence that a candidate could not be live. Private
pre-normalization `BUILD_*` file digests remain archive-bound and are not
claimed as independently regenerated. The superseded upstream `14.2.0-1`
slice hashes remain deny-listed and are never accepted as production inputs.

This provenance record is technical evidence, not an independent legal opinion.

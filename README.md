# ArkFile iOS

ArkFile iOS is an independent universal offline-library app focused on
downloading, verifying, installing, and reading ArkFile Essentials and Complete
content on iPhone and iPad.

## Provenance

ArkFile iOS is a modified downstream distribution based on Kiwix Apple and uses CoreKiwix, libkiwix, libzim, and openZIM technology for offline ZIM reading.

Original upstream projects:

- Kiwix Apple: https://github.com/kiwix/kiwix-apple
- CoreKiwix / libkiwix: https://github.com/kiwix/libkiwix
- libzim / openZIM: https://github.com/openzim/libzim

ArkFile preserves applicable GPL licensing and upstream attribution. ArkFile is independent and is not affiliated with, sponsored by, or endorsed by Kiwix, openZIM, Wikimedia CH, Wikimedia Foundation, Apple, or Posit PBC.

## License

Application code is licensed under GPLv3-or-later unless otherwise noted. See [LICENSE](LICENSE), [NOTICE.md](NOTICE.md), and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

ArkFile trademarks, paid content-pack access, backend services, account entitlements, download URLs, and curated content bundles are separate from GPL app-code rights.

## App Store / GPL Notice

ArkFile publishes matching corresponding source no later than distribution for every external TestFlight build, App Store build, or build made available to anyone other than the sole developer. A self-only internal TestFlight build may omit publication only when the finalized release identity binds matching internal-only flags in the requested options, Xcode-produced options, and exact code-signed IPA, and the upload-time App Store Connect check confirms that every automatic recipient record belongs to the sole developer. ArkFile's paid content/download service does not restrict users' GPL rights in the application code.

Kiwix/openZIM outreach must not be described as permission, affiliation, or endorsement. Public upstream and binary-provenance details are recorded in [docs/UPSTREAM_PROVENANCE.md](docs/UPSTREAM_PROVENANCE.md).

## Source Releases

Corresponding source for each source-required build must be published through
matching release tags and GitHub Releases at:

https://github.com/TheArkFile/arkfile-ios

Source release archives are sanitized snapshots generated from shipped-build commits. They include app and widget runtime source, project configuration, reviewed dependency locks and hashes, the deterministic public-build entrypoint, provenance, notices, and a release manifest. They exclude private repository history, private test suites and title research, internal legal/release material, Apple credentials, signing material, paid content payloads, local AI/model packages, TestFlight artifacts, agent files, and private operations.

Distribution-bound releases include the verified CoreKiwix source-and-relink
archive, notices, controlled build evidence, and the reviewed attribution limits
recorded in the release manifest. The same versioned asset may be reused while
its native build identity and SHA-256 are unchanged.

## Development

Kiwix Apple uses XcodeGen and does not commit an `.xcodeproj`.

Public-source build notes are documented in [docs/PUBLIC_BUILD.md](docs/PUBLIC_BUILD.md). From a sanitized public checkout or source archive, the supported unsigned Simulator build is:

```sh
scripts/arkfile-public-build.sh
```

The script downloads or accepts local copies of the exact pinned XcodeGen and CoreKiwix archives, checks them against reviewed hashes and the CoreKiwix certification receipt, restores the reviewed SwiftPM lock, disables automatic package resolution and code signing, builds the Release configuration for a generic iOS Simulator, and fails if source files change.

The internal scheme/target names may still say `Kiwix` while the user-facing product is ArkFile. Legal/source clarity takes priority over broad project renaming until the build is stable.

## Support

For support, licensing, or attribution questions, contact support@thearkfile.com.

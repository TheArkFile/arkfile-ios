# Third-Party Dependency Inventory

This inventory records dependency identity and the license evidence currently
available for ArkFile iOS. CoreKiwix is now an ArkFile-controlled
`14.2.0+arkfile.1` build, not the old upstream prebuilt aggregate. Its frozen
recipe is recorded in `Dependencies/CoreKiwixNativeBuildRecipe.lock.json`, and
its component/embedded-asset notices and exact provenance are recorded in
`Dependencies/CoreKiwixNativeNotices/index.json`.

The notice index is engineering-complete for every identified controlled input.
That does not make this document a legal opinion. The single CoreKiwix source-
and-relink archive contains the controlled framework, corresponding source,
build inputs, notices, and relink material. It is validated against the build
manifest, source lock, SPDX SBOM, and object map. For external distribution it
is published once per exact native build in `TheArkFile/arkfile-ios`, reused by
matching app releases, and recorded by URL and SHA-256.

## iOS App And Direct Dependencies

| Component | Reviewed identity | License evidence | iOS use |
|---|---|---|---|
| Kiwix Apple | Upstream commit `46f2e8655dfcbab069a1718b185e887473dd2de1` | GPL-3.0-or-later in upstream source headers and app `LICENSE` | ArkFile iOS is a modified downstream distribution. |
| CoreKiwix / libkiwix | Controlled `14.2.0+arkfile.1`; libkiwix `14.2.0` at `30adab733771835f25697e4f2ea18dc2eec4e92d`; kiwix-build `r_103` at `23200d831c6070b3c90d5da78c05887b70f0d831` plus the locked ArkFile recipe diff | GPL-3.0-or-later plus the transitive and embedded notices bound by the native notice index | Static offline ZIM reader foundation. One verified source-and-relink archive retains the matching framework, corresponding source, and relink material. |
| Defaults | `8.2.0`, revision `38925e3cfacf3fb89a81a35b1cd44fd5a5b7e0fa` | MIT in the pinned package | Settings and persisted preferences. |
| ZIPFoundation | `0.9.20`, revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` | MIT in the pinned package | HTML-book ZIP extraction. |
| MapLibre Native | `6.14.0`, wrapper revision `60d9bb85c94ce6e7fc4406cd32529fd12bdb7809`; binary checksum `2af8a5e52252265835500c5b575e64107dbc5867de6e849fab2d91fa4e416920` | BSD-2-Clause in the pinned package and binary artifact | Native offline map rendering. |
| Protomaps Basemaps style | `@protomaps/basemaps` `5.7.2`, npm source commit `3ea8293a28131c3dc63f1bb20827bdb8a76df06f` | BSD-3-Clause code, CC0 visual design, and identified MIT-derived icon notices in upstream `LICENSE.md` | Generated MapLibre style data; map data attribution is separate. |
| Protomaps basemap assets | `protomaps/basemaps-assets` tree `028c18f713baecad011301ff7a69acc39bcc2ae7` | Asset source identity is recorded in `content/maps/base/manifest.json`; exact asset notice review remains part of the map release record | Offline glyph and sprite assets. |
| Noto Fonts | Bundled font glyph assets with `content/maps/base/assets/fonts/OFL.txt` | SIL Open Font License 1.1 and copyright notice travel with the assets | Offline map labels. |

Exact Swift package pins are tracked in `Dependencies/Package.resolved`. The
generated `Kiwix.xcodeproj` is ignored and is not the dependency record.

## Native Components Identified Inside CoreKiwix

These shipped components are inputs to the controlled recipe and are bound to
exact source archives or Git commits and notice hashes by the build-recipe lock
and notice index.

| Component | Controlled version | License conclusion and retained notice files |
|---|---|---|
| libkiwix | `14.2.0`, commit `30adab733771835f25697e4f2ea18dc2eec4e92d` | GPL-3.0-or-later plus embedded materials; `libkiwix-COPYING-GPL-3.0.txt`, `libkiwix-AUTHORS.txt` |
| libzim / openZIM | `9.6.0`, commit `8e51607a1866f9a2ec6eb428b136c5184974afe7` | GPL-2.0-or-later and BSD-3-Clause; `libzim-COPYING-GPL-2.0.txt`, `libzim-AUTHORS.txt`, `libzim-lrucache-BSD-3-Clause.txt` |
| zlib | `1.3.1` | Zlib; `zlib-LICENSE-Zlib.txt` |
| Zstandard | `1.5.7` | BSD-3-Clause selected from the upstream dual-license options; `zstd-LICENSE-BSD-3-Clause.txt`, `zstd-COPYING-GPL-2.0.txt` |
| liblzma / XZ Utils | `5.2.6` | Controlled composite/public-domain statement; `xz-COPYING.txt`, `xz-AUTHORS.txt`, and the GPL-2.0, GPL-3.0, and LGPL-2.1 texts retained beside it |
| Xapian | `1.4.23` | GPL-2.0-or-later plus MIT, BSD-3-Clause, BSL-1.0, and Unicode-DFS-2016 subcomponents; six `xapian-*` notice files in the notice index |
| curl | `8.4.0` | curl license; `curl-COPYING.txt` |
| ICU | `73.2` | Composite ICU and bundled third-party notices preserved without reducing them to one expression; `icu-LICENSE-composite.txt` |
| GNU libmicrohttpd | `0.9.76` | LGPL-2.1-or-later; `libmicrohttpd-COPYING-LGPL-2.1.txt`, `libmicrohttpd-AUTHORS.txt`; corresponding source and relinkable static-link material are mandatory release artifacts |
| pugixml | `1.15` | MIT; `pugixml-LICENSE-MIT.txt` |
| kainjow Mustache | `4.1` | BSL-1.0; `mustache-cpp-LICENSE-BSL-1.0.txt` |

## Compiled And Embedded Materials Inside libkiwix

| Material | Controlled identity | License conclusion and retained notice files |
|---|---|---|
| autoComplete | Exact embedded `autoComplete.min.js` | Apache-2.0; `autoComplete-LICENSE-Apache-2.0.txt` |
| libkiwix lrucache | Exact `src/tools/lrucache.h` | BSD-3-Clause; `libkiwix-lrucache-BSD-3-Clause.txt` |
| libkiwix base64 | Exact `src/tools/base64.cpp` | Zlib; `libkiwix-base64-Nyffenegger-Zlib.txt` |
| Isotope package | `3.0.6`, exact embedded package hash | GPL-3.0-only for Isotope's open-source use plus MIT for jquery-bridget `2.0.1`, ev-emitter `1.1.0`, get-size `2.0.3`, matches-selector `2.0.2`, fizzy-ui-utils `2.0.7`, outlayer `2.1.1`, and Masonry `4.2.1`; `libkiwix-isotope-attributions.txt`, `isotope-bundled-mit-tagged-attributions.txt`, `spdx-MIT-template.txt`, and the libkiwix GPL text |
| mustache.js | `4.2.0`, exact embedded file hash and upstream release commit `bd29972ab8a0f4c592f35483615ab9a274396300` | MIT; `libkiwix-mustache-js-identity.txt`, `mustache-js-LICENSE-MIT.txt` |
| DM Sans | Exact embedded binary hash; upstream OFL terms pinned at `a9ec422410bd9b5b0e438ef6a1355d1f1702e963` | OFL-1.1; `libkiwix-font-metadata-attributions.txt`, `dm-sans-LICENSE-OFL-1.1.txt` |
| Poppins | Exact embedded binary hash; upstream OFL terms pinned at `311d7fa87bdf7cd5cc4210a91bac56d5512a3013` | OFL-1.1; `libkiwix-font-metadata-attributions.txt`, `poppins-LICENSE-OFL-1.1.txt` |
| Roboto | `2.137`, exact embedded binary hash | Apache-2.0; `libkiwix-font-metadata-attributions.txt` and the retained Apache-2.0 text |

The seven exact Isotope dependency tags omit standalone license files. Each
tagged `package.json` MIT declaration, David DeSandro author attribution, and
source header is SHA-256-bound in the notice index and paired with the canonical
MIT text from SPDX License List `v3.28.0`. This is explicit provenance, not an
assertion that those upstream repositories supplied files they did not contain.

Build-only inputs are also retained: kiwix-build `r_103` under GPL-3.0-only and
the Meson wrap-generated build files under MIT. They are not presented as
runtime iOS libraries.

## Project Dependencies Excluded From The iOS Target

These packages remain part of the shared XcodeGen project for macOS. They are
locked for reproducibility but are filtered out of the iOS target and should
not be presented as shipped iOS libraries.

| Component | Reviewed identity | License |
|---|---|---|
| StripeApplePay | `25.7.2`, revision `f88ad4685e09c154370a441fa7bafd48f553a3bb` | MIT |
| StripeCore | `25.7.2`, revision `ef6d95d4a74796bb739df49dc41d24f1d58a6d2a` | MIT |
| Swift System | revision `b083113aef646d9d35403ca17e9789b750e42d1d` | Apache-2.0 with Runtime Library Exception |

## Release evidence

- Generate and validate the native build manifest, source lock, SPDX SBOM, and
  object map against the single source-and-relink archive and installed
  framework. Check in evidence only when it matches the framework byte-for-byte.
- Before external distribution, publish that archive once in its versioned
  `TheArkFile/arkfile-ios` native release; verify anonymous download and bind
  its URL/SHA-256 in each matching app source manifest. The app release notes
  also include one plain line linking it.
- Have the owner or counsel decide whether the complete evidence and delivery
  mechanism satisfy the applicable GPL/LGPL/OFL and notice obligations; the
  engineering `coverageComplete` flag is not that decision.
- Confirm the exact Protomaps asset notice set for the frozen asset tree rather
  than relying only on a repository name and branch.
- Keep the bundled in-app document labeled as notices and license references.
  It now directly identifies every notice in the controlled CoreKiwix index,
  and the build's source-release URL must resolve to the identity-bound source
  and relink material.

If a source header, pinned package license, or matching upstream release notice
conflicts with this summary, that primary evidence controls and this inventory
must be corrected before release.

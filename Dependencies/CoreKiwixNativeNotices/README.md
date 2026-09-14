# CoreKiwix native notices

This directory is the curated notice input for ArkFile's controlled
`CoreKiwix 14.2.0+arkfile.1` build. `index.json` binds each shipped component
or embedded asset to its exact source input and to the SHA-256 digest of the
notice material retained here.

Full component license and author wording is copied verbatim from the
controlled source tree or a pinned immutable upstream source; repository text
files normalize line endings or a missing final newline where necessary. Files
named for an inline component are exact excerpts or metadata transcriptions of
the cited source. `libkiwix-font-metadata-attributions.txt` is an exact
transcription of the copyright, author, license-description, and license-URL
records in the three shipped font binaries.

## Closed standalone-text coverage

The standalone-text gaps in the controlled libkiwix tree are closed with
immutable upstream evidence:

- the full DM Sans and Poppins OFL-1.1 files come from pinned upstream font
  release tags and are paired with the exact attribution metadata extracted
  from the embedded font binaries;
- the mustache.js 4.2.0 MIT file comes from its exact upstream release tag; and
- the seven MIT dependencies bundled by Isotope 3.0.6 are each bound to their
  exact upstream release tag, package declaration, author, and source header.
  Those seven tags do not contain standalone license files, so their tagged
  attribution evidence is paired with `text/MIT.txt` from the immutable SPDX
  License List v3.28.0 release.

`index.json` records every tag, commit, Git blob, raw URL, source SHA-256, and
packaged-notice SHA-256. Its `coverageComplete` value means that the engineering
inventory has source and notice evidence for every identified input; it is not
an unsupported claim that the distribution has received legal approval.

The libmicrohttpd entry also requires the corresponding source and relinkable
static-link material described by `CoreKiwixNativeBuildRecipe.lock.json` and
the separately generated source/object evidence. Whether the resulting
distribution package satisfies all license obligations remains an owner/legal
review decision.

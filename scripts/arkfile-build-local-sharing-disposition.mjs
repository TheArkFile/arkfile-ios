#!/usr/bin/env node
'use strict';

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_CATALOG_PATH = path.join(
  ROOT_DIR,
  'Support',
  'ArkFileContentCatalog',
  'content-catalog.json',
);
const DEFAULT_PUBLIC_LICENSE_INDEX_PATH = path.join(
  ROOT_DIR,
  'Support',
  'ArkFileContentLicenses',
  'content-license-index.json',
);
const DEFAULT_OWNER_ACCEPTANCE_PATH = path.join(
  ROOT_DIR,
  'ReleaseInputs',
  'local-sharing-owner-acceptance.json',
);
const DEFAULT_PUBLIC_NOTICES_PATH = path.join(
  ROOT_DIR, 'Support', 'ArkFileLocalSharing', 'local-sharing-public-notices.json',
);
const DEFAULT_OUTPUT_PATH = path.join(
  ROOT_DIR,
  'Support',
  'ArkFileLocalSharing',
  'local-sharing-disposition-index.json',
);
const DEFAULT_SAMPLE_ROOT = path.join(
  ROOT_DIR,
  'content',
  'base-sample-content',
);

const POLICY_VERSION = 'local-sharing-v1';
const REQUIRED_BUNDLED_SAMPLE_COUNT = 5;
// Keep these bytes identical to the code-only public source exporter placeholder.
const PUBLIC_SAMPLE_PLACEHOLDER = `# Base Sample Content Placeholder

Bundled sample-content payloads are excluded from public app-code source
releases. This exact README is the only permitted file for a code-only public
build. When sample payloads are supplied, complete inventory and SHA-256
validation apply. Shipping builds always require the reviewed sample payloads.
`;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const ALLOWED_TYPES = new Set(['zim', 'pdf', 'htmlbook', 'image', 'html', 'map']);
const EVIDENCE_STATUSES = new Set(['green', 'yellow', 'red']);
const DISPOSITIONS = new Set(['allow', 'block']);
const MANIFEST_SPECS = [
  {
    argument: 'currentLiteManifest',
    flag: '--current-lite-manifest',
    id: 'current-lite-full',
    role: 'current',
    variant: 'lite-full',
    tier: 'lite',
    sourceEdition: 'lite',
    hashGroup: 'currentManifestSHA256s',
    hashKey: 'liteFull',
  },
  {
    argument: 'currentCompleteManifest',
    flag: '--current-complete-manifest',
    id: 'current-complete-20260711',
    role: 'current',
    variant: 'complete-full',
    tier: 'complete',
    sourceEdition: 'full',
    hashGroup: 'currentManifestSHA256s',
    hashKey: 'completeFull',
  },
  {
    argument: 'currentCompleteFromLiteManifest',
    flag: '--current-complete-from-lite-manifest',
    id: 'current-complete-from-lite-20260711',
    role: 'current',
    variant: 'complete-from-lite',
    tier: 'complete',
    sourceEdition: 'full',
    hashGroup: 'currentManifestSHA256s',
    hashKey: 'completeFromLite',
  },
  {
    argument: 'retainedCompleteManifest',
    flag: '--retained-complete-manifest',
    id: 'retained-complete-20260708',
    role: 'retained',
    variant: 'complete-full',
    tier: 'complete',
    sourceEdition: 'full',
    hashGroup: 'retainedManifestSHA256s',
    hashKey: 'complete20260708',
  },
  {
    argument: 'retainedTextbooksManifest',
    flag: '--retained-textbooks-manifest',
    id: 'retained-complete-textbooks-20260704',
    role: 'retained',
    variant: 'complete-full',
    tier: 'complete',
    sourceEdition: 'full',
    hashGroup: 'retainedManifestSHA256s',
    hashKey: 'completeTextbooks20260704',
  },
];

function parseArgs(argv) {
  const args = {
    validateOnly: false,
    publicBuild: false,
    publicNotices: DEFAULT_PUBLIC_NOTICES_PATH,
    catalog: '',
    ledger: '',
    currentLiteManifest: '',
    currentCompleteManifest: '',
    currentCompleteFromLiteManifest: '',
    retainedCompleteManifest: '',
    retainedTextbooksManifest: '',
    sampleEvidence: '',
    sampleRoot: '',
    ownerAcceptance: '',
    publicLicenseIndex: DEFAULT_PUBLIC_LICENSE_INDEX_PATH,
    output: DEFAULT_OUTPUT_PATH,
  };

  const pathArguments = new Map([
    ['--catalog', 'catalog'],
    ['--ledger', 'ledger'],
    ['--current-lite-manifest', 'currentLiteManifest'],
    ['--current-complete-manifest', 'currentCompleteManifest'],
    ['--current-complete-from-lite-manifest', 'currentCompleteFromLiteManifest'],
    ['--retained-complete-manifest', 'retainedCompleteManifest'],
    ['--retained-textbooks-manifest', 'retainedTextbooksManifest'],
    ['--sample-evidence', 'sampleEvidence'],
    ['--sample-root', 'sampleRoot'],
    ['--owner-acceptance', 'ownerAcceptance'],
    ['--public-license-index', 'publicLicenseIndex'],
    ['--public-notices', 'publicNotices'],
    ['--output', 'output'],
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--validate-only') {
      args.validateOnly = true;
    } else if (argument === '--public-build') {
      args.publicBuild = true;
    } else if (argument === '--help' || argument === '-h') {
      printHelp();
      process.exit(0);
    } else if (pathArguments.has(argument)) {
      const value = argv[++index];
      if (!value) fail(`${argument} requires a path`);
      args[pathArguments.get(argument)] = path.resolve(value);
    } else {
      fail(`Unknown argument: ${argument}`);
    }
  }

  if (args.publicBuild && !args.validateOnly) {
    fail('--public-build is only supported with --validate-only');
  }
  if (args.validateOnly) {
    args.catalog ||= DEFAULT_CATALOG_PATH;
    args.ownerAcceptance ||= DEFAULT_OWNER_ACCEPTANCE_PATH;
    args.sampleRoot ||= DEFAULT_SAMPLE_ROOT;
  }
  return args;
}

function printHelp() {
  console.log(`Usage:
  scripts/arkfile-build-local-sharing-disposition.mjs --validate-only [--output PATH] [--catalog PATH] [--owner-acceptance PATH] [--public-license-index PATH] [--sample-root PATH] [--public-notices PATH] [--public-build]

  scripts/arkfile-build-local-sharing-disposition.mjs \\
    --catalog PATH \\
    --ledger PATH \\
    --current-lite-manifest PATH \\
    --current-complete-manifest PATH \\
    --current-complete-from-lite-manifest PATH \\
    --retained-complete-manifest PATH \\
    --retained-textbooks-manifest PATH \\
    --sample-evidence PATH \\
    --owner-acceptance PATH \\
    [--public-license-index PATH] \\
    [--output PATH]

Generation requires every source path explicitly. The private evidence ledger and
release manifests are build-time inputs only; the generated runtime projection
contains no private filesystem paths. --validate-only validates the checked-in
projection, catalog, public green index, public notices, and private owner record.
It requires the exact projected bundled sample inventory at --sample-root
(default: content/base-sample-content). --public-build omits the private owner
record dependency and permits the exporter's exact README as the only sample
input. If any sample payload is supplied, the complete inventory and hashes
remain required. Shipping validation never accepts the public placeholder.
`);
}

function log(message) {
  console.log(`[arkfile-local-sharing-disposition] ${message}`);
}

function fail(message) {
  console.error(`[arkfile-local-sharing-disposition] ERROR: ${message}`);
  process.exit(1);
}

function readJSON(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Could not read ${filePath}: ${error.message}`);
  }
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function sha256String(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

/**
 * This order is a cross-runtime contract with iOS:
 * Unicode NFC, slash normalization, leading/trailing slash trim, lowercase.
 */
function canonicalizeRelativePath(value) {
  return String(value || '')
    .normalize('NFC')
    .replace(/\\/g, '/')
    .replace(/^\/+|\/+$/g, '')
    .toLowerCase();
}

function displayRelativePath(value) {
  return String(value || '')
    .normalize('NFC')
    .replace(/\\/g, '/')
    .replace(/^\/+|\/+$/g, '');
}

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(',')}]`;
  }
  if (value && typeof value === 'object') {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

function compareStrings(lhs, rhs) {
  return lhs < rhs ? -1 : lhs > rhs ? 1 : 0;
}

function projectionHashFor(projection) {
  const { projectionHash: _ignored, ...hashableProjection } = projection;
  return sha256String(stableStringify(hashableProjection));
}

const MANIFEST_SEMANTIC_FINGERPRINT_CONTRACT =
  'arkfile-install-manifest-semantic-v1';

/**
 * Field-by-field, cross-runtime framing for install-authoritative manifest
 * semantics. This deliberately does not hash a generic JSON re-encoding: the
 * backend may wrap or re-serialize a manifest without changing what iOS will
 * install.
 */
function semanticFingerprintForManifest(manifest) {
  const chunks = [];
  const append = (name, value) => {
    if (value == null) {
      chunks.push(`${name}:-\n`);
      return;
    }
    const normalized = String(value).normalize('NFC');
    chunks.push(
      `${name}:${Buffer.byteLength(normalized, 'utf8')}:`,
      normalized,
      '\n',
    );
  };
  const semanticPath = (value) => String(value || '')
    .normalize('NFC')
    .replace(/\\/g, '/')
    .replace(/^\/+|\/+$/g, '');
  const semanticString = (value) => String(value || '').normalize('NFC');
  const integer = (value, label) => {
    if (value == null) return null;
    const result = Number(value);
    if (!Number.isSafeInteger(result)) {
      throw new Error(`Manifest semantic field ${label} is not a safe integer`);
    }
    return result;
  };
  const optionalBoolean = (value, label) => {
    if (value == null) return null;
    if (typeof value !== 'boolean') {
      throw new Error(`Manifest semantic field ${label} is not a boolean`);
    }
    return value ? '1' : '0';
  };
  const compareSemanticStrings = (lhs, rhs) => Buffer.compare(
    Buffer.from(lhs, 'utf8'),
    Buffer.from(rhs, 'utf8'),
  );

  append('contract', MANIFEST_SEMANTIC_FINGERPRINT_CONTRACT);
  append('format', integer(manifest?.format, 'format'));
  append('product', manifest?.product);
  append('variant', manifest?.variant);
  append('tier', manifest?.tier);
  append('baselineTier', manifest?.baselineTier);
  append('deliveryMode', manifest?.deliveryMode);
  append('sourceEdition', manifest?.sourceEdition);
  append('baselineEdition', manifest?.baselineEdition);
  append('installMode', manifest?.installMode);
  append('installedBytes', integer(manifest?.installedBytes, 'installedBytes'));
  append('filesIncluded', integer(manifest?.filesIncluded, 'filesIncluded'));
  append('bytesIncluded', integer(manifest?.bytesIncluded, 'bytesIncluded'));
  append('generatedAt', manifest?.generatedAt);
  append(
    'compat.contentSchema',
    integer(manifest?.compat?.contentSchema, 'compat.contentSchema'),
  );
  append('compat.minDesktopVersion', manifest?.compat?.minDesktopVersion);
  append(
    'compat.minIOSBuild',
    integer(manifest?.compat?.minIOSBuild, 'compat.minIOSBuild'),
  );

  const deletedPaths = [...(manifest?.deletedPaths || [])]
    .map(semanticPath)
    .sort(compareSemanticStrings);
  append('deletedPaths.count', deletedPaths.length);
  deletedPaths.forEach((deletedPath, index) => {
    append(`deletedPaths.${index}`, deletedPath);
  });

  const files = [...(manifest?.files || [])].map((file) => ({
    relativePath: semanticPath(file.relativePath),
    objectKey: semanticString(file.objectKey),
    sizeBytes: integer(file.sizeBytes, `files.${file.relativePath}.sizeBytes`),
    sha256: file.sha256 == null ? null : String(file.sha256).toLowerCase(),
    mode: integer(file.mode, `files.${file.relativePath}.mode`),
    variantGroup: file.variantGroup,
    variantLabel: file.variantLabel,
    variantDefault: optionalBoolean(
      file.variantDefault,
      `files.${file.relativePath}.variantDefault`,
    ),
  })).sort((lhs, rhs) => (
    compareSemanticStrings(
      canonicalizeRelativePath(lhs.relativePath),
      canonicalizeRelativePath(rhs.relativePath),
    )
    || compareSemanticStrings(lhs.relativePath, rhs.relativePath)
    || compareSemanticStrings(lhs.objectKey, rhs.objectKey)
  ));
  append('files.count', files.length);
  files.forEach((file, index) => {
    append(`files.${index}.relativePath`, file.relativePath);
    append(`files.${index}.objectKey`, file.objectKey);
    append(`files.${index}.sizeBytes`, file.sizeBytes);
    append(`files.${index}.sha256`, file.sha256);
    append(`files.${index}.mode`, file.mode);
    append(`files.${index}.variantGroup`, file.variantGroup);
    append(`files.${index}.variantLabel`, file.variantLabel);
    append(`files.${index}.variantDefault`, file.variantDefault);
  });
  return sha256String(chunks.join(''));
}

function artifactIdentityKey(identity) {
  return `${identity.sizeBytes}:${identity.sha256}`;
}

function acceptedArtifactBinding(entries) {
  const acceptedEntries = entries.filter(
    (entry) => entry.evidenceStatus === 'yellow' && entry.disposition === 'allow',
  );
  const artifacts = acceptedEntries
    .flatMap((entry) => entry.acceptedIdentities.map((identity) => ({
      contentId: entry.contentId,
      canonicalPath: entry.canonicalPath,
      type: entry.type,
      sizeBytes: identity.sizeBytes,
      sha256: identity.sha256,
    })))
    .sort((lhs, rhs) => {
      const left = stableStringify(lhs);
      const right = stableStringify(rhs);
      return compareStrings(left, right);
    });

  return {
    acceptedArtifactCount: acceptedEntries.length,
    acceptedIdentityCount: artifacts.length,
    acceptedArtifactSetSHA256: sha256String(stableStringify(artifacts)),
  };
}

function catalogItems(catalog) {
  if (!catalog || typeof catalog !== 'object' || !catalog.categories) return [];
  return Object.values(catalog.categories).flat();
}

function mapByCanonicalPath(items, pathSelector, label) {
  const result = new Map();
  for (const item of items) {
    const canonicalPath = canonicalizeRelativePath(pathSelector(item));
    if (!canonicalPath) throw new Error(`${label} contains an empty relative path`);
    if (result.has(canonicalPath)) {
      throw new Error(`${label} contains a canonical path collision: ${canonicalPath}`);
    }
    result.set(canonicalPath, item);
  }
  return result;
}

function manifestMetadata(source) {
  const manifest = source.manifest;
  return {
    id: source.spec.id,
    role: source.spec.role,
    variant: String(manifest.variant || ''),
    tier: String(manifest.tier || ''),
    sourceEdition: String(manifest.sourceEdition || ''),
    generatedAt: String(manifest.generatedAt || ''),
    sha256: source.sha256,
    semanticFingerprint: semanticFingerprintForManifest(manifest),
  };
}

function manifestEntryMap(source) {
  return mapByCanonicalPath(
    source.manifest.files || [],
    (entry) => entry.relativePath,
    `manifest ${source.spec.id}`,
  );
}

function normalizedIdentity(entry, manifestID) {
  const sizeBytes = Number(entry.sizeBytes);
  const sha256 = String(entry.sha256 || '').toLowerCase();
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes <= 0) {
    throw new Error(`${manifestID} has an invalid size for ${entry.relativePath}`);
  }
  if (!SHA256_PATTERN.test(sha256)) {
    throw new Error(`${manifestID} has an invalid SHA-256 for ${entry.relativePath}`);
  }
  return { sizeBytes, sha256 };
}

function addIdentity(identityMap, identity, manifestID = '') {
  const key = artifactIdentityKey(identity);
  const existing = identityMap.get(key) || {
    sizeBytes: identity.sizeBytes,
    sha256: identity.sha256,
    manifestIDs: [],
  };
  if (manifestID && !existing.manifestIDs.includes(manifestID)) {
    existing.manifestIDs.push(manifestID);
  }
  identityMap.set(key, existing);
}

function sortedIdentities(identityMap) {
  return [...identityMap.values()]
    .map((identity) => ({
      ...identity,
      manifestIDs: [...identity.manifestIDs].sort(),
    }))
    .sort((lhs, rhs) => (
      lhs.sizeBytes - rhs.sizeBytes
      || compareStrings(lhs.sha256, rhs.sha256)
    ));
}

function multipartZIMAnchor(canonicalPath) {
  const match = canonicalPath.match(/^(.*\.zim)[a-z]{2}$/);
  return match ? match[1] : '';
}

function mapRegionPrefix(canonicalPath) {
  const components = canonicalPath.split('/');
  if (
    components.length >= 4
    && components[0] === 'maps'
    && components[1] === 'regions'
    && components[2]
  ) {
    return `maps/regions/${components[2]}/`;
  }
  return '';
}

function compatibilityMembersForEntry(entry, manifestSources) {
  const members = new Map();
  const mapPrefix = entry.type === 'map' ? mapRegionPrefix(entry.canonicalPath) : '';

  for (const source of manifestSources) {
    for (const manifestEntry of source.manifest.files || []) {
      const memberPath = displayRelativePath(manifestEntry.relativePath);
      const canonicalMemberPath = canonicalizeRelativePath(memberPath);
      const zimAnchor = multipartZIMAnchor(canonicalMemberPath);
      const isMapMember = mapPrefix && canonicalMemberPath.startsWith(mapPrefix);
      const isMultipartMember = entry.type === 'zim' && zimAnchor === entry.canonicalPath;
      if (!isMapMember && !isMultipartMember) continue;

      const identity = normalizedIdentity(manifestEntry, source.spec.id);
      const key = `${canonicalMemberPath}:${artifactIdentityKey(identity)}`;
      const existing = members.get(key) || {
        relativePath: memberPath,
        sizeBytes: identity.sizeBytes,
        sha256: identity.sha256,
        manifestIDs: [],
      };
      if (!existing.manifestIDs.includes(source.spec.id)) {
        existing.manifestIDs.push(source.spec.id);
      }
      members.set(key, existing);
    }
  }

  const sorted = [...members.values()]
    .map((member) => ({ ...member, manifestIDs: [...member.manifestIDs].sort() }))
    .sort((lhs, rhs) => {
      const leftPath = canonicalizeRelativePath(lhs.relativePath);
      const rightPath = canonicalizeRelativePath(rhs.relativePath);
      return compareStrings(leftPath, rightPath)
        || lhs.sizeBytes - rhs.sizeBytes
        || compareStrings(lhs.sha256, rhs.sha256);
    });

  const identityByPath = new Map();
  for (const member of sorted) {
    const canonicalMemberPath = canonicalizeRelativePath(member.relativePath);
    const identity = artifactIdentityKey(member);
    const prior = identityByPath.get(canonicalMemberPath);
    if (prior && prior !== identity) {
      throw new Error(
        `Compatibility member ${member.relativePath} has conflicting retained identities; `
        + 'versioned group alternatives must be projected separately',
      );
    }
    identityByPath.set(canonicalMemberPath, identity);
  }

  return sorted.length > 1 ? sorted : [];
}

const PUBLIC_NOTICE_FIELDS = [
  'sourceTitle', 'creators', 'publisher', 'canonicalURL',
  'attributionText', 'changesMade', 'rightsSummary',
];

function onlyKeys(value, allowed, label, errors) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    errors.push(`${label} must be an object`);
    return false;
  }
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) errors.push(`${label} contains an unapproved field: ${key}`);
  }
  return true;
}

function validatePublicNotice(notice, label, errors) {
  if (!onlyKeys(notice, PUBLIC_NOTICE_FIELDS, label, errors)) return;
  for (const field of ['sourceTitle', 'attributionText', 'changesMade', 'rightsSummary']) {
    if (typeof notice[field] !== 'string' || !notice[field].trim()) {
      errors.push(`${label}.${field} must be a non-empty string`);
    }
  }
  if (!Array.isArray(notice.creators) || notice.creators.some((value) => typeof value !== 'string')) {
    errors.push(`${label}.creators must contain strings`);
  }
  if (notice.publisher !== null && typeof notice.publisher !== 'string') {
    errors.push(`${label}.publisher must be a string or null`);
  }
  if (notice.canonicalURL !== null) {
    try {
      const url = new URL(notice.canonicalURL);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw new Error();
    } catch {
      errors.push(`${label}.canonicalURL must be a public HTTP URL or null`);
    }
  }
  const serialized = JSON.stringify(notice);
  if (/(?:\/Users\/|\/Volumes\/|file:\/\/|private pilot ledger|under review|counsel review|risk-tolerant legal posture|owner accepted|internal notes?)/i.test(serialized)) {
    errors.push(`${label} contains private publication metadata`);
  }
}

function validatePublicNotices(registry) {
  const errors = [];
  onlyKeys(registry, ['schemaVersion', 'entries'], 'public notice registry', errors);
  if (registry?.schemaVersion !== 1) errors.push('public notice registry schemaVersion must be 1');
  if (!Array.isArray(registry?.entries) || !registry.entries.length) {
    errors.push('public notice registry entries must not be empty');
    return errors;
  }
  const ids = new Set();
  for (const entry of registry.entries) {
    if (!onlyKeys(entry, ['contentId', 'canonicalPath', 'notice'], 'public notice entry', errors)) continue;
    if (typeof entry.contentId !== 'string' || !entry.contentId || ids.has(entry.contentId)) {
      errors.push('public notice registry contains a missing or duplicate contentId');
    }
    ids.add(entry.contentId);
    if (typeof entry.canonicalPath !== 'string' || !entry.canonicalPath
        || canonicalizeRelativePath(entry.canonicalPath) !== entry.canonicalPath) {
      errors.push(`public notice path is invalid for ${entry.contentId}`);
    }
    validatePublicNotice(entry.notice, `public notice ${entry.contentId}`, errors);
  }
  return errors;
}

function publicNoticeMap(registry) {
  const errors = validatePublicNotices(registry);
  if (errors.length) throw new Error(errors.join('; '));
  return new Map(registry.entries.map((entry) => [entry.contentId, entry]));
}

function receiverNoticeFor(contentId, canonicalPath, notices) {
  const entry = notices.get(contentId);
  if (!entry || entry.canonicalPath !== canonicalPath) {
    throw new Error(`An explicit public receiver notice is required for ${contentId}`);
  }
  // Receiver-facing prose comes only from reviewed public input, never the ledger.
  return structuredClone(entry.notice);
}

function dispositionFor(ledgerEntry) {
  switch (ledgerEntry.decision?.status) {
    case 'green':
    case 'yellow':
      return { disposition: 'allow' };
    case 'red':
      return {
        disposition: 'block',
        blockReason: 'sharing-restricted',
      };
    default:
      throw new Error(
        `Unsupported active-catalog evidence status: ${ledgerEntry.decision?.status}`,
      );
  }
}

function sampleType(relativePath) {
  const lowercased = canonicalizeRelativePath(relativePath);
  if (lowercased.endsWith('.zim')) return 'zim';
  if (lowercased.endsWith('.pdf')) return 'pdf';
  if (lowercased.endsWith('.zip')) return 'htmlbook';
  if (/\.(jpe?g|png|gif|webp|heic)$/.test(lowercased)) return 'image';
  if (/\.(html?|xhtml)$/.test(lowercased)) return 'html';
  if (lowercased.endsWith('.pmtiles')) return 'map';
  throw new Error(`Could not infer bundled sample type: ${relativePath}`);
}

function bundledSampleEntries(sampleEvidence, publicNotices) {
  const fragment = (sampleEvidence.fragments || []).find(
    (candidate) => candidate.backlogId === 'ios-bundled-sample-library',
  );
  if (!fragment) {
    throw new Error('Sample evidence is missing ios-bundled-sample-library');
  }
  const inventory = fragment.exactInventory;
  if (!inventory || inventory.matchesExpected !== true || !Array.isArray(inventory.files)) {
    throw new Error('Bundled sample exact inventory is missing or not verified');
  }
  if (inventory.files.length !== inventory.observedFileCount) {
    throw new Error('Bundled sample exact inventory count is stale');
  }

  return inventory.files.map((file) => {
    const relativePath = displayRelativePath(file.relativePath);
    const canonicalPath = canonicalizeRelativePath(relativePath);
    const identity = normalizedIdentity(file, 'bundled-sample-evidence');
    const displayName = path.posix.basename(relativePath);
    return {
      contentId: `bundled-sample/${canonicalPath}`,
      displayName,
      relativePath,
      canonicalPath,
      type: sampleType(relativePath),
      managed: false,
      evidenceStatus: 'yellow',
      disposition: 'allow',
      acceptedIdentities: [{ ...identity, manifestIDs: [] }],
      receiverNotice: receiverNoticeFor(
        `bundled-sample/${canonicalPath}`, canonicalPath, publicNotices,
      ),
    };
  });
}

function validateOwnerAcceptanceRecord(record, expected) {
  const errors = [];
  if (record?.schemaVersion !== 1) errors.push('owner acceptance schemaVersion must be 1');
  if (!record?.id || typeof record.id !== 'string') errors.push('owner acceptance id is required');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(record?.acceptedAt || '')) {
    errors.push('owner acceptance acceptedAt must be YYYY-MM-DD');
  }
  if (record?.policyVersion !== POLICY_VERSION) {
    errors.push(`owner acceptance policyVersion must be ${POLICY_VERSION}`);
  }
  if (record?.distributionMode !== 'local-sharing') {
    errors.push('owner acceptance distributionMode must be local-sharing');
  }
  if (record?.scope?.managedCatalogDecisionStatus !== 'yellow') {
    errors.push('owner acceptance must cover managed yellow catalog entries');
  }
  if (record?.scope?.includesBundledSamples !== true) {
    errors.push('owner acceptance must cover exact bundled samples');
  }
  if (record?.scope?.exactArtifactIdentitiesOnly !== true) {
    errors.push('owner acceptance must be limited to exact artifact identities');
  }
  if (record?.scope?.includesRetiredArtifacts !== false) {
    errors.push('owner acceptance must exclude retired artifacts');
  }

  for (const field of [
    'acceptedArtifactCount',
    'acceptedIdentityCount',
    'acceptedArtifactSetSHA256',
  ]) {
    if (record?.[field] !== expected.binding[field]) {
      errors.push(
        `owner acceptance ${field} is stale; expected ${expected.binding[field]}`,
      );
    }
  }
  for (const field of [
    'catalogSHA256',
    'ledgerVersion',
    'ledgerSHA256',
    'sampleEvidenceSHA256',
  ]) {
    if (record?.sourceBinding?.[field] !== expected.source[field]) {
      errors.push(
        `owner acceptance sourceBinding.${field} is stale; expected ${expected.source[field]}`,
      );
    }
  }
  return errors;
}

function buildProjection({
  catalog,
  ledger,
  ownerAcceptance,
  sampleEvidence,
  manifestSources,
  sourceHashes,
  publicLicenseIndex,
  publicNotices,
}) {
  if (catalog?.schemaVersion !== 1) throw new Error('Catalog schemaVersion must be 1');
  if (ledger?.schemaVersion !== 1) throw new Error('Private ledger schemaVersion must be 1');
  if (!Array.isArray(ledger.entries)) throw new Error('Private ledger entries are missing');
  if (sampleEvidence?.schemaVersion !== 1) {
    throw new Error('Sample evidence schemaVersion must be 1');
  }

  const notices = publicNoticeMap(publicNotices);
  const items = catalogItems(catalog);
  const itemMap = mapByCanonicalPath(items, (item) => item.relativePath, 'catalog');
  const ledgerMap = mapByCanonicalPath(
    ledger.entries,
    (entry) => entry.artifact?.relativePath,
    'private ledger',
  );
  const manifestMaps = new Map(
    manifestSources.map((source) => [source.spec.id, manifestEntryMap(source)]),
  );
  const completeMap = manifestMaps.get('current-complete-20260711');
  if (!completeMap) throw new Error('Current Complete manifest input is missing');

  const entries = [];
  for (const item of [...items].sort((lhs, rhs) => (
    compareStrings(
      canonicalizeRelativePath(lhs.relativePath),
      canonicalizeRelativePath(rhs.relativePath),
    )
  ))) {
    const canonicalPath = canonicalizeRelativePath(item.relativePath);
    const ledgerEntry = ledgerMap.get(canonicalPath);
    if (!ledgerEntry) throw new Error(`No private ledger row for ${item.relativePath}`);
    if (!EVIDENCE_STATUSES.has(ledgerEntry.decision?.status)) {
      throw new Error(
        `Active catalog row ${item.relativePath} has unsupported decision ${ledgerEntry.decision?.status}`,
      );
    }
    if (ledgerEntry.artifact.type !== item.type) {
      throw new Error(`Catalog/ledger type mismatch for ${item.relativePath}`);
    }
    if (ledgerEntry.artifact.sizeBytes !== item.size) {
      throw new Error(`Catalog/ledger size mismatch for ${item.relativePath}`);
    }
    if (!ALLOWED_TYPES.has(item.type)) {
      throw new Error(`Unsupported catalog type ${item.type} for ${item.relativePath}`);
    }
    if (
      ledgerEntry.decision.status === 'green'
      && !ledgerEntry.downstreamRights?.allowedDistributionModes?.includes('local-sharing')
    ) {
      throw new Error(`Green ledger row lacks local-sharing permission: ${item.relativePath}`);
    }

    const identityMap = new Map();
    const ledgerIdentity = normalizedIdentity(ledgerEntry.artifact, 'private-ledger');
    addIdentity(identityMap, ledgerIdentity);
    for (const source of manifestSources) {
      const manifestEntry = manifestMaps.get(source.spec.id).get(canonicalPath);
      if (!manifestEntry) continue;
      const manifestIdentity = normalizedIdentity(manifestEntry, source.spec.id);
      if (
        ledgerEntry.decision.status === 'green'
        && artifactIdentityKey(manifestIdentity) !== artifactIdentityKey(ledgerIdentity)
      ) {
        throw new Error(
          `Green retained identity is not bound to the reviewed ledger row: ${item.relativePath}`,
        );
      }
      addIdentity(identityMap, manifestIdentity, source.spec.id);
    }

    const currentCompleteEntry = completeMap.get(canonicalPath);
    if (!currentCompleteEntry) {
      throw new Error(`Current Complete manifest is missing ${item.relativePath}`);
    }
    if (
      artifactIdentityKey(normalizedIdentity(currentCompleteEntry, 'current-complete-20260711'))
      !== artifactIdentityKey(ledgerIdentity)
    ) {
      throw new Error(`Current Complete identity does not match ledger: ${item.relativePath}`);
    }

    const runtimeDisposition = dispositionFor(ledgerEntry);
    const entry = {
      contentId: String(ledgerEntry.contentId || item.id || canonicalPath),
      displayName: String(item.name || ledgerEntry.displayName || path.posix.basename(canonicalPath)),
      relativePath: displayRelativePath(item.relativePath),
      canonicalPath,
      type: String(item.type),
      managed: true,
      evidenceStatus: ledgerEntry.decision.status,
      ...runtimeDisposition,
      acceptedIdentities: sortedIdentities(identityMap),
      receiverNotice: receiverNoticeFor(
        String(ledgerEntry.contentId || item.id || canonicalPath), canonicalPath, notices,
      ),
    };
    const compatibilityGroupMembers = compatibilityMembersForEntry(entry, manifestSources);
    if (compatibilityGroupMembers.length > 0) {
      entry.compatibilityGroupMembers = compatibilityGroupMembers;
    }
    entries.push(entry);
  }

  const samples = bundledSampleEntries(sampleEvidence, notices);
  for (const sample of samples) {
    if (itemMap.has(sample.canonicalPath)) {
      throw new Error(`Bundled sample collides with managed catalog: ${sample.relativePath}`);
    }
    entries.push(sample);
  }
  entries.sort((lhs, rhs) => (
    compareStrings(lhs.canonicalPath, rhs.canonicalPath)
    || Number(rhs.managed) - Number(lhs.managed)
    || compareStrings(lhs.contentId, rhs.contentId)
  ));

  const binding = acceptedArtifactBinding(entries);
  const source = {
    catalogSHA256: sourceHashes.catalogSHA256,
    ledgerVersion: String(ledger.ledgerVersion || ''),
    ledgerSHA256: sourceHashes.ledgerSHA256,
    currentManifestSHA256s: {},
    retainedManifestSHA256s: {},
    sampleEvidenceSHA256: sourceHashes.sampleEvidenceSHA256,
    manifests: manifestSources.map(manifestMetadata),
  };
  for (const manifestSource of manifestSources) {
    source[manifestSource.spec.hashGroup][manifestSource.spec.hashKey] = manifestSource.sha256;
  }

  const acceptanceErrors = validateOwnerAcceptanceRecord(ownerAcceptance, { binding, source });
  if (acceptanceErrors.length) throw new Error(acceptanceErrors.join('; '));

  const managedEntries = entries.filter((entry) => entry.managed);
  const bundledSamples = entries.filter((entry) => !entry.managed);
  const greenManagedEntries = managedEntries.filter(
    (entry) => entry.evidenceStatus === 'green',
  ).length;
  const yellowManagedEntries = managedEntries.filter(
    (entry) => entry.evidenceStatus === 'yellow',
  ).length;
  const projection = {
    schemaVersion: 1,
    policyVersion: POLICY_VERSION,
    projectionHash: '',
    ownerAcceptance: {
      id: ownerAcceptance.id,
      acceptedAt: ownerAcceptance.acceptedAt,
      acceptedArtifactCount: binding.acceptedArtifactCount,
      acceptedIdentityCount: binding.acceptedIdentityCount,
      acceptedArtifactSetSHA256: binding.acceptedArtifactSetSHA256,
    },
    source,
    coverage: {
      managedCatalogEntries: managedEntries.length,
      bundledSampleEntries: bundledSamples.length,
      greenManagedEntries,
      ownerAcceptedYellowManagedEntries: yellowManagedEntries,
      ownerAcceptedYellowBundledSamples: bundledSamples.length,
      ownerAcceptedYellowEntries: yellowManagedEntries + bundledSamples.length,
      allowedEntries: entries.length,
    },
    entries,
  };
  projection.projectionHash = projectionHashFor(projection);

  const errors = validateProjection(projection, {
    catalog,
    ownerAcceptance,
    publicLicenseIndex,
    publicNotices,
    catalogSHA256: sourceHashes.catalogSHA256,
  });
  if (errors.length) throw new Error(errors.join('; '));
  return projection;
}

function isSortedUniqueStrings(values) {
  if (!Array.isArray(values)) return false;
  const sorted = [...new Set(values)].sort();
  return values.length === sorted.length && values.every((value, index) => value === sorted[index]);
}

function validateBundledSampleRoot(
  projection,
  sampleRoot,
  { expectedCount = REQUIRED_BUNDLED_SAMPLE_COUNT, allowPublicPlaceholder = false } = {},
) {
  const errors = [];
  const samples = (projection?.entries || []).filter((entry) => !entry.managed);
  if (samples.length !== expectedCount) {
    errors.push(
      `bundled sample projection must contain exactly ${expectedCount} rows; found ${samples.length}`,
    );
  }
  const expectedFiles = new Map();
  const expectedDirectories = new Map();

  for (const entry of samples) {
    const relativePath = displayRelativePath(entry.relativePath);
    const components = relativePath.split('/');
    if (
      !relativePath
      || path.posix.isAbsolute(relativePath)
      || components.some((component) => component === '' || component === '.' || component === '..')
    ) {
      errors.push(`bundled sample path is unsafe: ${entry.relativePath || '<empty>'}`);
      continue;
    }
    if (entry.acceptedIdentities?.length !== 1) {
      errors.push(`bundled sample must have exactly one accepted identity: ${entry.relativePath}`);
      continue;
    }
    const identity = entry.acceptedIdentities[0];
    if (
      !Number.isSafeInteger(identity.sizeBytes)
      || identity.sizeBytes <= 0
      || !SHA256_PATTERN.test(identity.sha256 || '')
      || !Array.isArray(identity.manifestIDs)
      || identity.manifestIDs.length !== 0
    ) {
      errors.push(`bundled sample identity is invalid: ${entry.relativePath}`);
      continue;
    }
    const canonicalPath = canonicalizeRelativePath(relativePath);
    if (expectedFiles.has(canonicalPath)) {
      errors.push(`bundled sample projection has a canonical path collision: ${relativePath}`);
      continue;
    }
    expectedFiles.set(canonicalPath, {
      relativePath,
      sizeBytes: identity.sizeBytes,
      sha256: identity.sha256,
    });
    let directory = path.posix.dirname(relativePath);
    while (directory !== '.') {
      const canonicalDirectory = canonicalizeRelativePath(directory);
      const priorDirectory = expectedDirectories.get(canonicalDirectory);
      if (priorDirectory && priorDirectory !== directory) {
        errors.push(`bundled sample projection has a directory path collision: ${directory}`);
      } else {
        expectedDirectories.set(canonicalDirectory, directory);
      }
      directory = path.posix.dirname(directory);
    }
  }

  if (!sampleRoot) {
    errors.push('bundled sample root is required');
    return errors;
  }
  let rootStat;
  try {
    rootStat = fs.lstatSync(sampleRoot);
  } catch (error) {
    errors.push(`bundled sample root is unavailable: ${error.message}`);
    return errors;
  }
  if (rootStat.isSymbolicLink()) {
    errors.push(`bundled sample root must not be a symbolic link: ${sampleRoot}`);
    return errors;
  }
  if (!rootStat.isDirectory()) {
    errors.push(`bundled sample root is not a directory: ${sampleRoot}`);
    return errors;
  }

  const actualFiles = new Map();
  const actualDirectories = new Map();
  function inspectDirectory(absoluteDirectory, relativeDirectory = '') {
    let names;
    try {
      names = fs.readdirSync(absoluteDirectory).sort();
    } catch (error) {
      errors.push(`could not read bundled sample directory ${relativeDirectory || '.'}: ${error.message}`);
      return;
    }
    for (const name of names) {
      const absoluteEntry = path.join(absoluteDirectory, name);
      const relativeEntry = relativeDirectory
        ? `${relativeDirectory}/${name}`
        : name;
      let stat;
      try {
        stat = fs.lstatSync(absoluteEntry);
      } catch (error) {
        errors.push(`could not inspect bundled sample path ${relativeEntry}: ${error.message}`);
        continue;
      }
      if (stat.isSymbolicLink()) {
        errors.push(`bundled sample path must not be a symbolic link: ${relativeEntry}`);
        continue;
      }
      const canonicalEntry = canonicalizeRelativePath(relativeEntry);
      if (stat.isDirectory()) {
        if (actualDirectories.has(canonicalEntry)) {
          errors.push(`bundled sample directory has a canonical collision: ${relativeEntry}`);
          continue;
        }
        actualDirectories.set(canonicalEntry, relativeEntry);
        inspectDirectory(absoluteEntry, relativeEntry);
      } else if (stat.isFile()) {
        if (actualFiles.has(canonicalEntry)) {
          errors.push(`bundled sample file has a canonical collision: ${relativeEntry}`);
          continue;
        }
        actualFiles.set(canonicalEntry, {
          absolutePath: absoluteEntry,
          relativePath: relativeEntry,
          sizeBytes: stat.size,
        });
      } else {
        errors.push(`bundled sample path is not a regular file or directory: ${relativeEntry}`);
      }
    }
  }
  inspectDirectory(sampleRoot);

  // Only the exact code-only export can omit sample bytes. Inspect the entire
  // tree first so extra files, directories, symlinks, and partial payloads do
  // not acquire an exception by being placed alongside this README.
  if (allowPublicPlaceholder && actualFiles.size === 1 && actualDirectories.size === 0) {
    const placeholder = actualFiles.get('readme.md');
    if (placeholder?.relativePath === 'README.md') {
      try {
        if (fs.readFileSync(placeholder.absolutePath).equals(Buffer.from(PUBLIC_SAMPLE_PLACEHOLDER))) {
          return errors;
        }
      } catch (error) {
        errors.push(`could not read public sample placeholder: ${error.message}`);
      }
      errors.push('public sample placeholder bytes differ from the source exporter');
    }
  }

  for (const [canonicalPath, expected] of expectedFiles) {
    const actual = actualFiles.get(canonicalPath);
    if (!actual) {
      errors.push(`bundled sample file is missing: ${expected.relativePath}`);
      continue;
    }
    if (actual.relativePath !== expected.relativePath) {
      errors.push(
        `bundled sample path differs from projection: expected ${expected.relativePath}, found ${actual.relativePath}`,
      );
    }
    if (actual.sizeBytes !== expected.sizeBytes) {
      errors.push(
        `bundled sample size mismatch for ${expected.relativePath}: expected ${expected.sizeBytes}, found ${actual.sizeBytes}`,
      );
      continue;
    }
    let actualSHA256;
    try {
      actualSHA256 = sha256File(actual.absolutePath);
    } catch (error) {
      errors.push(`could not hash bundled sample ${expected.relativePath}: ${error.message}`);
      continue;
    }
    if (actualSHA256 !== expected.sha256) {
      errors.push(`bundled sample SHA-256 mismatch: ${expected.relativePath}`);
    }
  }
  for (const [canonicalPath, actual] of actualFiles) {
    if (!expectedFiles.has(canonicalPath)) {
      errors.push(`unexpected bundled sample file: ${actual.relativePath}`);
    }
  }
  for (const [canonicalPath, expectedDirectory] of expectedDirectories) {
    const actualDirectory = actualDirectories.get(canonicalPath);
    if (!actualDirectory) {
      errors.push(`bundled sample directory is missing: ${expectedDirectory}`);
    } else if (actualDirectory !== expectedDirectory) {
      errors.push(
        `bundled sample directory differs from projection: expected ${expectedDirectory}, found ${actualDirectory}`,
      );
    }
  }
  for (const [canonicalPath, actualDirectory] of actualDirectories) {
    if (!expectedDirectories.has(canonicalPath)) {
      errors.push(`unexpected bundled sample directory: ${actualDirectory}`);
    }
  }
  return errors;
}

function validateProjection(projection, options = {}) {
  const errors = [];
  const entries = Array.isArray(projection?.entries) ? projection.entries : [];
  onlyKeys(projection, ['schemaVersion', 'policyVersion', 'projectionHash', 'ownerAcceptance', 'source', 'coverage', 'entries'], 'projection', errors);
  onlyKeys(projection?.ownerAcceptance, ['id', 'acceptedAt', 'acceptedArtifactCount', 'acceptedIdentityCount', 'acceptedArtifactSetSHA256'], 'projection ownerAcceptance', errors);
  onlyKeys(projection?.source, ['catalogSHA256', 'ledgerVersion', 'ledgerSHA256', 'currentManifestSHA256s', 'retainedManifestSHA256s', 'sampleEvidenceSHA256', 'manifests'], 'projection source', errors);
  onlyKeys(projection?.coverage, ['managedCatalogEntries', 'bundledSampleEntries', 'greenManagedEntries', 'ownerAcceptedYellowManagedEntries', 'ownerAcceptedYellowBundledSamples', 'ownerAcceptedYellowEntries', 'allowedEntries'], 'projection coverage', errors);
  for (const manifest of projection?.source?.manifests || []) {
    onlyKeys(manifest, ['id', 'role', 'variant', 'tier', 'sourceEdition', 'generatedAt', 'sha256', 'semanticFingerprint'], 'projection manifest', errors);
  }
  if (projection?.schemaVersion !== 1) errors.push('projection schemaVersion must be 1');
  if (projection?.policyVersion !== POLICY_VERSION) {
    errors.push(`projection policyVersion must be ${POLICY_VERSION}`);
  }
  if (!SHA256_PATTERN.test(projection?.projectionHash || '')) {
    errors.push('projectionHash must be a lowercase SHA-256');
  } else if (projectionHashFor(projection) !== projection.projectionHash) {
    errors.push('projectionHash is stale');
  }
  if (!entries.length) errors.push('projection entries must not be empty');

  const contentIDs = new Set();
  const canonicalPaths = new Set();
  for (const entry of entries) {
    onlyKeys(entry, ['contentId', 'displayName', 'relativePath', 'canonicalPath', 'type', 'managed', 'evidenceStatus', 'disposition', 'blockReason', 'acceptedIdentities', 'compatibilityGroupMembers', 'receiverNotice'], 'projection entry', errors);
    for (const identity of entry.acceptedIdentities || []) {
      onlyKeys(identity, ['sizeBytes', 'sha256', 'manifestIDs'], 'accepted identity', errors);
    }
    for (const member of entry.compatibilityGroupMembers || []) {
      onlyKeys(member, ['relativePath', 'sizeBytes', 'sha256', 'manifestIDs'], 'compatibility member', errors);
    }
    if (!entry.contentId || contentIDs.has(entry.contentId)) {
      errors.push(`duplicate or empty contentId: ${entry.contentId || '<empty>'}`);
    }
    contentIDs.add(entry.contentId);
    if (
      !entry.canonicalPath
      || canonicalPaths.has(entry.canonicalPath)
      || canonicalizeRelativePath(entry.relativePath) !== entry.canonicalPath
    ) {
      errors.push(`invalid or duplicate canonicalPath: ${entry.canonicalPath || '<empty>'}`);
    }
    canonicalPaths.add(entry.canonicalPath);
    if (!ALLOWED_TYPES.has(entry.type)) errors.push(`invalid type for ${entry.relativePath}`);
    if (typeof entry.managed !== 'boolean') errors.push(`managed must be boolean for ${entry.relativePath}`);
    if (!EVIDENCE_STATUSES.has(entry.evidenceStatus)) {
      errors.push(`invalid evidenceStatus for ${entry.relativePath}`);
    }
    if (!DISPOSITIONS.has(entry.disposition)) {
      errors.push(`invalid disposition for ${entry.relativePath}`);
    }
    if (
      (entry.disposition === 'block' && (
        typeof entry.blockReason !== 'string' || entry.blockReason.trim() === ''
      ))
      || (entry.disposition === 'allow' && entry.blockReason != null)
    ) {
      errors.push(`invalid block reason for ${entry.relativePath}`);
    }
    if (!Array.isArray(entry.acceptedIdentities) || !entry.acceptedIdentities.length) {
      errors.push(`acceptedIdentities are missing for ${entry.relativePath}`);
    }
    const identityKeys = new Set();
    for (const identity of entry.acceptedIdentities || []) {
      const key = artifactIdentityKey(identity);
      if (
        !Number.isSafeInteger(identity.sizeBytes)
        || identity.sizeBytes <= 0
        || !SHA256_PATTERN.test(identity.sha256 || '')
        || identityKeys.has(key)
      ) {
        errors.push(`invalid or duplicate accepted identity for ${entry.relativePath}`);
      }
      identityKeys.add(key);
      if (!isSortedUniqueStrings(identity.manifestIDs)) {
        errors.push(`manifestIDs must be sorted and unique for ${entry.relativePath}`);
      }
    }
    for (const member of entry.compatibilityGroupMembers || []) {
      if (
        !canonicalizeRelativePath(member.relativePath)
        || !Number.isSafeInteger(member.sizeBytes)
        || member.sizeBytes <= 0
        || !SHA256_PATTERN.test(member.sha256 || '')
        || !isSortedUniqueStrings(member.manifestIDs)
      ) {
        errors.push(`invalid compatibility group member for ${entry.relativePath}`);
      }
    }
    if (entry.type === 'map' && entry.managed) {
      const regionPrefix = mapRegionPrefix(entry.canonicalPath);
      const members = entry.compatibilityGroupMembers || [];
      const hasPMTiles = members.some(
        (member) => canonicalizeRelativePath(member.relativePath) === entry.canonicalPath,
      );
      const hasManifest = members.some(
        (member) => canonicalizeRelativePath(member.relativePath) === `${regionPrefix}manifest.json`,
      );
      if (!regionPrefix || !hasPMTiles || !hasManifest) {
        errors.push(`map compatibility group is incomplete for ${entry.relativePath}`);
      }
    }
    validatePublicNotice(entry.receiverNotice, `receiverNotice ${entry.relativePath}`, errors);
  }

  if (options.publicNotices) {
    const noticeErrors = validatePublicNotices(options.publicNotices);
    errors.push(...noticeErrors);
    if (!noticeErrors.length) {
      const notices = publicNoticeMap(options.publicNotices);
      if (notices.size !== entries.length) errors.push('public notice coverage does not match projection');
      for (const entry of entries) {
        const expected = notices.get(entry.contentId);
        if (!expected || expected.canonicalPath !== entry.canonicalPath
            || stableStringify(expected.notice) !== stableStringify(entry.receiverNotice)) {
          errors.push(`receiverNotice differs from public input for ${entry.contentId}`);
        }
      }
    }
  }

  const catalog = options.catalog;
  if (catalog) {
    let itemMap;
    try {
      itemMap = mapByCanonicalPath(catalogItems(catalog), (item) => item.relativePath, 'catalog');
    } catch (error) {
      errors.push(error.message);
      itemMap = new Map();
    }
    const managed = entries.filter((entry) => entry.managed);
    if (managed.length !== itemMap.size) {
      errors.push(`managed coverage is ${managed.length}; catalog has ${itemMap.size}`);
    }
    for (const entry of managed) {
      const item = itemMap.get(entry.canonicalPath);
      if (!item) {
        errors.push(`managed entry is not in active catalog: ${entry.relativePath}`);
        continue;
      }
      if (entry.type !== item.type) errors.push(`catalog type drift for ${entry.relativePath}`);
      if (!entry.acceptedIdentities.some((identity) => identity.sizeBytes === item.size)) {
        errors.push(`catalog size is not an accepted identity for ${entry.relativePath}`);
      }
    }
    if (
      options.catalogSHA256
      && projection?.source?.catalogSHA256 !== options.catalogSHA256
    ) {
      errors.push('source.catalogSHA256 is stale');
    }
  }

  const publicIndex = options.publicLicenseIndex;
  if (publicIndex) {
    let publicMap;
    try {
      publicMap = mapByCanonicalPath(
        publicIndex.entries || [],
        (entry) => entry.artifact?.relativePath,
        'public green license index',
      );
    } catch (error) {
      errors.push(error.message);
      publicMap = new Map();
    }
    const projectedGreen = entries.filter(
      (entry) => entry.managed && entry.evidenceStatus === 'green',
    );
    if (projectedGreen.length !== publicMap.size) {
      errors.push(
        `green projection coverage is ${projectedGreen.length}; public index has ${publicMap.size}`,
      );
    }
    for (const entry of projectedGreen) {
      const publicEntry = publicMap.get(entry.canonicalPath);
      if (!publicEntry) {
        errors.push(`green entry is missing from public index: ${entry.relativePath}`);
        continue;
      }
      const identity = publicEntry.artifact || {};
      if (
        identity.type !== entry.type
        || !entry.acceptedIdentities.some(
          (candidate) => candidate.sizeBytes === identity.sizeBytes
            && candidate.sha256 === identity.sha256,
        )
      ) {
        errors.push(`green public identity drift for ${entry.relativePath}`);
      }
    }
  }

  const binding = acceptedArtifactBinding(entries);
  for (const field of [
    'acceptedArtifactCount',
    'acceptedIdentityCount',
    'acceptedArtifactSetSHA256',
  ]) {
    if (projection?.ownerAcceptance?.[field] !== binding[field]) {
      errors.push(`projection ownerAcceptance.${field} is stale`);
    }
  }
  if (options.ownerAcceptance) {
    const acceptanceErrors = validateOwnerAcceptanceRecord(options.ownerAcceptance, {
      binding,
      source: projection.source || {},
    });
    errors.push(...acceptanceErrors);
    if (projection?.ownerAcceptance?.id !== options.ownerAcceptance.id) {
      errors.push('projection ownerAcceptance.id does not match tracked record');
    }
    if (projection?.ownerAcceptance?.acceptedAt !== options.ownerAcceptance.acceptedAt) {
      errors.push('projection ownerAcceptance.acceptedAt does not match tracked record');
    }
  }

  const managed = entries.filter((entry) => entry.managed);
  const samples = entries.filter((entry) => !entry.managed);
  if (options.sampleRoot !== undefined) {
    errors.push(...validateBundledSampleRoot(projection, options.sampleRoot, {
      allowPublicPlaceholder: options.publicBuild === true,
    }));
  }
  const expectedCoverage = {
    managedCatalogEntries: managed.length,
    bundledSampleEntries: samples.length,
    greenManagedEntries: managed.filter((entry) => entry.evidenceStatus === 'green').length,
    ownerAcceptedYellowManagedEntries: managed.filter(
      (entry) => entry.evidenceStatus === 'yellow',
    ).length,
    ownerAcceptedYellowBundledSamples: samples.filter(
      (entry) => entry.evidenceStatus === 'yellow',
    ).length,
    ownerAcceptedYellowEntries: entries.filter(
      (entry) => entry.evidenceStatus === 'yellow',
    ).length,
    allowedEntries: entries.filter((entry) => entry.disposition === 'allow').length,
  };
  for (const [field, expected] of Object.entries(expectedCoverage)) {
    if (projection?.coverage?.[field] !== expected) {
      errors.push(`coverage.${field} is stale; expected ${expected}`);
    }
  }

  const source = projection?.source || {};
  if (
    !SHA256_PATTERN.test(source.catalogSHA256 || '')
    || !SHA256_PATTERN.test(source.ledgerSHA256 || '')
    || !SHA256_PATTERN.test(source.sampleEvidenceSHA256 || '')
    || !source.ledgerVersion
  ) {
    errors.push('projection source bindings are incomplete');
  }
  for (const group of ['currentManifestSHA256s', 'retainedManifestSHA256s']) {
    for (const hash of Object.values(source[group] || {})) {
      if (!SHA256_PATTERN.test(hash)) errors.push(`invalid source ${group} hash`);
    }
  }
  const expectedManifestHashes = {
    currentManifestSHA256s: {},
    retainedManifestSHA256s: {},
  };
  const projectedManifests = Array.isArray(source.manifests)
    ? source.manifests
    : [];
  for (const spec of MANIFEST_SPECS) {
    const hash = projectedManifests.find(
      (manifest) => manifest.id === spec.id,
    )?.sha256;
    if (hash) expectedManifestHashes[spec.hashGroup][spec.hashKey] = hash;
  }
  for (const group of ['currentManifestSHA256s', 'retainedManifestSHA256s']) {
    if (
      stableStringify(source[group] || {})
      !== stableStringify(expectedManifestHashes[group])
    ) {
      errors.push(`source ${group} keys and values do not match manifests`);
    }
  }
  if (!Array.isArray(source.manifests) || source.manifests.length !== MANIFEST_SPECS.length) {
    errors.push('source manifest provenance is incomplete');
  } else {
    const manifestIDs = new Set();
    const manifestHashes = new Set();
    const semanticFingerprints = new Set();
    const specsByID = new Map(MANIFEST_SPECS.map((spec) => [spec.id, spec]));
    for (const manifest of source.manifests) {
      const spec = specsByID.get(manifest.id);
      if (
        !spec
        || manifestIDs.has(manifest.id)
        || manifest.role !== spec.role
        || manifest.variant !== spec.variant
        || manifest.tier !== spec.tier
        || manifest.sourceEdition !== spec.sourceEdition
        || !manifest.generatedAt
        || !SHA256_PATTERN.test(manifest.sha256 || '')
        || manifestHashes.has(manifest.sha256)
        || !SHA256_PATTERN.test(manifest.semanticFingerprint || '')
        || semanticFingerprints.has(manifest.semanticFingerprint)
        || source?.[spec.hashGroup]?.[spec.hashKey] !== manifest.sha256
      ) {
        errors.push(`invalid manifest provenance: ${manifest.id || '<empty>'}`);
      }
      manifestIDs.add(manifest.id);
      manifestHashes.add(manifest.sha256);
      semanticFingerprints.add(manifest.semanticFingerprint);
    }
    for (const entry of entries) {
      for (const identity of entry.acceptedIdentities || []) {
        for (const manifestID of identity.manifestIDs || []) {
          if (!manifestIDs.has(manifestID)) {
            errors.push(
              `unknown manifest provenance ${manifestID} for ${entry.relativePath}`,
            );
          }
        }
      }
      for (const member of entry.compatibilityGroupMembers || []) {
        for (const manifestID of member.manifestIDs || []) {
          if (!manifestIDs.has(manifestID)) {
            errors.push(
              `unknown manifest provenance ${manifestID} for ${entry.relativePath}`,
            );
          }
        }
      }
    }
  }

  const serialized = JSON.stringify(projection);
  for (const forbidden of ['/Volumes/', '/Users/', '.private-content', 'file://']) {
    if (serialized.includes(forbidden)) {
      errors.push(`runtime projection exposes a private path marker: ${forbidden}`);
    }
  }
  return errors;
}

function requireGenerationPaths(args) {
  const required = [
    ['catalog', '--catalog'],
    ['ledger', '--ledger'],
    ...MANIFEST_SPECS.map((spec) => [spec.argument, spec.flag]),
    ['sampleEvidence', '--sample-evidence'],
    ['ownerAcceptance', '--owner-acceptance'],
  ];
  const missing = required.filter(([field]) => !args[field]).map(([, flag]) => flag);
  if (missing.length) {
    throw new Error(`Generation requires explicit paths: ${missing.join(', ')}`);
  }
}

function readRequired(filePath, label) {
  if (!fs.existsSync(filePath)) throw new Error(`${label} not found: ${filePath}`);
  return readJSON(filePath);
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (args.validateOnly) {
      const catalog = readRequired(args.catalog, 'Catalog');
      const ownerAcceptance = args.publicBuild
        ? undefined : readRequired(args.ownerAcceptance, 'Owner acceptance');
      const publicLicenseIndex = readRequired(args.publicLicenseIndex, 'Public license index');
      const publicNotices = readRequired(args.publicNotices, 'Public receiver notices');
      const projection = readRequired(args.output, 'Disposition projection');
      const errors = validateProjection(projection, {
        catalog,
        ownerAcceptance,
        publicLicenseIndex,
        publicNotices,
        catalogSHA256: sha256File(args.catalog),
        sampleRoot: args.sampleRoot,
        publicBuild: args.publicBuild,
      });
      if (errors.length) throw new Error(errors.join('; '));
      log(
        `Validated ${projection.coverage.managedCatalogEntries} managed titles and `
        + (args.publicBuild ? 'public sample inputs at '
          : `${projection.coverage.bundledSampleEntries} exact bundled sample files at `)
        + `${path.relative(ROOT_DIR, args.output)}`,
      );
      return;
    }

    requireGenerationPaths(args);
    const catalog = readRequired(args.catalog, 'Catalog');
    const ledger = readRequired(args.ledger, 'Private ledger');
    const sampleEvidence = readRequired(args.sampleEvidence, 'Sample evidence');
    const ownerAcceptance = readRequired(args.ownerAcceptance, 'Owner acceptance');
    const publicLicenseIndex = readRequired(args.publicLicenseIndex, 'Public license index');
    const publicNotices = readRequired(args.publicNotices, 'Public receiver notices');
    const manifestSources = MANIFEST_SPECS.map((spec) => ({
      spec,
      manifest: readRequired(args[spec.argument], `Manifest ${spec.id}`),
      sha256: sha256File(args[spec.argument]),
    }));
    const projection = buildProjection({
      catalog,
      ledger,
      ownerAcceptance,
      sampleEvidence,
      manifestSources,
      sourceHashes: {
        catalogSHA256: sha256File(args.catalog),
        ledgerSHA256: sha256File(args.ledger),
        sampleEvidenceSHA256: sha256File(args.sampleEvidence),
      },
      publicLicenseIndex,
      publicNotices,
    });
    fs.mkdirSync(path.dirname(args.output), { recursive: true });
    fs.writeFileSync(args.output, `${JSON.stringify(projection, null, 2)}\n`, 'utf8');
    log(
      `Wrote ${projection.coverage.managedCatalogEntries} managed titles and `
      + `${projection.coverage.bundledSampleEntries} bundled samples to `
      + `${path.relative(ROOT_DIR, args.output)}`,
    );
  } catch (error) {
    fail(error.message);
  }
}

if (process.argv[1] && fs.existsSync(process.argv[1])
    && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))) {
  main();
}

export {
  POLICY_VERSION,
  MANIFEST_SPECS,
  acceptedArtifactBinding,
  buildProjection,
  canonicalizeRelativePath,
  compatibilityMembersForEntry,
  projectionHashFor,
  semanticFingerprintForManifest,
  stableStringify,
  validateBundledSampleRoot,
  validateProjection,
  validatePublicNotices,
  receiverNoticeFor,
  publicNoticeMap,
  dispositionFor,
};

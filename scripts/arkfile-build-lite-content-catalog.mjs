#!/usr/bin/env node
'use strict';

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, '..');
const DEFAULT_OUTPUT_PATH = path.join(ROOT_DIR, 'Support', 'ArkFileContentCatalog', 'content-catalog.json');
const DEFAULT_TITLE_SUMMARIES_PATH = path.join(
  ROOT_DIR,
  'Support',
  'ArkFileContentCatalog',
  'title-summaries.json',
);
const DEFAULT_LICENSE_INDEX_PATH = path.join(
  ROOT_DIR,
  'Support',
  'ArkFileContentLicenses',
  'content-license-index.json',
);
const DEFAULT_LICENSE_SOURCE_CANDIDATES = [
  process.env.ARKFILE_DESKTOP_CONTENT_LICENSE_INDEX,
  path.join(ROOT_DIR, '..', 'arkfile-app', 'www', 'catalog', 'content-license-index.json'),
].filter(Boolean);
const DEFAULT_REGION_INDEX_PATH = path.join(ROOT_DIR, 'Support', 'OfflineMap', 'regions-index.json');
const DEFAULT_SOURCE_CANDIDATES = [
  process.env.ARKFILE_DESKTOP_CONTENT_CATALOG,
  path.join(ROOT_DIR, '..', 'arkfile-app', 'www', 'catalog', 'content-catalog.json'),
].filter(Boolean);

const CATEGORY_KEYS = ['general', 'medical', 'food-preparation', 'travel', 'books_documents'];
const REQUIRED_LITE_PATHS = [
  'general/encyclopedias/Simple Wikipedia.zim',
  'medical/reference/WikiMed - Sept 2025.zim',
  'travel/guides/WikiVoyage - Dec 2025.zim',
  'books_documents/King James Bible.zip',
];
const REQUIRED_COMPLETE_PATHS = [
  'general/encyclopedias/Wikipedia - No Images, August 2025.zim',
  'general/encyclopedias/Wikipedia - With Images, August 2025.zim',
];
const MIN_EXPECTED_IOS_ENTRIES = 130;
const IOS_TIER_LABELS = {
  lite: 'ArkFile Essentials',
  complete: 'ArkFile Complete',
};
const PUBLIC_LICENSE_FIELD_NAMES = [
  'licenseId',
  'licenseName',
  'licenseUrl',
  'sourceUrl',
  'attributionText',
  'changesMade',
  'contentLicenseLedgerVersion',
  'contentLicenseProjectionHash',
  'contentLicenseDecisionStatus',
];
const LICENSE_PERMISSION_VALUES = new Set(['allowed', 'prohibited', 'permission-required']);
const LICENSE_DECISION_STATUSES = new Set(['green']);
const DISTRIBUTION_MODES = new Set([
  'paid-download',
  'offline-use',
  'local-sharing',
  'public-preview',
  'future-updates',
]);
const SHA256_PATTERN = /^[a-f0-9]{64}$/;

function parseArgs(argv) {
  const args = {
    source: '',
    output: process.env.ARKFILE_IOS_CONTENT_CATALOG_OUT || DEFAULT_OUTPUT_PATH,
    licenseIndex: process.env.ARKFILE_IOS_CONTENT_LICENSE_INDEX || DEFAULT_LICENSE_INDEX_PATH,
    licenseSource: '',
    titleSummaries: process.env.ARKFILE_IOS_TITLE_SUMMARIES || DEFAULT_TITLE_SUMMARIES_PATH,
    requireContentLicenses: false,
    skipTitleSummaries: false,
    validateOnly: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--validate-only') {
      args.validateOnly = true;
    } else if (arg === '--source') {
      args.source = path.resolve(argv[++index] || '');
    } else if (arg === '--output') {
      args.output = path.resolve(argv[++index] || '');
    } else if (arg === '--license-index') {
      args.licenseIndex = path.resolve(argv[++index] || '');
    } else if (arg === '--license-source') {
      args.licenseSource = path.resolve(argv[++index] || '');
    } else if (arg === '--title-summaries') {
      args.titleSummaries = path.resolve(argv[++index] || '');
    } else if (arg === '--require-content-licenses') {
      args.requireContentLicenses = true;
    } else if (arg === '--skip-title-summaries') {
      args.skipTitleSummaries = true;
    } else if (arg === '--help' || arg === '-h') {
      printHelp();
      process.exit(0);
    } else {
      fail(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function printHelp() {
  console.log(`Usage: scripts/arkfile-build-lite-content-catalog.mjs [--validate-only] [--source PATH] [--output PATH] [--title-summaries PATH] [--license-source PATH] [--license-index PATH] [--require-content-licenses] [--skip-title-summaries]

Builds the iOS bundled ArkFile catalog from the desktop catalog metadata. The
output intentionally contains metadata only for iOS-installable Essentials and
Complete titles, not paid content payloads and not desktop-only Standard SKUs.

The normal validation mode accepts the checked-in empty bootstrap license index
while title research is underway. --require-content-licenses is the fail-closed
release mode: every iOS title must have a matching green public ledger entry,
and the catalog must carry the same ledger version and projection hash.

--skip-title-summaries is valid only with --validate-only. It validates the
already-generated catalog without requiring the private, non-build title
research ledger. Public corresponding-source builds use this mode because the
compiled catalog already contains the generated summary strings.

Environment:
  ARKFILE_DESKTOP_CONTENT_CATALOG   Source desktop www/catalog/content-catalog.json
  ARKFILE_DESKTOP_CONTENT_LICENSE_INDEX Source desktop public title-license projection
  ARKFILE_IOS_CONTENT_CATALOG_OUT   Output path for the iOS catalog
  ARKFILE_IOS_CONTENT_LICENSE_INDEX Bundled iOS public projection path
  ARKFILE_IOS_TITLE_SUMMARIES       Curated book and document summary ledger
`);
}

function log(message) {
  console.log(`[arkfile-ios-catalog] ${message}`);
}

function fail(message) {
  console.error(`[arkfile-ios-catalog] ERROR: ${message}`);
  process.exit(1);
}

function findSourceCatalog(explicitSource) {
  if (explicitSource) {
    if (!fs.existsSync(explicitSource)) fail(`Source catalog not found: ${explicitSource}`);
    return explicitSource;
  }
  return DEFAULT_SOURCE_CANDIDATES.find((candidate) => fs.existsSync(candidate)) || '';
}

function findSourceLicenseIndex(explicitSource) {
  if (explicitSource) {
    if (!fs.existsSync(explicitSource)) fail(`Source content license index not found: ${explicitSource}`);
    return explicitSource;
  }
  return DEFAULT_LICENSE_SOURCE_CANDIDATES.find((candidate) => fs.existsSync(candidate)) || '';
}

function readJSON(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    fail(`Could not read ${filePath}: ${error.message}`);
  }
}

function sha256(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function normalizeRelativePath(value) {
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
    const fields = Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`);
    return `{${fields.join(',')}}`;
  }
  return JSON.stringify(value);
}

function projectionHashFor(index) {
  const core = {
    schemaVersion: index.schemaVersion,
    ledgerVersion: index.ledgerVersion,
    coverage: index.coverage,
    entries: index.entries,
  };
  return crypto.createHash('sha256').update(stableStringify(core)).digest('hex');
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isSafePublicURL(value) {
  if (!isNonEmptyString(value)) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' || url.protocol === 'http:';
  } catch {
    return false;
  }
}

function publicLicenseFieldsFor(entry, index) {
  return {
    licenseId: entry.license.id,
    licenseName: entry.license.name,
    licenseUrl: entry.license.url,
    sourceUrl: entry.source.canonicalUrl,
    attributionText: entry.notices.attributionText,
    changesMade: entry.notices.changesMade,
    contentLicenseLedgerVersion: index.ledgerVersion,
    contentLicenseProjectionHash: index.projectionHash,
    contentLicenseDecisionStatus: entry.decision.status,
  };
}

function licenseEntriesByPath(index) {
  return new Map((index.entries || []).map((entry) => [
    normalizeRelativePath(entry?.artifact?.relativePath),
    entry,
  ]));
}

function foldedLicenseEntriesByPath(index) {
  return new Map((index.entries || []).map((entry) => [
    normalizeRelativePath(entry?.artifact?.relativePath).toLowerCase(),
    entry,
  ]));
}

function isTitleSummaryEligible(item) {
  return ['htmlbook', 'html', 'pdf'].includes(String(item?.type || ''))
    && String(item?.subcategory || '') !== 'Open Textbooks'
    && String(item?.subcategory || '') !== 'National Maps';
}

function titleSummaryEntriesByPath(ledger) {
  return new Map((ledger.entries || []).map((entry) => [
    normalizeRelativePath(entry?.relativePath),
    entry,
  ]));
}

function foldedTitleSummaryEntriesByPath(ledger) {
  return new Map((ledger.entries || []).map((entry) => [
    normalizeRelativePath(entry?.relativePath).toLowerCase(),
    entry,
  ]));
}

function gitCommitFor(filePath) {
  let directory = fs.statSync(filePath).isDirectory() ? filePath : path.dirname(filePath);
  while (directory && directory !== path.dirname(directory)) {
    if (fs.existsSync(path.join(directory, '.git'))) {
      try {
        return execFileSync('git', ['-C', directory, 'rev-parse', 'HEAD'], {
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore'],
        }).trim();
      } catch {
        return '';
      }
    }
    directory = path.dirname(directory);
  }
  return '';
}

function isLiteItem(item) {
  const tiers = Array.isArray(item.availableInTiers) ? item.availableInTiers : [];
  return item.minimumTier === 'lite' || tiers.includes('lite') || item.requiredPack === 'essentials';
}

function isCompleteItem(item) {
  const tiers = Array.isArray(item.availableInTiers) ? item.availableInTiers : [];
  return item.minimumTier === 'complete' || tiers.includes('complete') || item.requiredPack === 'complete';
}

function isIOSInstallableItem(item) {
  return isLiteItem(item) || isCompleteItem(item);
}

function normalizedAvailableTiers(item) {
  const tiers = new Set();
  if (isLiteItem(item)) {
    tiers.add('lite');
    tiers.add('complete');
  } else if (isCompleteItem(item)) {
    tiers.add('complete');
  }
  return ['lite', 'complete'].filter((tier) => tiers.has(tier));
}

function normalizedIOSLicenseTiers(entry) {
  const tiers = Array.isArray(entry?.artifact?.includedInTiers)
    ? entry.artifact.includedInTiers
    : [];
  return ['lite', 'complete'].filter((tier) => tiers.includes(tier));
}

function normalizeIOSItem(item, licenseEntry, licenseIndex, titleSummaryEntry) {
  const relativePath = normalizeRelativePath(item.relativePath);
  const size = Number(item.size ?? item.sizeBytes ?? 0);
  const availableInTiers = normalizedAvailableTiers(item);
  const minimumTier = availableInTiers.includes('lite') ? 'lite' : 'complete';
  const normalized = {
    id: relativePath.toLowerCase(),
    name: String(item.name || path.basename(relativePath)),
    relativePath,
    category: String(item.category || relativePath.split('/')[0] || ''),
    subcategory: String(item.subcategory || 'Other'),
    type: String(item.type || ''),
    size,
    availableInTiers,
    minimumTier,
    requiredPack: minimumTier === 'lite' ? 'essentials' : 'complete',
  };
  if (typeof item.variantGroup === 'string' && item.variantGroup.trim()) {
    normalized.variantGroup = item.variantGroup.trim();
  }
  if (typeof item.variantLabel === 'string' && item.variantLabel.trim()) {
    normalized.variantLabel = item.variantLabel.trim();
  }
  if (typeof item.variantDefault === 'boolean') {
    normalized.variantDefault = item.variantDefault;
  }
  if (typeof item.defaultSelected === 'boolean') {
    normalized.defaultSelected = item.defaultSelected;
  }
  if (isNonEmptyString(titleSummaryEntry?.summary)) {
    normalized.summary = titleSummaryEntry.summary.trim();
  }
  for (const field of PUBLIC_LICENSE_FIELD_NAMES) {
    if (isNonEmptyString(item[field])) {
      normalized[field] = item[field].trim();
    }
  }
  if (licenseEntry) {
    if (size !== licenseEntry.artifact.sizeBytes) {
      fail(`Desktop catalog size conflicts with the reviewed artifact for ${relativePath}`);
    }
    if (stableStringify(availableInTiers) !== stableStringify(normalizedIOSLicenseTiers(licenseEntry))) {
      fail(`Desktop catalog iOS tiers conflict with the reviewed artifact for ${relativePath}`);
    }
    const expectedFields = publicLicenseFieldsFor(licenseEntry, licenseIndex);
    for (const [field, expectedValue] of Object.entries(expectedFields)) {
      if (normalized[field] != null && normalized[field] !== expectedValue) {
        fail(`Desktop catalog ${field} conflicts with the public license index for ${relativePath}`);
      }
      normalized[field] = expectedValue;
    }
  }
  return normalized;
}

function mapRegionCatalogItems() {
  if (!fs.existsSync(DEFAULT_REGION_INDEX_PATH)) return [];
  const index = readJSON(DEFAULT_REGION_INDEX_PATH);
  const regions = Array.isArray(index.regions) ? index.regions : [];
  return regions.map((region) => {
    const id = String(region.id || '').trim();
    const displayName = String(region.displayName || region.name || id);
    const maxZoom = Number(region.maxZoom || 14);
    const relativePath = `maps/regions/${id}/region.pmtiles`;
    return {
      id: relativePath.toLowerCase(),
      name: `Street Map — ${displayName} (z${maxZoom})`,
      relativePath,
      category: 'travel',
      subcategory: 'Street-Level Maps (Complete)',
      type: 'map',
      size: Number(region.sizeBytes || 0),
      availableInTiers: ['complete'],
      minimumTier: 'complete',
      requiredPack: 'complete',
      defaultSelected: false,
    };
  }).filter((item) => item.relativePath !== 'maps/regions//region.pmtiles');
}

function buildIOSCatalog(sourcePath, licenseIndex, titleSummaryLedger) {
  const source = readJSON(sourcePath);
  const categories = Object.fromEntries(CATEGORY_KEYS.map((key) => [key, []]));
  const entriesByPath = licenseEntriesByPath(licenseIndex);
  const foldedEntriesByPath = foldedLicenseEntriesByPath(licenseIndex);
  const summariesByPath = titleSummaryEntriesByPath(titleSummaryLedger);
  const foldedSummariesByPath = foldedTitleSummaryEntriesByPath(titleSummaryLedger);

  function licenseEntryFor(relativePath) {
    const exact = entriesByPath.get(relativePath);
    if (exact) return exact;
    const caseMatch = foldedEntriesByPath.get(relativePath.toLowerCase());
    if (caseMatch) {
      throw new Error(`catalog path case does not match reviewed artifact: ${relativePath} (expected ${caseMatch.artifact.relativePath})`);
    }
    return undefined;
  }

  function summaryEntryFor(relativePath) {
    const exact = summariesByPath.get(relativePath);
    if (exact) return exact;
    const caseMatch = foldedSummariesByPath.get(relativePath.toLowerCase());
    if (caseMatch) {
      throw new Error(`title summary path case does not match catalog: ${relativePath} (expected ${caseMatch.relativePath})`);
    }
    return undefined;
  }

  for (const category of CATEGORY_KEYS) {
    const items = source.categories && Array.isArray(source.categories[category])
      ? source.categories[category]
      : [];
    for (const item of items) {
      if (!isIOSInstallableItem(item)) continue;
      const itemPath = normalizeRelativePath(item.relativePath);
      categories[category].push(normalizeIOSItem(
        item,
        licenseEntryFor(itemPath),
        licenseIndex,
        summaryEntryFor(itemPath),
      ));
    }
  }
  const regionItems = mapRegionCatalogItems();
  const existingPaths = new Set(categories.travel.map((item) => item.relativePath.toLowerCase()));
  for (const item of regionItems) {
    if (!existingPaths.has(item.relativePath.toLowerCase())) {
      const entry = licenseEntryFor(item.relativePath);
      categories.travel.push(normalizeIOSItem(item, entry, licenseIndex, summaryEntryFor(item.relativePath)));
      existingPaths.add(item.relativePath.toLowerCase());
    }
  }

  const sourceHash = sha256(sourcePath);
  return {
    schemaVersion: 1,
    product: 'ArkFile',
    description: 'iOS catalog metadata for showing ArkFile Essentials and Complete titles before content packs are installed. This file does not contain paid content payloads or desktop-only Standard SKUs.',
    tiers: IOS_TIER_LABELS,
    source: {
      // Describe the source within its project without publishing a local worktree name.
      desktopCatalogPath: 'www/catalog/content-catalog.json',
      desktopCatalogSHA256: sourceHash,
      desktopCommit: gitCommitFor(sourcePath),
    },
    contentLicenses: {
      ledgerVersion: licenseIndex.ledgerVersion,
      projectionHash: licenseIndex.projectionHash,
      coverageComplete: licenseIndex.coverage.complete,
    },
    categories,
  };
}

function validateTitleSummaryLedger(ledger, catalog) {
  const errors = [];
  if (ledger?.schemaVersion !== 1) {
    errors.push(`title summary schemaVersion must be 1; received ${ledger?.schemaVersion}`);
  }
  if (!Array.isArray(ledger?.entries)) {
    return [...errors, 'title summary entries must be an array'];
  }

  const catalogItems = flattenItems(catalog);
  const catalogByPath = new Map(catalogItems.map((item) => [
    normalizeRelativePath(item.relativePath),
    item,
  ]));
  const catalogByFoldedPath = new Map(catalogItems.map((item) => [
    normalizeRelativePath(item.relativePath).toLowerCase(),
    item,
  ]));
  const ledgerByPath = titleSummaryEntriesByPath(ledger);
  const seen = new Set();

  for (const entry of ledger.entries) {
    const relativePath = normalizeRelativePath(entry?.relativePath);
    const foldedPath = relativePath.toLowerCase();
    if (!relativePath) errors.push('title summary entry is missing relativePath');
    if (seen.has(foldedPath)) errors.push(`duplicate title summary path: ${relativePath}`);
    seen.add(foldedPath);

    const catalogItem = catalogByPath.get(relativePath);
    if (!catalogItem) {
      const caseMatch = catalogByFoldedPath.get(foldedPath);
      errors.push(caseMatch
        ? `title summary path case does not match catalog: ${relativePath} (expected ${caseMatch.relativePath})`
        : `orphan title summary path is not in the iOS catalog: ${relativePath}`);
      continue;
    }
    if (!isTitleSummaryEligible(catalogItem)) {
      errors.push(`title summary is not allowed for excluded item: ${relativePath}`);
    }
    if (!isNonEmptyString(entry.summary)) {
      errors.push(`title summary is empty: ${relativePath}`);
    } else if (entry.summary.trim().length < 30 || entry.summary.trim().length > 360) {
      errors.push(`title summary must be 30-360 characters: ${relativePath}`);
    }
  }

  for (const item of catalogItems) {
    const relativePath = normalizeRelativePath(item.relativePath);
    const hasLedgerEntry = seen.has(relativePath.toLowerCase());
    if (isTitleSummaryEligible(item) && !hasLedgerEntry) {
      errors.push(`eligible title is missing a summary: ${relativePath}`);
    }
    if (isTitleSummaryEligible(item)
        && item.summary !== ledgerByPath.get(relativePath)?.summary?.trim()) {
      errors.push(`catalog title summary is missing or stale: ${relativePath}`);
    }
    if (!isTitleSummaryEligible(item) && isNonEmptyString(item.summary)) {
      errors.push(`excluded catalog item carries a title summary: ${relativePath}`);
    }
  }
  return errors;
}

function flattenItems(catalog) {
  return CATEGORY_KEYS.flatMap((category) => {
    const items = catalog.categories && Array.isArray(catalog.categories[category])
      ? catalog.categories[category]
      : [];
    return items.map((item) => ({ ...item, categoryKey: category }));
  });
}

function validatePublicKeys(value, allowed, label, errors) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return;
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) errors.push(`${label} contains an unapproved public field: ${key}`);
  }
}

function validateLicenseIndex(index, options = {}) {
  const errors = [];
  if (!index || typeof index !== 'object' || Array.isArray(index)) {
    return ['content license index must be a JSON object'];
  }
  validatePublicKeys(index, ['schemaVersion', 'ledgerVersion', 'coverage', 'entries', 'projectionHash'], 'content license index', errors);
  validatePublicKeys(index.coverage, ['expectedArtifacts', 'greenArtifacts', 'retiredArtifacts', 'incompleteArtifacts', 'complete'], 'content license coverage', errors);
  if (index.schemaVersion !== 1) {
    errors.push(`content license index schemaVersion must be 1; received ${index.schemaVersion}`);
  }
  if (!isNonEmptyString(index.ledgerVersion)) {
    errors.push('content license index ledgerVersion must be a non-empty string');
  }
  if (!SHA256_PATTERN.test(String(index.projectionHash || ''))) {
    errors.push('content license index projectionHash must be a lowercase SHA-256 digest');
  }
  if (!index.coverage || typeof index.coverage !== 'object' || Array.isArray(index.coverage)) {
    errors.push('content license index coverage must be an object');
  } else {
    for (const field of ['expectedArtifacts', 'greenArtifacts', 'retiredArtifacts', 'incompleteArtifacts']) {
      if (!Number.isSafeInteger(index.coverage[field]) || index.coverage[field] < 0) {
        errors.push(`content license index coverage.${field} must be a non-negative integer`);
      }
    }
    if (typeof index.coverage.complete !== 'boolean') {
      errors.push('content license index coverage.complete must be boolean');
    }
  }
  if (!Array.isArray(index.entries)) {
    errors.push('content license index entries must be an array');
    return errors;
  }

  const seenPaths = new Set();
  const seenContentIDs = new Set();
  let previousPath = '';
  let greenCount = 0;
  let incompleteCount = 0;
  for (const [entryIndex, entry] of index.entries.entries()) {
    const prefix = `content license entry ${entryIndex + 1}`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      errors.push(`${prefix} must be an object`);
      continue;
    }
    validatePublicKeys(entry, ['contentId', 'displayName', 'artifact', 'source', 'license', 'notices', 'downstreamRights', 'decision'], prefix, errors);
    validatePublicKeys(entry.artifact, ['relativePath', 'type', 'sha256', 'sizeBytes', 'editionOrRevision', 'includedInTiers'], `${prefix}.artifact`, errors);
    validatePublicKeys(entry.source, ['title', 'creators', 'publisher', 'canonicalUrl', 'artifactUrl', 'retrievedAt'], `${prefix}.source`, errors);
    validatePublicKeys(entry.license, ['id', 'name', 'url', 'commercialUse', 'redistribution', 'modification', 'shareAlike', 'attributionRequired', 'noAdditionalRestrictions'], `${prefix}.license`, errors);
    validatePublicKeys(entry.notices, ['attributionText', 'changesMade', 'requiredInternalFiles'], `${prefix}.notices`, errors);
    validatePublicKeys(entry.downstreamRights, ['summary', 'allowedDistributionModes'], `${prefix}.downstreamRights`, errors);
    validatePublicKeys(entry.decision, ['status', 'reviewedAt'], `${prefix}.decision`, errors);
    if (/(?:private pilot ledger|internal notes?|counsel review|\/Users\/|\/Volumes\/)/i.test(JSON.stringify(entry))) {
      errors.push(`${prefix} contains private publication metadata`);
    }
    if (!isNonEmptyString(entry.contentId)) errors.push(`${prefix} is missing contentId`);
    if (!isNonEmptyString(entry.displayName)) errors.push(`${prefix} is missing displayName`);
    const contentIDKey = String(entry.contentId || '').toLowerCase();
    if (contentIDKey && seenContentIDs.has(contentIDKey)) errors.push(`duplicate contentId: ${entry.contentId}`);
    seenContentIDs.add(contentIDKey);

    const artifact = entry.artifact;
    const relativePath = normalizeRelativePath(artifact?.relativePath);
    const pathKey = relativePath.toLowerCase();
    if (!relativePath) errors.push(`${prefix} is missing artifact.relativePath`);
    if (pathKey && seenPaths.has(pathKey)) errors.push(`duplicate content license relativePath: ${relativePath}`);
    seenPaths.add(pathKey);
    if (previousPath && previousPath > relativePath) {
      errors.push(`content license entries are not sorted by canonical relativePath: ${relativePath}`);
    }
    previousPath = relativePath;
    if (!isNonEmptyString(artifact?.type)) errors.push(`${prefix} is missing artifact.type`);
    if (!SHA256_PATTERN.test(String(artifact?.sha256 || ''))) errors.push(`${prefix} has invalid artifact.sha256`);
    if (!Number.isSafeInteger(artifact?.sizeBytes) || artifact.sizeBytes < 0) errors.push(`${prefix} has invalid artifact.sizeBytes`);
    if (!isNonEmptyString(artifact?.editionOrRevision)) errors.push(`${prefix} is missing artifact.editionOrRevision`);
    if (!Array.isArray(artifact?.includedInTiers) || artifact.includedInTiers.length < 1) {
      errors.push(`${prefix} is missing artifact.includedInTiers`);
    }

    const source = entry.source;
    for (const field of ['title', 'publisher', 'canonicalUrl', 'retrievedAt']) {
      if (!isNonEmptyString(source?.[field])) errors.push(`${prefix} is missing source.${field}`);
    }
    if (isNonEmptyString(source?.canonicalUrl) && !isSafePublicURL(source.canonicalUrl)) {
      errors.push(`${prefix} has unsafe source.canonicalUrl`);
    }
    if (source?.artifactUrl != null && !isSafePublicURL(source.artifactUrl)) {
      errors.push(`${prefix} has unsafe source.artifactUrl`);
    }
    if (!Array.isArray(source?.creators) || source.creators.length < 1 || source.creators.some((value) => !isNonEmptyString(value))) {
      errors.push(`${prefix} has invalid source.creators`);
    }

    const license = entry.license;
    for (const field of ['id', 'name', 'url']) {
      if (!isNonEmptyString(license?.[field])) errors.push(`${prefix} is missing license.${field}`);
    }
    if (isNonEmptyString(license?.url) && !isSafePublicURL(license.url)) {
      errors.push(`${prefix} has unsafe license.url`);
    }
    for (const field of ['commercialUse', 'redistribution', 'modification']) {
      if (!LICENSE_PERMISSION_VALUES.has(license?.[field])) errors.push(`${prefix} has invalid license.${field}`);
    }
    for (const field of ['shareAlike', 'attributionRequired', 'noAdditionalRestrictions']) {
      if (typeof license?.[field] !== 'boolean') errors.push(`${prefix} has invalid license.${field}`);
    }

    const notices = entry.notices;
    if (!isNonEmptyString(notices?.attributionText)) errors.push(`${prefix} is missing notices.attributionText`);
    if (!isNonEmptyString(notices?.changesMade)) errors.push(`${prefix} is missing notices.changesMade`);
    if (!Array.isArray(notices?.requiredInternalFiles)) errors.push(`${prefix} has invalid notices.requiredInternalFiles`);

    const status = entry.decision?.status;
    const downstreamRights = entry.downstreamRights;
    if (!isNonEmptyString(downstreamRights?.summary)) errors.push(`${prefix} is missing downstreamRights.summary`);
    if (!Array.isArray(downstreamRights?.allowedDistributionModes)
        || (status === 'green' && downstreamRights.allowedDistributionModes.length < 1)
        || downstreamRights.allowedDistributionModes.some((mode) => !DISTRIBUTION_MODES.has(mode))) {
      errors.push(`${prefix} has invalid downstreamRights.allowedDistributionModes`);
    }

    if (!LICENSE_DECISION_STATUSES.has(status)) errors.push(`${prefix} has invalid decision.status`);
    if (!isNonEmptyString(entry.decision?.reviewedAt)) errors.push(`${prefix} is missing decision.reviewedAt`);
    if (status === 'green') greenCount += 1;
    else incompleteCount += 1;
  }

  if (SHA256_PATTERN.test(String(index.projectionHash || ''))) {
    const expectedHash = projectionHashFor(index);
    if (index.projectionHash !== expectedHash) {
      errors.push(`content license index projectionHash is stale; expected ${expectedHash}`);
    }
  }
  if (index.coverage && typeof index.coverage === 'object') {
    if (index.coverage.greenArtifacts !== greenCount) errors.push('content license coverage.greenArtifacts does not match green entries');
    if (index.entries.length !== greenCount) errors.push('public content license entries must contain only green decisions');
    if (index.coverage.incompleteArtifacts < incompleteCount) {
      errors.push('content license coverage.incompleteArtifacts cannot be lower than incomplete entries');
    }
    if (index.coverage.expectedArtifacts
        !== index.coverage.greenArtifacts + index.coverage.retiredArtifacts + index.coverage.incompleteArtifacts) {
      errors.push('content license coverage.expectedArtifacts must equal green, retired, and incomplete artifacts');
    }
    if (index.coverage.complete && index.coverage.incompleteArtifacts !== 0) {
      errors.push('content license coverage.complete cannot be true while entries are incomplete');
    }
  }
  if (options.requireContentLicenses) {
    if (index.ledgerVersion === 'bootstrap-unverified') {
      errors.push('strict content-license validation cannot use the bootstrap-unverified ledger');
    }
    if (index.coverage?.complete !== true) {
      errors.push('strict content-license validation requires coverage.complete to be true');
    }
    if (index.coverage?.incompleteArtifacts !== 0) {
      errors.push('strict content-license validation requires coverage.incompleteArtifacts to be zero');
    }
  }
  return errors;
}

function validateCatalog(catalog, options = {}) {
  const errors = [];
  validatePublicKeys(catalog, ['schemaVersion', 'product', 'description', 'tiers', 'source', 'contentLicenses', 'categories'], 'catalog', errors);
  validatePublicKeys(catalog.tiers, ['lite', 'complete'], 'catalog tiers', errors);
  validatePublicKeys(catalog.source, ['desktopCatalogPath', 'desktopCatalogSHA256', 'desktopCommit'], 'catalog source', errors);
  if (catalog.source?.desktopCatalogPath != null
      && catalog.source.desktopCatalogPath !== 'www/catalog/content-catalog.json') {
    errors.push('catalog source path must use the public project-relative location');
  }
  validatePublicKeys(catalog.contentLicenses, ['ledgerVersion', 'projectionHash', 'coverageComplete'], 'catalog contentLicenses', errors);
  validatePublicKeys(catalog.categories, CATEGORY_KEYS, 'catalog categories', errors);
  for (const categoryItems of Object.values(catalog.categories || {})) {
    for (const item of Array.isArray(categoryItems) ? categoryItems : []) {
      validatePublicKeys(item, ['id', 'name', 'type', 'size', 'relativePath', 'category', 'subcategory', 'minimumTier', 'requiredPack', 'availableInTiers', 'defaultSelected', 'variantGroup', 'variantLabel', 'variantDefault', 'summary', ...PUBLIC_LICENSE_FIELD_NAMES], 'catalog item', errors);
    }
  }
  if (catalog.schemaVersion !== 1) errors.push(`schemaVersion must be 1; received ${catalog.schemaVersion}`);
  if (catalog.product !== 'ArkFile') errors.push(`product must be ArkFile; received ${catalog.product}`);
  if (!catalog.tiers || catalog.tiers.lite !== IOS_TIER_LABELS.lite) errors.push('tiers.lite must be ArkFile Essentials');
  if (!catalog.tiers || catalog.tiers.complete !== IOS_TIER_LABELS.complete) errors.push('tiers.complete must be ArkFile Complete');

  const items = flattenItems(catalog);
  const licenseIndex = options.licenseIndex;
  const entriesByPath = licenseIndex ? licenseEntriesByPath(licenseIndex) : new Map();
  const foldedEntriesByPath = licenseIndex ? foldedLicenseEntriesByPath(licenseIndex) : new Map();
  if (items.length < MIN_EXPECTED_IOS_ENTRIES) {
    errors.push(`catalog only contains ${items.length} iOS entries; expected at least ${MIN_EXPECTED_IOS_ENTRIES}`);
  }

  for (const category of CATEGORY_KEYS) {
    const categoryItems = catalog.categories && Array.isArray(catalog.categories[category])
      ? catalog.categories[category]
      : [];
    if (!categoryItems.length) errors.push(`category has no Essentials preview entries: ${category}`);
  }

  const seen = new Set();
  for (const item of items) {
    const relativePath = normalizeRelativePath(item.relativePath);
    if (!relativePath) errors.push('catalog item is missing relativePath');
    const key = relativePath.toLowerCase();
    if (seen.has(key)) errors.push(`duplicate catalog relativePath: ${relativePath}`);
    seen.add(key);

    if (item.category !== item.categoryKey) {
      errors.push(`catalog item category mismatch for ${relativePath}: ${item.category} in ${item.categoryKey}`);
    }
    if (!['lite', 'complete'].includes(item.minimumTier)) {
      errors.push(`minimumTier must be lite or complete in iOS catalog: ${relativePath}`);
    }
    const expectedRequiredPack = item.minimumTier === 'lite' ? 'essentials' : 'complete';
    if (item.requiredPack !== expectedRequiredPack) {
      errors.push(`requiredPack must be ${expectedRequiredPack}: ${relativePath}`);
    }
    if (!Array.isArray(item.availableInTiers) || item.availableInTiers.length < 1) {
      errors.push(`availableInTiers must not be empty: ${relativePath}`);
    } else if (item.availableInTiers.some((tier) => !['lite', 'complete'].includes(tier))) {
      errors.push(`availableInTiers contains non-iOS tier for ${relativePath}: ${item.availableInTiers.join(',')}`);
    } else if (item.minimumTier === 'lite' && !item.availableInTiers.includes('lite')) {
      errors.push(`Essentials item must include lite availability: ${relativePath}`);
    } else if (item.minimumTier === 'complete' && item.availableInTiers.includes('lite')) {
      errors.push(`Complete-only item must not include lite availability: ${relativePath}`);
    } else if (!item.availableInTiers.includes('complete')) {
      errors.push(`Every iOS catalog item must be available to Complete: ${relativePath}`);
    }
    if (!['zim', 'pdf', 'htmlbook', 'image', 'html', 'map'].includes(item.type)) {
      errors.push(`unsupported content type for ${relativePath}: ${item.type}`);
    }
    if (!Number.isSafeInteger(item.size) || item.size < 0) {
      errors.push(`invalid size for ${relativePath}: ${item.size}`);
    }
    if (item.defaultSelected != null && typeof item.defaultSelected !== 'boolean') {
      errors.push(`defaultSelected must be boolean when present: ${relativePath}`);
    }

    const presentLicenseFields = PUBLIC_LICENSE_FIELD_NAMES.filter((field) => isNonEmptyString(item[field]));
    const licenseEntry = entriesByPath.get(relativePath);
    const caseMatch = licenseEntry ? undefined : foldedEntriesByPath.get(key);
    if (caseMatch) {
      errors.push(`catalog path case does not match reviewed artifact: ${relativePath} (expected ${caseMatch.artifact.relativePath})`);
    }
    if (presentLicenseFields.length > 0 && presentLicenseFields.length !== PUBLIC_LICENSE_FIELD_NAMES.length) {
      const missing = PUBLIC_LICENSE_FIELD_NAMES.filter((field) => !isNonEmptyString(item[field]));
      errors.push(`partial content-license metadata for ${relativePath}; missing ${missing.join(',')}`);
    }
    if (presentLicenseFields.length > 0 && !licenseEntry) {
      errors.push(`catalog has content-license metadata without a public index entry: ${relativePath}`);
    }
    if (licenseEntry) {
      if (Number(item.size) !== Number(licenseEntry.artifact.sizeBytes)) {
        errors.push(`catalog size does not match reviewed artifact for ${relativePath}`);
      }
      if (stableStringify(item.availableInTiers) !== stableStringify(normalizedIOSLicenseTiers(licenseEntry))) {
        errors.push(`catalog iOS tiers do not match reviewed artifact for ${relativePath}`);
      }
      const expectedFields = publicLicenseFieldsFor(licenseEntry, licenseIndex);
      for (const [field, expectedValue] of Object.entries(expectedFields)) {
        if (item[field] !== expectedValue) {
          errors.push(`catalog ${field} is missing or stale for ${relativePath}`);
        }
      }
    }
    if (options.requireContentLicenses) {
      if (!licenseEntry) errors.push(`strict content-license coverage is missing: ${relativePath}`);
      else if (licenseEntry.decision.status !== 'green') {
        errors.push(`strict content-license coverage requires green status for ${relativePath}; received ${licenseEntry.decision.status}`);
      } else if (!licenseEntry.downstreamRights.allowedDistributionModes.includes('local-sharing')) {
        errors.push(`strict content-license coverage requires local-sharing permission for ${relativePath}`);
      }
    }
  }

  const catalogLicenseMetadata = catalog.contentLicenses;
  if (catalogLicenseMetadata) {
    if (catalogLicenseMetadata.ledgerVersion !== licenseIndex?.ledgerVersion) {
      errors.push('catalog content-license ledgerVersion does not match bundled index');
    }
    if (catalogLicenseMetadata.projectionHash !== licenseIndex?.projectionHash) {
      errors.push('catalog content-license projectionHash does not match bundled index');
    }
    if (catalogLicenseMetadata.coverageComplete !== licenseIndex?.coverage?.complete) {
      errors.push('catalog content-license coverageComplete does not match bundled index');
    }
  } else if (entriesByPath.size > 0 || options.requireContentLicenses) {
    errors.push('catalog is missing contentLicenses projection metadata');
  }

  const byPath = new Set(items.map((item) => String(item.relativePath || '').toLowerCase()));
  for (const requiredPath of REQUIRED_LITE_PATHS) {
    if (!byPath.has(requiredPath.toLowerCase())) {
      errors.push(`required Essentials preview entry is missing: ${requiredPath}`);
    }
  }
  for (const requiredPath of REQUIRED_COMPLETE_PATHS) {
    if (!byPath.has(requiredPath.toLowerCase())) {
      errors.push(`required Complete preview entry is missing: ${requiredPath}`);
    }
  }

  if (options.sourcePath && fs.existsSync(options.sourcePath)) {
    const expectedHash = sha256(options.sourcePath);
    const actualHash = catalog.source && catalog.source.desktopCatalogSHA256;
    if (actualHash && actualHash !== expectedHash) {
      errors.push(`bundled catalog is stale for ${options.sourcePath}; run scripts/arkfile-build-lite-content-catalog.mjs`);
    }
  }

  return errors;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.skipTitleSummaries && !args.validateOnly) {
    fail('--skip-title-summaries is valid only with --validate-only');
  }
  if (!args.skipTitleSummaries && !fs.existsSync(args.titleSummaries)) {
    fail(`Title summary ledger not found: ${args.titleSummaries}`);
  }
  const titleSummaryLedger = args.skipTitleSummaries ? null : readJSON(args.titleSummaries);
  const sourcePath = findSourceCatalog(args.source);
  const sourceLicenseIndexPath = args.validateOnly ? '' : findSourceLicenseIndex(args.licenseSource);
  const effectiveLicenseIndexPath = sourceLicenseIndexPath || args.licenseIndex;
  if (!fs.existsSync(effectiveLicenseIndexPath)) {
    fail(`Content license index not found: ${effectiveLicenseIndexPath}`);
  }
  const licenseIndex = readJSON(effectiveLicenseIndexPath);
  const indexErrors = validateLicenseIndex(licenseIndex, {
    requireContentLicenses: args.requireContentLicenses,
  });
  if (indexErrors.length) fail(indexErrors.join('; '));

  if (args.validateOnly) {
    if (!fs.existsSync(args.output)) fail(`Bundled catalog not found: ${args.output}`);
    const catalog = readJSON(args.output);
    const errors = validateCatalog(catalog, {
      sourcePath,
      licenseIndex,
      requireContentLicenses: args.requireContentLicenses,
    });
    if (titleSummaryLedger) {
      errors.push(...validateTitleSummaryLedger(titleSummaryLedger, catalog));
    }
    if (errors.length) fail(errors.join('; '));
    log(`Validated ${flattenItems(catalog).length} iOS catalog entries at ${path.relative(ROOT_DIR, args.output)}`);
    return;
  }

  if (!sourcePath) {
    fail('No desktop content catalog found. Set ARKFILE_DESKTOP_CONTENT_CATALOG or pass --source.');
  }

  const catalog = buildIOSCatalog(sourcePath, licenseIndex, titleSummaryLedger);
  const errors = validateCatalog(catalog, {
    sourcePath,
    licenseIndex,
    requireContentLicenses: args.requireContentLicenses,
  });
  errors.push(...validateTitleSummaryLedger(titleSummaryLedger, catalog));
  if (errors.length) fail(errors.join('; '));

  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, JSON.stringify(catalog, null, 2) + '\n', 'utf8');
  if (path.resolve(effectiveLicenseIndexPath) !== path.resolve(args.licenseIndex)) {
    fs.mkdirSync(path.dirname(args.licenseIndex), { recursive: true });
    fs.copyFileSync(effectiveLicenseIndexPath, args.licenseIndex);
    log(`Copied the full public content-license projection to ${path.relative(ROOT_DIR, args.licenseIndex)}`);
  }
  log(`Wrote ${flattenItems(catalog).length} iOS catalog entries to ${path.relative(ROOT_DIR, args.output)}`);
}

if (process.argv[1] && fs.existsSync(process.argv[1])
    && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))) {
  main();
}

export {
  normalizeIOSItem,
  projectionHashFor,
  validateCatalog,
  validateLicenseIndex,
  validateTitleSummaryLedger,
  isTitleSummaryEligible,
};

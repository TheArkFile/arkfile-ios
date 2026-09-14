#!/usr/bin/env node

/**
 * Produce and verify the portable evidence bundle for ArkFile's controlled
 * CoreKiwix build.  The implementation deliberately reads build products,
 * compiler databases, dependency files, and source inputs; it never reads the
 * build LOGS directory or copies the ambient process environment into evidence.
 */

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const EVIDENCE_FORMAT = 1;
export const EVIDENCE_POLICY = 'arkfile-corekiwix-native-evidence-v1';

export const OUTPUT_FILES = Object.freeze({
  manifest: 'CoreKiwixNativeBuildManifest.json',
  sourceLock: 'CoreKiwixNativeSource.lock.json',
  sbom: 'CoreKiwixNativeSBOM.spdx.json',
  objectMap: 'CoreKiwixNativeObjectMap.jsonl',
});

export const STALE_UPSTREAM_SHA256_DENY_LIST = Object.freeze([
  // Official libkiwix_xcframework-14.2.0-1.tar.gz.  It is not the controlled
  // build and did not retain the source/object/relink evidence required here.
  'a28b5eb16fb6309f719b1eda0b260d9b27e8f1cac462c75ce9077b2a51af2b2a',
  // Its three distributed merged.a slices.
  '54c061cc77a5c293e249356b0b99f45bc60931fad97f90d9b2c0a39489746a49',
  '66324fa8a07e65cbbf2bd033f638c4b9002f6c89f5c4954b220e6ed20a00162f',
  '6a7b90da01771039fc30e3ba01099bf4d4d689c050b1c69c9251eda56824a414',
].sort());

const SCRIPT_RELATIVE_PATH = 'scripts/arkfile-corekiwix-evidence.mjs';
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const GIT_SHA_PATTERN = /^[0-9a-f]{40}$/;
const SECRET_PATTERN = /(?:api[_-]?key|access[_-]?token|auth(?:orization)?|bearer|client[_-]?secret|password|private[_-]?key)\s*[:=]/iu;
const PRIVATE_KEY_PATTERN = /-----BEGIN [A-Z ]*PRIVATE KEY-----/u;
const SOURCE_SUFFIX_PATTERN = /\.(?:c|cc|cpp|cxx|m|mm|s|S)$/u;

const COMPONENTS = Object.freeze([
  {
    id: 'curl', name: 'curl', licenseDeclared: 'curl', licenseConcluded: 'curl', purlName: 'curl',
    sourcePattern: /^libcurl$/u, buildPattern: /^libcurl$/u,
    archivePatterns: [/^curl-[0-9].*\.tar\./u, /^curl_.*_patch\.zip$/u],
    installedArchives: ['libcurl.a'], licensePaths: ['COPYING'],
    versionFile: 'include/curl/curlver.h', versionPattern: /^#define LIBCURL_VERSION\s+"([^"]+)"/mu,
  },
  {
    id: 'icu', name: 'ICU', licenseDeclared: 'ICU', licenseConcluded: 'NOASSERTION', purlName: 'icu',
    sourcePattern: /^icu4c-([0-9.]+)$/u, buildPattern: /^icu4c-([0-9.]+)$/u,
    archivePatterns: [/^icu4c-.*-(?:src\.tgz|data\.zip)$/u],
    installedArchives: ['libicudata.a', 'libicui18n.a', 'libicuuc.a'],
    licensePaths: ['LICENSE', 'license.html'],
  },
  {
    id: 'libkiwix', name: 'libkiwix', licenseDeclared: 'GPL-3.0-or-later',
    licenseConcluded: 'GPL-3.0-or-later AND GPL-3.0-only AND BSD-3-Clause AND Zlib AND Apache-2.0 AND MIT AND OFL-1.1',
    purlName: 'libkiwix',
    sourcePattern: /^libkiwix_release$/u, buildPattern: /^libkiwix-([0-9.]+)$/u,
    archivePatterns: [], installedArchives: ['libkiwix.a'],
    licensePaths: [
      'COPYING', 'AUTHORS', 'static/skin/autoComplete/LICENSE',
      'src/tools/lrucache.h', 'src/tools/base64.cpp',
      'static/skin/isotope.pkgd.min.js', 'static/skin/mustache.min.js',
      'static/skin/fonts/DMSans-Regular.ttf', 'static/skin/fonts/Poppins.ttf',
      'static/skin/fonts/Roboto.ttf',
    ],
    versionFile: 'meson.build', versionPattern: /project\([^]*?version\s*:\s*'([^']+)'/u,
    gitSource: true,
  },
  {
    id: 'libmicrohttpd', name: 'libmicrohttpd',
    licenseDeclared: 'LGPL-2.1-or-later OR (GPL-2.0-or-later WITH eCos-exception-2.0)',
    licenseConcluded: 'LGPL-2.1-or-later', purlName: 'libmicrohttpd',
    sourcePattern: /^libmicrohttpd-([0-9.]+)$/u, buildPattern: /^libmicrohttpd-([0-9.]+)$/u,
    archivePatterns: [/^libmicrohttpd-[0-9].*\.tar\./u, /^libmicrohttpd_.*_patch\.zip$/u],
    installedArchives: ['libmicrohttpd.a'], licensePaths: ['COPYING', 'AUTHORS'],
  },
  {
    id: 'libzim', name: 'libzim', licenseDeclared: 'GPL-2.0-or-later',
    licenseConcluded: 'GPL-2.0-or-later AND BSD-3-Clause', purlName: 'libzim',
    sourcePattern: /^libzim_release$/u, buildPattern: /^libzim-([0-9.]+)$/u,
    archivePatterns: [/^zim-testing-suite-.*\.tar\./u], installedArchives: ['libzim.a'],
    licensePaths: ['COPYING', 'AUTHORS', 'src/lrucache.h'], versionFile: 'meson.build',
    versionPattern: /project\([^]*?version\s*:\s*'([^']+)'/u, gitSource: true,
  },
  {
    id: 'mustache', name: 'Mustache', licenseDeclared: 'BSL-1.0', licenseConcluded: 'BSL-1.0', purlName: 'mustache',
    sourcePattern: /^mustache-([0-9.]+)$/u, buildPattern: /^mustache-([0-9.]+)$/u,
    archivePatterns: [/^Mustache-[0-9].*\.tar\./u], installedArchives: [],
    licensePaths: ['LICENSE'], headerOnly: true,
  },
  {
    id: 'pugixml', name: 'pugixml', licenseDeclared: 'MIT', licenseConcluded: 'MIT', purlName: 'pugixml',
    sourcePattern: /^pugixml-([0-9.]+)$/u, buildPattern: /^pugixml-([0-9.]+)$/u,
    archivePatterns: [/^pugixml-[0-9].*\.tar\./u], installedArchives: ['libpugixml.a'],
    licensePaths: ['LICENSE.md'],
  },
  {
    id: 'xapian', name: 'Xapian', licenseDeclared: 'GPL-2.0-or-later',
    licenseConcluded: 'GPL-2.0-or-later AND MIT AND BSD-3-Clause AND BSL-1.0 AND Unicode-DFS-2016',
    purlName: 'xapian-core',
    sourcePattern: /^xapian-core-([0-9.]+)$/u, buildPattern: /^xapian-core-([0-9.]+)$/u,
    archivePatterns: [/^xapian-core-[0-9].*\.tar\./u], installedArchives: ['libxapian.a'],
    licensePaths: [
      'COPYING', 'AUTHORS', 'api/constinfo.cc', 'languages/steminternal.cc',
      'include/xapian/intrusive_ptr.h', 'unicode/UnicodeData-README.txt',
    ],
    versionFile: 'configure.ac',
    versionPattern: /AC_INIT\(\[xapian-core\],\s*\[([^\]]+)\]/u,
  },
  {
    id: 'xz', name: 'XZ Utils', licenseDeclared: 'LicenseRef-XZ-Utils-Public-Domain',
    licenseConcluded: 'LicenseRef-XZ-Utils-Public-Domain', purlName: 'xz',
    sourcePattern: /^lzma-([0-9.]+)$/u, buildPattern: /^lzma-([0-9.]+)$/u,
    archivePatterns: [/^xz-[0-9].*\.tar\./u, /^liblzma_.*_patch\.zip$/u],
    installedArchives: ['liblzma.a'],
    licensePaths: ['COPYING', 'AUTHORS', 'COPYING.GPLv2', 'COPYING.GPLv3', 'COPYING.LGPLv2.1'],
  },
  {
    id: 'zlib', name: 'zlib', licenseDeclared: 'Zlib', licenseConcluded: 'Zlib', purlName: 'zlib',
    sourcePattern: /^zlib-([0-9.]+)$/u, buildPattern: /^zlib-([0-9.]+)$/u,
    archivePatterns: [/^zlib-[0-9].*\.tar\./u, /^zlib_.*_patch\.zip$/u],
    installedArchives: ['libz.a'], licensePaths: ['LICENSE'],
  },
  {
    id: 'zstd', name: 'Zstandard', licenseDeclared: 'BSD-3-Clause OR GPL-2.0-only',
    licenseConcluded: 'BSD-3-Clause', purlName: 'zstd',
    sourcePattern: /^zstd-([0-9.]+)$/u, buildPattern: /^zstd-([0-9.]+)$/u,
    archivePatterns: [/^zstd-[0-9].*\.tar\./u], installedArchives: ['libzstd.a'],
    licensePaths: ['LICENSE', 'COPYING'],
  },
]);

const THIN_BUILDS = Object.freeze([
  { id: 'ios-device-arm64', platform: 'ios', architecture: 'arm64', patterns: [/^BUILD_(?:aarch64|arm64)-apple-ios$/u] },
  { id: 'ios-simulator-arm64', platform: 'ios-simulator', architecture: 'arm64', patterns: [/^BUILD_(?:aarch64|arm64)-apple-ios-simulator$/u] },
  { id: 'ios-simulator-x86_64', platform: 'ios-simulator', architecture: 'x86_64', patterns: [/^BUILD_(?:x86|x86_64)-apple-ios-simulator$/u] },
  { id: 'macos-arm64', platform: 'macos', architecture: 'arm64', patterns: [/^BUILD_(?:aarch64|arm64)-apple-(?:darwin|macos)$/u] },
  { id: 'macos-x86_64', platform: 'macos', architecture: 'x86_64', patterns: [/^BUILD_x86_64-apple-(?:darwin|macos)$/u] },
]);

const EXPECTED_FRAMEWORK_SLICES = Object.freeze([
  { identifier: 'ios-arm64', platform: 'ios', variant: null, architectures: ['arm64'] },
  { identifier: 'ios-arm64_x86_64-simulator', platform: 'ios', variant: 'simulator', architectures: ['arm64', 'x86_64'] },
  { identifier: 'macos-arm64_x86_64', platform: 'macos', variant: null, architectures: ['arm64', 'x86_64'] },
]);

export class CoreKiwixEvidenceError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CoreKiwixEvidenceError';
  }
}

function fail(message) {
  throw new CoreKiwixEvidenceError(message);
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function sha256File(filePath) {
  return sha256(readFileSync(filePath));
}

function canonicalJSON(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function canonicalHash(value) {
  return sha256(JSON.stringify(value));
}

function assertObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object.`);
  }
}

function assertExactKeys(value, expected, label) {
  assertObject(value, label);
  const actualKeys = Object.keys(value).sort();
  const expectedKeys = [...expected].sort();
  if (JSON.stringify(actualKeys) !== JSON.stringify(expectedKeys)) {
    fail(`${label} keys must be exactly: ${expectedKeys.join(', ')}.`);
  }
}

function assertString(value, label) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(`${label} must be a non-empty string.`);
  }
  if (value !== value.normalize('NFC') || /[\u0000-\u001f\u007f]/u.test(value)) {
    fail(`${label} must be normalized printable text.`);
  }
  if (SECRET_PATTERN.test(value) || PRIVATE_KEY_PATTERN.test(value)) {
    fail(`${label} contains secret-like material.`);
  }
}

function assertDigest(value, label) {
  if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) {
    fail(`${label} must be a lowercase SHA-256 digest.`);
  }
}

function assertInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(`${label} must be a nonnegative safe integer.`);
  }
}

export function assertSafeRelativePath(value, label = 'path') {
  assertString(value, label);
  if (value.startsWith('/') || /^[A-Za-z]:[\\/]/u.test(value) || value.includes('\\')) {
    fail(`${label} must be a portable relative path.`);
  }
  const pieces = value.split('/');
  if (pieces.some((piece) => piece === '' || piece === '.' || piece === '..')) {
    fail(`${label} must not contain empty, dot, or traversal components.`);
  }
}

function assertPortableValue(value, label = 'evidence') {
  if (typeof value === 'string') {
    assertString(value, label);
    if (value.startsWith('/') || /^[A-Za-z]:[\\/]/u.test(value)) {
      fail(`${label} contains an absolute filesystem path.`);
    }
    if (/(?:^|[\\/])\.\.(?:[\\/]|$)/u.test(value)) {
      fail(`${label} contains path traversal.`);
    }
    return;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertPortableValue(item, `${label}[${index}]`));
    return;
  }
  if (value && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) {
      assertString(key, `${label} key`);
      assertPortableValue(item, `${label}.${key}`);
    }
  }
}

function requireExistingDirectory(directoryPath, label) {
  if (!existsSync(directoryPath)) fail(`Missing ${label}: ${directoryPath}`);
  const entry = lstatSync(directoryPath);
  if (entry.isSymbolicLink() || !entry.isDirectory()) {
    fail(`${label} must be a real directory, not a symlink: ${directoryPath}`);
  }
  return realpathSync(directoryPath);
}

function requireRegularFile(filePath, label) {
  if (!existsSync(filePath)) fail(`Missing ${label}: ${filePath}`);
  const entry = lstatSync(filePath);
  if (entry.isSymbolicLink() || !entry.isFile()) {
    fail(`${label} must be a regular file, not a symlink: ${filePath}`);
  }
  return filePath;
}

function safeRelative(root, target, label) {
  const relative = path.relative(root, target).split(path.sep).join('/');
  assertSafeRelativePath(relative, label);
  return relative;
}

function fileSpec(root, filePath, label) {
  requireRegularFile(filePath, label);
  const relativePath = safeRelative(root, filePath, `${label} path`);
  const sizeBytes = statSync(filePath).size;
  return { path: relativePath, sizeBytes, sha256: sha256File(filePath) };
}

function listDirectoryNames(directoryPath, label) {
  return readdirSync(directoryPath, { withFileTypes: true }).map((entry) => {
    if (entry.isSymbolicLink()) fail(`${label} contains symlink ${entry.name}.`);
    return entry;
  });
}

function findExactlyOneDirectory(parent, patterns, label) {
  const matches = listDirectoryNames(parent, label)
    .filter((entry) => entry.isDirectory() && patterns.some((pattern) => pattern.test(entry.name)))
    .map((entry) => entry.name)
    .sort();
  if (matches.length !== 1) {
    fail(`${label} must match exactly one directory; found ${matches.length}: ${matches.join(', ') || '(none)'}.`);
  }
  return matches[0];
}

function resolveTool(candidates, label) {
  const tool = candidates.find((candidate) => existsSync(candidate));
  if (!tool) fail(`Required ${label} tool was not found at an approved absolute path.`);
  requireRegularFile(tool, `${label} tool`);
  return tool;
}

function runTool(tool, args, label, options = {}) {
  try {
    return execFileSync(tool, args, {
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
      ...options,
    });
  } catch (error) {
    const stderr = typeof error?.stderr === 'string' ? error.stderr.trim() : '';
    fail(`${label} failed${stderr ? `: ${stderr}` : '.'}`);
  }
}

function approvedTools() {
  return {
    ar: resolveTool(['/usr/bin/ar', '/usr/bin/llvm-ar'], 'ar'),
    nm: resolveTool(['/usr/bin/nm', '/usr/bin/llvm-nm'], 'nm'),
    lipo: resolveTool(['/usr/bin/lipo'], 'lipo'),
    plutil: resolveTool(['/usr/bin/plutil'], 'plutil'),
    git: resolveTool(['/usr/bin/git'], 'git'),
  };
}

function parseLines(output) {
  return output.split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
}

function isArchiveMetadataMember(member) {
  return /^__\.SYMDEF(?: SORTED)?$/u.test(member) || member === '/' || member === '//';
}

function archiveMembers(tools, archivePath, label) {
  const members = parseLines(runTool(tools.ar, ['-t', archivePath], `${label} member inventory`));
  if (members.length === 0) fail(`${label} is an empty archive.`);
  for (const [index, member] of members.entries()) {
    assertString(member, `${label} member[${index}]`);
    if (member.includes('/') || member === '.' || member === '..') {
      fail(`${label} member[${index}] is not a safe archive member name.`);
    }
  }
  const objectMembers = members.filter((member) => !isArchiveMetadataMember(member));
  if (objectMembers.length === 0) fail(`${label} contains no object members.`);
  return { members, objectMembers };
}

function archiveDefinedSymbols(tools, archivePath, label) {
  const output = runTool(tools.nm, ['-gUj', archivePath], `${label} defined-symbol inventory`);
  const symbols = [...new Set(parseLines(output)
    .filter((line) => !line.endsWith(':'))
    .filter((line) => !/\s/u.test(line)))].sort();
  if (symbols.length === 0) fail(`${label} has no externally defined symbols.`);
  return symbols;
}

function architectureList(tools, archivePath, label) {
  const output = runTool(tools.lipo, ['-archs', archivePath], `${label} architecture inspection`).trim();
  const architectures = output.split(/\s+/u).filter(Boolean).map((architecture) => (
    architecture === 'aarch64' ? 'arm64' : architecture
  )).sort();
  if (architectures.length === 0) fail(`${label} reported no architecture.`);
  return architectures;
}

function normalizedTextHash(text, roots, label) {
  if (text.includes('\0') || SECRET_PATTERN.test(text) || PRIVATE_KEY_PATTERN.test(text)) {
    fail(`${label} contains prohibited secret-like or binary material.`);
  }
  let normalized = text.replace(/\r\n/gu, '\n');
  const replacements = [
    [roots.framework, '<FRAMEWORK>'],
    [roots.buildWork, '<BUILD_WORK>'],
    [roots.repo, '<REPO>'],
  ].sort((left, right) => right[0].length - left[0].length);
  for (const [absolute, marker] of replacements) {
    normalized = normalized.split(absolute).join(marker);
  }
  normalized = normalized
    .replace(/\/Applications\/Xcode[^\s"']*\/Contents\/Developer/gu, '<XCODE>')
    .replace(/\/Library\/Developer\/CommandLineTools/gu, '<COMMAND_LINE_TOOLS>')
    .replace(/[ \t]+/gu, ' ')
    .replace(/ *\n */gu, '\n')
    .trim();
  return sha256(normalized);
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&');
}

function collectDependencySourceFiles(contents, roots, label) {
  const candidates = new Set();
  const pattern = new RegExp(`${escapeRegularExpression(roots.buildWork)}/[^\\s\\\\]+`, 'gu');
  for (const match of contents.matchAll(pattern)) {
    const candidate = match[0].replace(/[,:]+$/gu, '');
    if (!SOURCE_SUFFIX_PATTERN.test(candidate)) continue;
    requireRegularFile(candidate, `${label} compiled source`);
    const canonical = realpathSync(candidate);
    const relative = safeRelative(roots.buildWork, canonical, `${label} compiled source path`);
    candidates.add(relative);
  }
  return [...candidates].sort().map((relative) => {
    const filePath = path.join(roots.buildWork, ...relative.split('/'));
    return { path: relative, sizeBytes: statSync(filePath).size, sha256: sha256File(filePath) };
  });
}

function walkSelectedEvidenceFiles(root) {
  const results = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (entry.name === 'LOGS' || entry.name === '.git') continue;
        visit(fullPath);
      } else if (
        entry.isFile()
        && (entry.name === 'compile_commands.json' || /\.(?:d|Po|Plo)$/u.test(entry.name))
      ) {
        results.push(fullPath);
      }
    }
  };
  visit(root);
  return results.sort();
}

function resolveEvidenceSource(buildWork, workingDirectory, fileValue, label) {
  assertString(fileValue, label);
  const candidateUnresolved = path.resolve(workingDirectory, fileValue);
  requireRegularFile(candidateUnresolved, label);
  const candidate = realpathSync(candidateUnresolved);
  const relative = path.relative(buildWork, candidate).split(path.sep).join('/');
  if (relative.startsWith('../') || relative === '..' || path.isAbsolute(relative)) {
    fail(`${label} resolves outside build-work.`);
  }
  assertSafeRelativePath(relative, label);
  return { path: relative, sizeBytes: statSync(candidate).size, sha256: sha256File(candidate) };
}

function collectComponentBuildEvidence(component, buildDirectory, roots) {
  const componentDirectoryName = findExactlyOneDirectory(
    buildDirectory,
    [component.buildPattern],
    `${safeRelative(roots.buildWork, buildDirectory, 'thin build path')} ${component.id} build evidence`
  );
  const componentBuildRoot = path.join(buildDirectory, componentDirectoryName);
  const evidenceFiles = walkSelectedEvidenceFiles(componentBuildRoot);
  const compileRecords = [];
  const dependencyRecords = [];
  const sourceFiles = new Map();

  for (const evidencePath of evidenceFiles) {
    requireRegularFile(evidencePath, 'build evidence file');
    const relativeEvidencePath = safeRelative(roots.buildWork, evidencePath, 'build evidence path');
    const contents = readFileSync(evidencePath, 'utf8');
    if (path.basename(evidencePath) === 'compile_commands.json') {
      let records;
      try {
        records = JSON.parse(contents);
      } catch {
        fail(`Invalid compile_commands JSON at ${relativeEvidencePath}.`);
      }
      if (!Array.isArray(records) || records.length === 0) {
        fail(`compile_commands JSON must be a non-empty array at ${relativeEvidencePath}.`);
      }
      for (const [index, record] of records.entries()) {
        assertObject(record, `${relativeEvidencePath}[${index}]`);
        if (typeof record.directory !== 'string' || typeof record.file !== 'string') {
          fail(`${relativeEvidencePath}[${index}] lacks directory/file.`);
        }
        const command = typeof record.command === 'string'
          ? record.command
          : Array.isArray(record.arguments) ? record.arguments.join('\0') : null;
        if (!command || typeof command !== 'string') {
          fail(`${relativeEvidencePath}[${index}] lacks command or arguments.`);
        }
        const source = resolveEvidenceSource(roots.buildWork, record.directory, record.file, `${relativeEvidencePath}[${index}].file`);
        sourceFiles.set(source.path, source);
        const outputValue = typeof record.output === 'string' ? record.output : '(not-recorded)';
        const normalizedRecord = {
          evidencePath: relativeEvidencePath,
          index,
          source,
          outputSHA256: sha256(outputValue),
          commandSHA256: normalizedTextHash(command, roots, `${relativeEvidencePath}[${index}] command`),
        };
        compileRecords.push(normalizedRecord);
      }
    } else {
      for (const source of collectDependencySourceFiles(contents, roots, relativeEvidencePath)) {
        sourceFiles.set(source.path, source);
      }
      dependencyRecords.push({
        path: relativeEvidencePath,
        sizeBytes: statSync(evidencePath).size,
        normalizedSHA256: normalizedTextHash(contents, roots, relativeEvidencePath),
      });
    }
  }

  compileRecords.sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
  dependencyRecords.sort((left, right) => left.path.localeCompare(right.path));
  const sources = [...sourceFiles.values()].sort((left, right) => left.path.localeCompare(right.path));
  return {
    component: component.id,
    buildPath: safeRelative(roots.buildWork, componentBuildRoot, `${component.id} build path`),
    compileRecords: { count: compileRecords.length, sha256: canonicalHash(compileRecords) },
    dependencyRecords: { count: dependencyRecords.length, sha256: canonicalHash(dependencyRecords) },
    compiledSources: { count: sources.length, sha256: canonicalHash(sources), files: sources },
  };
}

function parseVersion(component, sourceDirectory, sourceDirectoryName) {
  if (component.versionFile) {
    const versionFile = path.join(sourceDirectory, component.versionFile);
    requireRegularFile(versionFile, `${component.id} version file`);
    const match = readFileSync(versionFile, 'utf8').match(component.versionPattern);
    if (!match?.[1]) fail(`Could not parse ${component.id} version from ${component.versionFile}.`);
    return match[1];
  }
  const match = sourceDirectoryName.match(component.sourcePattern);
  if (!match?.[1]) fail(`Could not parse ${component.id} version from source directory name.`);
  return match[1];
}

function directoryDeclaredVersion(component, directoryName, kind) {
  const pattern = kind === 'source' ? component.sourcePattern : component.buildPattern;
  return directoryName.match(pattern)?.[1] ?? null;
}

function loadExceptions(exceptionsPath) {
  if (!exceptionsPath) return [];
  requireRegularFile(exceptionsPath, 'exception policy');
  let policy;
  try {
    policy = JSON.parse(readFileSync(exceptionsPath, 'utf8'));
  } catch {
    fail('Exception policy is not valid JSON.');
  }
  assertExactKeys(policy, ['format', 'exceptions'], 'exception policy');
  if (policy.format !== 1 || !Array.isArray(policy.exceptions)) {
    fail('Exception policy must have format 1 and an exceptions array.');
  }
  const seen = new Set();
  return policy.exceptions.map((exception, index) => {
    assertExactKeys(exception, ['code', 'subject', 'reason'], `exception[${index}]`);
    assertString(exception.code, `exception[${index}].code`);
    assertString(exception.subject, `exception[${index}].subject`);
    assertString(exception.reason, `exception[${index}].reason`);
    if (exception.reason.length < 20) fail(`exception[${index}].reason must be at least 20 characters.`);
    const key = `${exception.code}\0${exception.subject}`;
    if (seen.has(key)) fail(`Duplicate exception ${exception.code}:${exception.subject}.`);
    seen.add(key);
    return { code: exception.code, subject: exception.subject, reason: exception.reason };
  }).sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
}

function createExceptionConsumer(declared) {
  const byKey = new Map(declared.map((exception) => [`${exception.code}\0${exception.subject}`, exception]));
  const used = new Map();
  return {
    require(code, subject) {
      const key = `${code}\0${subject}`;
      const exception = byKey.get(key);
      if (!exception) fail(`Policy finding ${code}:${subject} has no declared exception.`);
      used.set(key, exception);
      return exception;
    },
    finalize() {
      const unused = [...byKey.keys()].filter((key) => !used.has(key));
      if (unused.length > 0) {
        fail(`Exception policy contains unused entries: ${unused.map((key) => key.replace('\0', ':')).join(', ')}.`);
      }
      const usedExceptions = [...used.values()].sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
      return {
        format: 1,
        semantics: 'every finding requires one exact exception and every declared exception must be used',
        declared,
        used: usedExceptions,
        exactTwoSidedMatch: JSON.stringify(declared) === JSON.stringify(usedExceptions),
      };
    },
  };
}

function componentForArchive(archiveName) {
  const matches = COMPONENTS.filter((component) => component.installedArchives.includes(archiveName));
  if (matches.length !== 1) fail(`Installed archive ${archiveName} does not map to exactly one component.`);
  return matches[0];
}

function componentForSourceInput(fileName) {
  return COMPONENTS.filter((component) => (
    component.archivePatterns.some((pattern) => pattern.test(fileName))
  ));
}

function findCompleteThinBuild(buildWork, thinSpec) {
  const matches = listDirectoryNames(buildWork, `${thinSpec.id} thin build`)
    .filter((entry) => entry.isDirectory() && thinSpec.patterns.some((pattern) => pattern.test(entry.name)))
    .filter((entry) => {
      const merged = path.join(buildWork, entry.name, 'INSTALL', 'lib', 'merged.a');
      if (!existsSync(merged)) return false;
      const metadata = lstatSync(merged);
      if (metadata.isSymbolicLink()) fail(`${thinSpec.id} candidate ${entry.name} uses a symlinked merged archive.`);
      return metadata.isFile();
    })
    .map((entry) => entry.name)
    .sort();
  if (matches.length !== 1) {
    fail(`${thinSpec.id} must have exactly one complete thin build; found ${matches.length}: ${matches.join(', ') || '(none)'}.`);
  }
  return matches[0];
}

function inferArchiveOrder(mergedMembers, archives, label) {
  const solutions = [];
  const search = (offset, remaining, order) => {
    if (solutions.length > 1) return;
    if (offset === mergedMembers.length) {
      if (remaining.length === 0) solutions.push([...order]);
      return;
    }
    for (const archive of remaining) {
      const members = archive.objectMembers;
      if (offset + members.length > mergedMembers.length) continue;
      let matches = true;
      for (let index = 0; index < members.length; index += 1) {
        if (mergedMembers[offset + index] !== members[index]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      search(
        offset + members.length,
        remaining.filter((candidate) => candidate.archive !== archive.archive),
        [...order, archive.archive]
      );
    }
  };
  search(0, archives, []);
  if (solutions.length !== 1) {
    fail(`${label} must have exactly one component-archive concatenation; found ${solutions.length}.`);
  }
  return solutions[0];
}

function setDifference(left, right) {
  return [...left].filter((value) => !right.has(value)).sort();
}

function collectThinBuild(thinSpec, buildWork, roots, tools, exceptions) {
  const buildName = findCompleteThinBuild(buildWork, thinSpec);
  const buildDirectory = path.join(buildWork, buildName);
  const installLibraryDirectory = path.join(buildDirectory, 'INSTALL', 'lib');
  requireExistingDirectory(installLibraryDirectory, `${thinSpec.id} installed library directory`);

  const expectedArchiveNames = COMPONENTS.flatMap((component) => component.installedArchives).sort();
  const actualArchiveNames = listDirectoryNames(installLibraryDirectory, `${thinSpec.id} installed library directory`)
    .filter((entry) => entry.isFile() && entry.name.endsWith('.a') && entry.name !== 'merged.a')
    .map((entry) => entry.name)
    .sort();
  if (JSON.stringify(actualArchiveNames) !== JSON.stringify(expectedArchiveNames)) {
    fail(`${thinSpec.id} component archives differ from the exact required set. Expected ${expectedArchiveNames.join(', ')}; found ${actualArchiveNames.join(', ')}.`);
  }

  const componentEvidence = new Map();
  for (const component of COMPONENTS) {
    const evidence = collectComponentBuildEvidence(component, buildDirectory, roots);
    const evidenceCount = evidence.compileRecords.count + evidence.dependencyRecords.count;
    if (evidenceCount === 0 && !component.headerOnly) {
      const subject = `${thinSpec.id}:${component.id}`;
      evidence.exception = exceptions.require('missing-normalized-build-evidence', subject);
    } else {
      evidence.exception = null;
    }
    componentEvidence.set(component.id, evidence);
  }

  const inventories = actualArchiveNames.map((archiveName) => {
    const component = componentForArchive(archiveName);
    const archivePath = path.join(installLibraryDirectory, archiveName);
    const { members, objectMembers } = archiveMembers(tools, archivePath, `${thinSpec.id} ${archiveName}`);
    const symbols = archiveDefinedSymbols(tools, archivePath, `${thinSpec.id} ${archiveName}`);
    return {
      component: component.id,
      archive: archiveName,
      path: safeRelative(buildWork, archivePath, `${thinSpec.id} ${archiveName} path`),
      sizeBytes: statSync(archivePath).size,
      sha256: sha256File(archivePath),
      archiveMemberCount: members.length,
      objectMemberCount: objectMembers.length,
      orderedArchiveMembersSHA256: canonicalHash(members),
      orderedObjectMembersSHA256: canonicalHash(objectMembers),
      definedSymbolCount: symbols.length,
      definedSymbolSetSHA256: canonicalHash(symbols),
      objectMembers,
      members,
      definedSymbols: symbols,
    };
  });

  const mergedPath = path.join(installLibraryDirectory, 'merged.a');
  requireRegularFile(mergedPath, `${thinSpec.id} merged archive`);
  const mergedArchitecture = architectureList(tools, mergedPath, `${thinSpec.id} merged archive`);
  if (JSON.stringify(mergedArchitecture) !== JSON.stringify([thinSpec.architecture])) {
    fail(`${thinSpec.id} merged archive architecture must be ${thinSpec.architecture}; found ${mergedArchitecture.join(', ')}.`);
  }
  const mergedInventory = archiveMembers(tools, mergedPath, `${thinSpec.id} merged archive`);
  const mergedSymbols = archiveDefinedSymbols(tools, mergedPath, `${thinSpec.id} merged archive`);
  const componentArchiveOrder = inferArchiveOrder(
    mergedInventory.objectMembers,
    inventories,
    `${thinSpec.id} merged archive`
  );
  const concatenatedMembers = componentArchiveOrder.flatMap((archiveName) => (
    inventories.find((inventory) => inventory.archive === archiveName).objectMembers
  ));
  if (JSON.stringify(concatenatedMembers) !== JSON.stringify(mergedInventory.objectMembers)) {
    fail(`${thinSpec.id} merged archive ordered object-member multiset does not exactly match its component archives.`);
  }
  const componentSymbols = new Set(inventories.flatMap((inventory) => inventory.definedSymbols));
  const mergedSymbolSet = new Set(mergedSymbols);
  const symbolsMissingFromMerged = setDifference(componentSymbols, mergedSymbolSet);
  const symbolsMissingFromComponents = setDifference(mergedSymbolSet, componentSymbols);
  if (symbolsMissingFromMerged.length > 0 || symbolsMissingFromComponents.length > 0) {
    fail(`${thinSpec.id} merged archive symbol set differs from its component archives.`);
  }

  const staleHashes = [sha256File(mergedPath), ...inventories.map((inventory) => inventory.sha256)]
    .filter((digest) => STALE_UPSTREAM_SHA256_DENY_LIST.includes(digest));
  if (staleHashes.length > 0) {
    fail(`${thinSpec.id} contains stale upstream denied SHA-256 ${staleHashes.join(', ')}.`);
  }

  return {
    id: thinSpec.id,
    platform: thinSpec.platform,
    architecture: thinSpec.architecture,
    buildPath: safeRelative(buildWork, buildDirectory, `${thinSpec.id} build path`),
    componentEvidence: [...componentEvidence.values()].sort((left, right) => left.component.localeCompare(right.component)),
    componentArchives: inventories.map(({ members, objectMembers, definedSymbols, ...portable }) => portable),
    internal: {
      inventories,
      mergedMembers: mergedInventory.members,
      mergedObjectMembers: mergedInventory.objectMembers,
    },
    mergedArchive: {
      path: safeRelative(buildWork, mergedPath, `${thinSpec.id} merged archive path`),
      sizeBytes: statSync(mergedPath).size,
      sha256: sha256File(mergedPath),
      archiveMemberCount: mergedInventory.members.length,
      objectMemberCount: mergedInventory.objectMembers.length,
      orderedArchiveMembersSHA256: canonicalHash(mergedInventory.members),
      orderedObjectMembersSHA256: canonicalHash(mergedInventory.objectMembers),
      definedSymbolCount: mergedSymbols.length,
      definedSymbolSetSHA256: canonicalHash(mergedSymbols),
      relinkProof: {
        method: 'exact-ordered-object-member-multiset-and-defined-symbol-set',
        componentArchiveOrder,
        exactOrderedObjectMemberMultiset: true,
        componentDefinedSymbolSetSHA256: canonicalHash([...componentSymbols].sort()),
        mergedDefinedSymbolSetSHA256: canonicalHash(mergedSymbols),
        exactDefinedSymbolSet: true,
      },
    },
  };
}

function sourceInputInventory(buildWork, exceptions) {
  const archiveRoot = path.join(buildWork, 'ARCHIVE');
  requireExistingDirectory(archiveRoot, 'source archive directory');
  return listDirectoryNames(archiveRoot, 'source archive directory')
    .filter((entry) => !entry.name.startsWith('.'))
    .map((entry) => {
      if (!entry.isFile()) fail(`Source input ARCHIVE/${entry.name} must be a regular file.`);
      const matches = componentForSourceInput(entry.name);
      let component = null;
      let exception = null;
      if (matches.length !== 1) {
        const subject = `ARCHIVE/${entry.name}`;
        exception = exceptions.require('unmapped-source-input', subject);
      } else {
        component = matches[0].id;
      }
      const filePath = path.join(archiveRoot, entry.name);
      const digest = sha256File(filePath);
      if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(digest)) {
        fail(`Source input ARCHIVE/${entry.name} matches stale upstream denied SHA-256 ${digest}.`);
      }
      return {
        component,
        scope: entry.name.startsWith('zim-testing-suite-') ? 'build-test-only' : 'linked-source-or-patch',
        path: safeRelative(buildWork, filePath, 'source input path'),
        sizeBytes: statSync(filePath).size,
        sha256: digest,
        exception,
      };
    })
    .sort((left, right) => left.path.localeCompare(right.path));
}

function gitIdentity(tools, sourceDirectory, component) {
  const commit = runTool(tools.git, ['-C', sourceDirectory, 'rev-parse', 'HEAD'], `${component.id} Git commit`).trim();
  const tree = runTool(tools.git, ['-C', sourceDirectory, 'rev-parse', 'HEAD^{tree}'], `${component.id} Git tree`).trim();
  const trackedStatus = runTool(
    tools.git,
    ['-C', sourceDirectory, 'status', '--porcelain=v1', '--untracked-files=no'],
    `${component.id} tracked Git status`
  ).trim();
  if (!GIT_SHA_PATTERN.test(commit) || !GIT_SHA_PATTERN.test(tree)) {
    fail(`${component.id} Git identity is malformed.`);
  }
  if (trackedStatus !== '') fail(`${component.id} source contains tracked modifications.`);
  return { commit, tree, trackedWorktreeClean: true };
}

function collectSourceLock(buildWork, thinBuilds, tools, exceptions) {
  const sourceRoot = path.join(buildWork, 'SOURCE');
  requireExistingDirectory(sourceRoot, 'source directory');
  const sourceInputs = sourceInputInventory(buildWork, exceptions);
  const components = COMPONENTS.map((component) => {
    const sourceDirectoryName = findExactlyOneDirectory(sourceRoot, [component.sourcePattern], `${component.id} source`);
    const sourceDirectory = path.join(sourceRoot, sourceDirectoryName);
    const version = parseVersion(component, sourceDirectory, sourceDirectoryName);
    const sourceDirectoryVersion = directoryDeclaredVersion(component, sourceDirectoryName, 'source');
    let versionException = null;
    if (sourceDirectoryVersion !== null && sourceDirectoryVersion !== version) {
      versionException = exceptions.require(
        'source-directory-version-mismatch',
        `${component.id}:SOURCE/${sourceDirectoryName}:${version}`
      );
    }

    const buildDirectoryVersions = [...new Set(thinBuilds.map((thinBuild) => {
      const evidence = thinBuild.componentEvidence.find((candidate) => candidate.component === component.id);
      const buildDirectoryName = evidence.buildPath.split('/').at(-1);
      return directoryDeclaredVersion(component, buildDirectoryName, 'build');
    }).filter((candidate) => candidate !== null))].sort();
    let buildVersionException = null;
    if (buildDirectoryVersions.some((candidate) => candidate !== version)) {
      buildVersionException = exceptions.require(
        'build-directory-version-mismatch',
        `${component.id}:${buildDirectoryVersions.join(',')}:${version}`
      );
    }

    const licenses = component.licensePaths.map((licensePath) => {
      assertSafeRelativePath(licensePath, `${component.id} license path`);
      const licenseFile = path.join(sourceDirectory, ...licensePath.split('/'));
      return fileSpec(buildWork, licenseFile, `${component.id} license ${licensePath}`);
    });
    const componentInputs = sourceInputs.filter((sourceInput) => sourceInput.component === component.id);
    if (!component.gitSource && componentInputs.length === 0) {
      fail(`${component.id} has no exact source archive input.`);
    }

    const compiledSources = new Map();
    const generatorEvidence = [];
    for (const thinBuild of thinBuilds) {
      const evidence = thinBuild.componentEvidence.find((candidate) => candidate.component === component.id);
      for (const file of evidence.compiledSources.files) compiledSources.set(file.path, file);
      generatorEvidence.push({
        thinBuild: thinBuild.id,
        compileRecords: evidence.compileRecords,
        dependencyRecords: evidence.dependencyRecords,
        compiledSources: {
          count: evidence.compiledSources.count,
          sha256: evidence.compiledSources.sha256,
        },
        exception: evidence.exception,
      });
    }
    const compiledSourceFiles = [...compiledSources.values()].sort((left, right) => left.path.localeCompare(right.path));
    const git = component.gitSource ? gitIdentity(tools, sourceDirectory, component) : null;
    const sourceIdentity = {
      sourceInputs: componentInputs.map(({ exception, ...input }) => input),
      git,
      compiledSourceFileCount: compiledSourceFiles.length,
      compiledSourceSetSHA256: canonicalHash(compiledSourceFiles),
      compiledSourceFiles,
      licenseSetSHA256: canonicalHash(licenses),
    };
    return {
      id: component.id,
      name: component.name,
      version,
      sourcePath: `SOURCE/${sourceDirectoryName}`,
      sourceDirectoryVersion,
      buildDirectoryVersions,
      versionExceptions: [versionException, buildVersionException].filter(Boolean),
      licenseDeclared: component.licenseDeclared,
      licenseConcluded: component.licenseConcluded,
      headerOnly: Boolean(component.headerOnly),
      installedArchives: component.installedArchives,
      sourceIdentity,
      sourceIdentitySHA256: canonicalHash(sourceIdentity),
      generatorEvidence,
      generatorEvidenceSHA256: canonicalHash(generatorEvidence),
      licenses,
    };
  });
  const linkedComponentIds = components.map((component) => component.id).sort();
  return {
    format: EVIDENCE_FORMAT,
    policy: EVIDENCE_POLICY,
    componentSet: linkedComponentIds,
    componentSetSHA256: canonicalHash(linkedComponentIds),
    sourceInputs,
    components,
  };
}

function parseFrameworkInfo(tools, infoPlistPath) {
  let info;
  try {
    info = JSON.parse(runTool(tools.plutil, ['-convert', 'json', '-o', '-', infoPlistPath], 'XCFramework Info.plist conversion'));
  } catch (error) {
    if (error instanceof CoreKiwixEvidenceError) throw error;
    fail('XCFramework Info.plist is not valid.');
  }
  if (info.CFBundlePackageType !== 'XFWK' || info.XCFrameworkFormatVersion !== '1.0') {
    fail('XCFramework Info.plist identity is not XFWK format 1.0.');
  }
  if (!Array.isArray(info.AvailableLibraries) || info.AvailableLibraries.length !== 3) {
    fail('XCFramework must declare exactly three libraries.');
  }
  return info;
}

function treeIdentity(root, label) {
  const files = [];
  const visit = (directory) => {
    for (const entry of listDirectoryNames(directory, label).sort((left, right) => left.name.localeCompare(right.name))) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(fullPath);
      else if (entry.isFile()) files.push(fileSpec(root, fullPath, label));
      else fail(`${label} contains unsupported filesystem entry ${entry.name}.`);
    }
  };
  visit(root);
  if (files.length === 0) fail(`${label} contains no files.`);
  return { fileCount: files.length, sha256: canonicalHash(files) };
}

function collectFramework(frameworkRoot, buildWork, thinBuilds, tools) {
  const infoPlistPath = path.join(frameworkRoot, 'Info.plist');
  requireRegularFile(infoPlistPath, 'XCFramework Info.plist');
  const info = parseFrameworkInfo(tools, infoPlistPath);
  const available = [...info.AvailableLibraries].sort((left, right) => (
    String(left.LibraryIdentifier).localeCompare(String(right.LibraryIdentifier))
  ));
  const expectedSorted = [...EXPECTED_FRAMEWORK_SLICES].sort((left, right) => left.identifier.localeCompare(right.identifier));
  const slices = available.map((library, index) => {
    const expected = expectedSorted[index];
    const variant = library.SupportedPlatformVariant ?? null;
    const architectures = [...(library.SupportedArchitectures ?? [])].map((value) => (
      value === 'aarch64' ? 'arm64' : value
    )).sort();
    if (
      library.LibraryIdentifier !== expected.identifier
      || library.LibraryPath !== 'merged.a'
      || library.BinaryPath !== 'merged.a'
      || library.HeadersPath !== 'Headers'
      || library.SupportedPlatform !== expected.platform
      || variant !== expected.variant
      || JSON.stringify(architectures) !== JSON.stringify(expected.architectures)
    ) {
      fail(`XCFramework slice ${library.LibraryIdentifier ?? '(missing)'} does not match the required ${expected.identifier} declaration.`);
    }
    const sliceDirectory = path.join(frameworkRoot, expected.identifier);
    requireExistingDirectory(sliceDirectory, `${expected.identifier} slice`);
    const binaryPath = path.join(sliceDirectory, 'merged.a');
    requireRegularFile(binaryPath, `${expected.identifier} binary`);
    const actualArchitectures = architectureList(tools, binaryPath, `${expected.identifier} binary`);
    if (JSON.stringify(actualArchitectures) !== JSON.stringify(expected.architectures)) {
      fail(`${expected.identifier} binary architectures differ from Info.plist.`);
    }
    const digest = sha256File(binaryPath);
    if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(digest)) {
      fail(`${expected.identifier} binary matches stale upstream denied SHA-256 ${digest}.`);
    }
    return {
      identifier: expected.identifier,
      platform: expected.platform,
      variant: expected.variant,
      architectures,
      binary: {
        path: `${expected.identifier}/merged.a`,
        sizeBytes: statSync(binaryPath).size,
        sha256: digest,
      },
      sliceTree: treeIdentity(sliceDirectory, `${expected.identifier} slice`),
    };
  });
  const deviceSlice = slices.find((slice) => slice.identifier === 'ios-arm64');
  const deviceThin = thinBuilds.find((thinBuild) => thinBuild.id === 'ios-device-arm64');
  if (deviceSlice.binary.sha256 !== deviceThin.mergedArchive.sha256) {
    fail('Distributed ios-arm64 slice is not byte-identical to the controlled iOS device thin archive.');
  }
  return {
    packageType: 'XFWK',
    formatVersion: '1.0',
    infoPlist: {
      path: 'Info.plist',
      sizeBytes: statSync(infoPlistPath).size,
      sha256: sha256File(infoPlistPath),
    },
    tree: treeIdentity(frameworkRoot, 'XCFramework'),
    slices,
    controlledDeviceThinArchiveSHA256: deviceThin.mergedArchive.sha256,
    distributedDeviceSliceExactArchiveIdentity: true,
  };
}

function sourceCandidatesForArchiveMember(component, member) {
  const memberCore = member.replace(/\.ao$/u, '').replace(/\.o$/u, '');
  const scored = component.sourceIdentity.compiledSourceFiles.map((source) => {
    const base = path.posix.basename(source.path);
    const stem = base.replace(SOURCE_SUFFIX_PATTERN, '');
    let score = 0;
    if (memberCore === base) score = 4;
    else if (memberCore.endsWith(`_${base}`)) score = 3;
    else if (memberCore === stem) score = 2;
    else if (memberCore.endsWith(`_${stem}`)) score = 1;
    return { source, score };
  }).filter((candidate) => candidate.score > 0);
  if (scored.length === 0) return [];
  const bestScore = Math.max(...scored.map((candidate) => candidate.score));
  return scored
    .filter((candidate) => candidate.score === bestScore)
    .map((candidate) => candidate.source)
    .sort((left, right) => left.path.localeCompare(right.path));
}

function createObjectMap(sourceLock, thinBuilds, framework, exceptions) {
  const deviceThin = thinBuilds.find((thinBuild) => thinBuild.id === 'ios-device-arm64');
  const archiveByName = new Map(deviceThin.internal.inventories.map((archive) => [archive.archive, archive]));
  const componentById = new Map(sourceLock.components.map((component) => [component.id, component]));
  const records = [];
  let mergedOrdinal = 0;
  for (const archiveName of deviceThin.mergedArchive.relinkProof.componentArchiveOrder) {
    const archive = archiveByName.get(archiveName);
    const component = componentById.get(archive.component);
    archive.objectMembers.forEach((member, componentArchiveOrdinal) => {
      const sourceFiles = sourceCandidatesForArchiveMember(component, member);
      const mappingException = sourceFiles.length === 0
        ? exceptions.require(
          'generated-object-without-direct-source',
          `${deviceThin.id}:${archiveName}:${componentArchiveOrdinal}:${member}`
        )
        : null;
      records.push({
        format: EVIDENCE_FORMAT,
        distributedSlice: 'ios-arm64',
        thinBuild: deviceThin.id,
        mergedArchiveSHA256: deviceThin.mergedArchive.sha256,
        mergedObjectOrdinal: mergedOrdinal,
        member,
        component: component.id,
        componentArchive: archiveName,
        componentArchiveSHA256: archive.sha256,
        componentArchiveOrdinal,
        sourceIdentitySHA256: component.sourceIdentitySHA256,
        generatorEvidenceSHA256: component.generatorEvidenceSHA256,
        sourceMapping: sourceFiles.length > 0
          ? 'compiled-source-and-normalized-generator-evidence'
          : 'excepted-normalized-generator-evidence',
        mappingException,
        sourceFiles,
        sourceFileSetSHA256: canonicalHash(sourceFiles),
      });
      mergedOrdinal += 1;
    });
  }
  if (mergedOrdinal !== deviceThin.internal.mergedObjectMembers.length) {
    fail('Distributed iOS object map does not cover every merged object member.');
  }
  for (let index = 0; index < records.length; index += 1) {
    if (
      records[index].mergedObjectOrdinal !== index
      || records[index].member !== deviceThin.internal.mergedObjectMembers[index]
    ) {
      fail(`Distributed iOS object map diverges at merged object ordinal ${index}.`);
    }
  }
  if (!framework.distributedDeviceSliceExactArchiveIdentity) {
    fail('Object map cannot cover a non-identical distributed iOS device slice.');
  }
  return records;
}

function createSPDX(sourceLock) {
  const namespaceIdentity = canonicalHash(sourceLock.components.map((component) => ({
    id: component.id,
    version: component.version,
    sourceIdentitySHA256: component.sourceIdentitySHA256,
  })));
  const packages = sourceLock.components.map((component) => {
    const definition = COMPONENTS.find((candidate) => candidate.id === component.id);
    return {
      SPDXID: `SPDXRef-Package-${component.id}`,
      name: component.name,
      versionInfo: component.version,
      downloadLocation: 'NOASSERTION',
      filesAnalyzed: false,
      checksums: [{ algorithm: 'SHA256', checksumValue: component.sourceIdentitySHA256 }],
      licenseConcluded: component.licenseConcluded,
      licenseDeclared: component.licenseDeclared,
      copyrightText: 'NOASSERTION',
      externalRefs: [{
        referenceCategory: 'PACKAGE-MANAGER',
        referenceType: 'purl',
        referenceLocator: `pkg:generic/${definition.purlName}@${encodeURIComponent(component.version)}`,
      }],
    };
  });
  return {
    spdxVersion: 'SPDX-2.3',
    dataLicense: 'CC0-1.0',
    SPDXID: 'SPDXRef-DOCUMENT',
    name: 'CoreKiwix controlled native dependency SBOM',
    documentNamespace: `https://thearkfile.com/spdx/corekiwix/${namespaceIdentity}`,
    creationInfo: {
      created: '1970-01-01T00:00:00Z',
      creators: ['Tool: arkfile-corekiwix-evidence-v1'],
      comment: 'Deterministic timestamp; artifact identity is carried by SHA-256 checksums.',
    },
    hasExtractedLicensingInfos: [{
      licenseId: 'LicenseRef-XZ-Utils-Public-Domain',
      extractedText: 'The exact upstream XZ Utils licensing statement is retained and SHA-256 locked as the XZ component COPYING file in CoreKiwixNativeSource.lock.json.',
      name: 'XZ Utils public-domain and permissive file licensing statement',
      comment: 'A LicenseRef is used instead of substituting a broader standard identifier.',
    }],
    documentDescribes: packages.map((item) => item.SPDXID),
    packages,
  };
}

function portableThinBuild(thinBuild) {
  return {
    id: thinBuild.id,
    platform: thinBuild.platform,
    architecture: thinBuild.architecture,
    buildPath: thinBuild.buildPath,
    componentEvidence: thinBuild.componentEvidence.map((evidence) => ({
      component: evidence.component,
      buildPath: evidence.buildPath,
      compileRecords: evidence.compileRecords,
      dependencyRecords: evidence.dependencyRecords,
      compiledSources: {
        count: evidence.compiledSources.count,
        sha256: evidence.compiledSources.sha256,
      },
      exception: evidence.exception,
    })),
    componentArchives: thinBuild.componentArchives,
    mergedArchive: thinBuild.mergedArchive,
  };
}

function outputDescriptor(fileName, contents, extra = {}) {
  return {
    path: fileName,
    sizeBytes: Buffer.byteLength(contents),
    sha256: sha256(contents),
    ...extra,
  };
}

function collectLicenseManifest(sourceLock) {
  return sourceLock.components.flatMap((component) => component.licenses.map((license) => ({
    component: component.id,
    ...license,
  }))).sort((left, right) => (
    `${left.component}\0${left.path}`.localeCompare(`${right.component}\0${right.path}`)
  ));
}

function buildEvidenceBundle(options) {
  const repo = requireExistingDirectory(path.resolve(options.repo), 'repository');
  const buildWork = requireExistingDirectory(path.resolve(options.buildWork), 'build-work');
  const framework = requireExistingDirectory(path.resolve(options.framework), 'XCFramework');
  const output = path.resolve(options.output);
  if ([repo, buildWork, framework].includes(output)) {
    fail('Output directory must be distinct from repository, build-work, and XCFramework roots.');
  }
  const scriptPath = path.join(repo, ...SCRIPT_RELATIVE_PATH.split('/'));
  requireRegularFile(scriptPath, 'CoreKiwix evidence tool');
  const roots = { repo, buildWork, framework };
  const tools = approvedTools();
  const declaredExceptions = loadExceptions(options.exceptions ? path.resolve(options.exceptions) : null);
  const exceptions = createExceptionConsumer(declaredExceptions);

  const thinBuilds = THIN_BUILDS.map((thinSpec) => (
    collectThinBuild(thinSpec, buildWork, roots, tools, exceptions)
  ));
  const sourceLock = collectSourceLock(buildWork, thinBuilds, tools, exceptions);
  const frameworkEvidence = collectFramework(framework, buildWork, thinBuilds, tools);
  const objectRecords = createObjectMap(sourceLock, thinBuilds, frameworkEvidence, exceptions);
  const exceptionSemantics = exceptions.finalize();
  const sbom = createSPDX(sourceLock);

  const sourceLockContents = canonicalJSON(sourceLock);
  const sbomContents = canonicalJSON(sbom);
  const objectMapContents = `${objectRecords.map((record) => JSON.stringify(record)).join('\n')}\n`;
  const portableThinBuilds = thinBuilds.map(portableThinBuild);
  const deviceThinInternal = thinBuilds.find((thin) => thin.id === 'ios-device-arm64');
  const deviceThinPortable = portableThinBuilds.find((thin) => thin.id === 'ios-device-arm64');
  const archiveMetadataMembers = deviceThinInternal.internal.mergedMembers.filter(isArchiveMetadataMember);
  const distributedIOSCoverage = {
    sliceIdentifier: 'ios-arm64',
    thinBuild: 'ios-device-arm64',
    exactArchiveIdentity: frameworkEvidence.distributedDeviceSliceExactArchiveIdentity,
    mergedArchiveSHA256: deviceThinPortable.mergedArchive.sha256,
    mergedArchiveMemberCount: deviceThinPortable.mergedArchive.archiveMemberCount,
    mergedObjectMemberCount: deviceThinPortable.mergedArchive.objectMemberCount,
    mappedObjectMemberCount: objectRecords.length,
    archiveMetadataMemberCount: archiveMetadataMembers.length,
    archiveMetadataMembersSHA256: canonicalHash(archiveMetadataMembers),
    orderedObjectMapSHA256: canonicalHash(objectRecords),
    fullObjectCoverage: objectRecords.length === deviceThinPortable.mergedArchive.objectMemberCount,
    fullArchiveMemberCoverage: (
      objectRecords.length + archiveMetadataMembers.length === deviceThinPortable.mergedArchive.archiveMemberCount
    ),
  };
  if (!distributedIOSCoverage.fullObjectCoverage || !distributedIOSCoverage.fullArchiveMemberCoverage) {
    fail('Distributed iOS archive-member coverage is incomplete.');
  }

  const manifest = {
    format: EVIDENCE_FORMAT,
    policy: EVIDENCE_POLICY,
    product: {
      name: 'CoreKiwix',
      buildIdentity: `${sourceLock.components.find((component) => component.id === 'libkiwix').version}+arkfile.1`,
    },
    generator: {
      path: SCRIPT_RELATIVE_PATH,
      sizeBytes: statSync(scriptPath).size,
      sha256: sha256File(scriptPath),
    },
    staleUpstreamSHA256DenyList: [...STALE_UPSTREAM_SHA256_DENY_LIST],
    componentSet: sourceLock.componentSet,
    componentSetSHA256: sourceLock.componentSetSHA256,
    exceptionSemantics,
    outputs: {
      sourceLock: outputDescriptor(OUTPUT_FILES.sourceLock, sourceLockContents),
      sbom: outputDescriptor(OUTPUT_FILES.sbom, sbomContents),
      objectMap: outputDescriptor(OUTPUT_FILES.objectMap, objectMapContents, { lineCount: objectRecords.length }),
    },
    licenses: collectLicenseManifest(sourceLock),
    thinBuilds: portableThinBuilds,
    xcframework: frameworkEvidence,
    distributedIOSCoverage,
  };
  const manifestContents = canonicalJSON(manifest);
  const files = {
    [OUTPUT_FILES.manifest]: manifestContents,
    [OUTPUT_FILES.sourceLock]: sourceLockContents,
    [OUTPUT_FILES.sbom]: sbomContents,
    [OUTPUT_FILES.objectMap]: objectMapContents,
  };
  validateEvidenceArtifacts(files);
  return { files, manifest, sourceLock, sbom, objectRecords, output };
}

function assertFileDescriptor(value, label, expectedPath, withLineCount = false) {
  const keys = ['path', 'sizeBytes', 'sha256', ...(withLineCount ? ['lineCount'] : [])];
  assertExactKeys(value, keys, label);
  if (value.path !== expectedPath) fail(`${label}.path must be ${expectedPath}.`);
  assertSafeRelativePath(value.path, `${label}.path`);
  assertInteger(value.sizeBytes, `${label}.sizeBytes`);
  assertDigest(value.sha256, `${label}.sha256`);
  if (withLineCount) assertInteger(value.lineCount, `${label}.lineCount`);
}

function parseJSONStrict(contents, label) {
  let parsed;
  try {
    parsed = JSON.parse(contents);
  } catch {
    fail(`${label} is not valid JSON.`);
  }
  if (canonicalJSON(parsed) !== contents) fail(`${label} is not canonical pretty-printed JSON.`);
  return parsed;
}

function validateExceptionSemantics(value) {
  assertExactKeys(
    value,
    ['format', 'semantics', 'declared', 'used', 'exactTwoSidedMatch'],
    'manifest.exceptionSemantics'
  );
  if (value.format !== 1 || value.exactTwoSidedMatch !== true) {
    fail('Exception semantics must be format 1 with an exact two-sided match.');
  }
  if (JSON.stringify(value.declared) !== JSON.stringify(value.used)) {
    fail('Declared and used exceptions must be exactly equal.');
  }
  if (!Array.isArray(value.declared)) fail('Declared exceptions must be an array.');
  for (const [index, exception] of value.declared.entries()) {
    assertExactKeys(exception, ['code', 'subject', 'reason'], `declared exception[${index}]`);
  }
}

function validateSourceLock(sourceLock) {
  assertExactKeys(
    sourceLock,
    ['format', 'policy', 'componentSet', 'componentSetSHA256', 'sourceInputs', 'components'],
    'source lock'
  );
  if (sourceLock.format !== EVIDENCE_FORMAT || sourceLock.policy !== EVIDENCE_POLICY) {
    fail('Source lock format/policy is unsupported.');
  }
  const requiredIds = COMPONENTS.map((component) => component.id).sort();
  if (JSON.stringify(sourceLock.componentSet) !== JSON.stringify(requiredIds)) {
    fail('Source lock component set differs from the exact linked component set.');
  }
  if (sourceLock.componentSetSHA256 !== canonicalHash(requiredIds)) {
    fail('Source lock component-set digest is invalid.');
  }
  if (!Array.isArray(sourceLock.components) || sourceLock.components.length !== COMPONENTS.length) {
    fail(`Source lock must contain exactly ${COMPONENTS.length} components.`);
  }
  if (!Array.isArray(sourceLock.sourceInputs) || sourceLock.sourceInputs.length === 0) {
    fail('Source lock must retain exact archive/patch inputs.');
  }
  const sourceInputPaths = new Set();
  for (const [index, sourceInput] of sourceLock.sourceInputs.entries()) {
    assertExactKeys(
      sourceInput,
      ['component', 'scope', 'path', 'sizeBytes', 'sha256', 'exception'],
      `sourceInputs[${index}]`
    );
    assertSafeRelativePath(sourceInput.path, `sourceInputs[${index}].path`);
    if (!sourceInput.path.startsWith('ARCHIVE/')) fail(`sourceInputs[${index}] must be under ARCHIVE/.`);
    if (sourceInputPaths.has(sourceInput.path)) fail(`Duplicate source input ${sourceInput.path}.`);
    sourceInputPaths.add(sourceInput.path);
    assertInteger(sourceInput.sizeBytes, `sourceInputs[${index}].sizeBytes`);
    assertDigest(sourceInput.sha256, `sourceInputs[${index}].sha256`);
    if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(sourceInput.sha256)) {
      fail(`Source input ${sourceInput.path} uses a stale upstream denied hash.`);
    }
    if (sourceInput.component !== null && !requiredIds.includes(sourceInput.component)) {
      fail(`Source input ${sourceInput.path} names an unknown component.`);
    }
  }
  const ids = sourceLock.components.map((component) => component.id).sort();
  if (JSON.stringify(ids) !== JSON.stringify(requiredIds)) fail('Source lock components contain duplicates or omissions.');
  for (const component of sourceLock.components) {
    assertExactKeys(component, [
      'id', 'name', 'version', 'sourcePath', 'sourceDirectoryVersion', 'buildDirectoryVersions',
      'versionExceptions', 'licenseDeclared', 'licenseConcluded', 'headerOnly', 'installedArchives', 'sourceIdentity',
      'sourceIdentitySHA256', 'generatorEvidence', 'generatorEvidenceSHA256', 'licenses',
    ], `source lock component ${component.id}`);
    assertSafeRelativePath(component.sourcePath, `${component.id}.sourcePath`);
    assertDigest(component.sourceIdentitySHA256, `${component.id}.sourceIdentitySHA256`);
    assertDigest(component.generatorEvidenceSHA256, `${component.id}.generatorEvidenceSHA256`);
    if (component.sourceIdentitySHA256 !== canonicalHash(component.sourceIdentity)) {
      fail(`${component.id} source identity digest is invalid.`);
    }
    if (component.generatorEvidenceSHA256 !== canonicalHash(component.generatorEvidence)) {
      fail(`${component.id} generator evidence digest is invalid.`);
    }
    assertString(component.version, `${component.id}.version`);
    assertString(component.licenseDeclared, `${component.id}.licenseDeclared`);
    assertString(component.licenseConcluded, `${component.id}.licenseConcluded`);
    if (!Array.isArray(component.buildDirectoryVersions) || component.buildDirectoryVersions.length > 1) {
      fail(`${component.id}.buildDirectoryVersions must contain at most one exact version label.`);
    }
    if (!Array.isArray(component.versionExceptions)) fail(`${component.id}.versionExceptions must be an array.`);
    const definition = COMPONENTS.find((candidate) => candidate.id === component.id);
    if (
      component.name !== definition.name
      || component.licenseDeclared !== definition.licenseDeclared
      || component.licenseConcluded !== definition.licenseConcluded
      || component.headerOnly !== Boolean(definition.headerOnly)
      || JSON.stringify(component.installedArchives) !== JSON.stringify(definition.installedArchives)
    ) {
      fail(`${component.id} identity/license/archive policy differs from the exact component definition.`);
    }
    assertExactKeys(component.sourceIdentity, [
      'sourceInputs', 'git', 'compiledSourceFileCount', 'compiledSourceSetSHA256',
      'compiledSourceFiles', 'licenseSetSHA256',
    ], `${component.id}.sourceIdentity`);
    assertInteger(component.sourceIdentity.compiledSourceFileCount, `${component.id}.compiledSourceFileCount`);
    assertDigest(component.sourceIdentity.compiledSourceSetSHA256, `${component.id}.compiledSourceSetSHA256`);
    assertDigest(component.sourceIdentity.licenseSetSHA256, `${component.id}.licenseSetSHA256`);
    if (!Array.isArray(component.sourceIdentity.compiledSourceFiles)) {
      fail(`${component.id}.compiledSourceFiles must be an array.`);
    }
    if (
      component.sourceIdentity.compiledSourceFileCount !== component.sourceIdentity.compiledSourceFiles.length
      || component.sourceIdentity.compiledSourceSetSHA256 !== canonicalHash(component.sourceIdentity.compiledSourceFiles)
    ) {
      fail(`${component.id} compiled-source count/digest is invalid.`);
    }
    for (const [index, source] of component.sourceIdentity.compiledSourceFiles.entries()) {
      assertFileDescriptor(source, `${component.id}.compiledSourceFiles[${index}]`, source.path);
    }
    if (component.sourceIdentity.licenseSetSHA256 !== canonicalHash(component.licenses)) {
      fail(`${component.id} license-set digest is invalid.`);
    }
    if (definition.gitSource) {
      assertExactKeys(component.sourceIdentity.git, ['commit', 'tree', 'trackedWorktreeClean'], `${component.id}.git`);
      if (
        !GIT_SHA_PATTERN.test(component.sourceIdentity.git.commit)
        || !GIT_SHA_PATTERN.test(component.sourceIdentity.git.tree)
        || component.sourceIdentity.git.trackedWorktreeClean !== true
      ) {
        fail(`${component.id} Git identity is invalid.`);
      }
    } else if (component.sourceIdentity.git !== null) {
      fail(`${component.id} must not claim a Git identity.`);
    }
    if (!Array.isArray(component.generatorEvidence) || component.generatorEvidence.length !== 5) {
      fail(`${component.id} must carry normalized generator evidence for exactly five thin builds.`);
    }
    for (const evidence of component.generatorEvidence) {
      assertExactKeys(evidence, [
        'thinBuild', 'compileRecords', 'dependencyRecords', 'compiledSources', 'exception',
      ], `${component.id}.generatorEvidence`);
      assertCountHash(evidence.compileRecords, `${component.id}.${evidence.thinBuild}.compileRecords`);
      assertCountHash(evidence.dependencyRecords, `${component.id}.${evidence.thinBuild}.dependencyRecords`);
      assertCountHash(evidence.compiledSources, `${component.id}.${evidence.thinBuild}.compiledSources`);
    }
    if (!Array.isArray(component.licenses) || component.licenses.length === 0) {
      fail(`${component.id} must retain at least one license file hash.`);
    }
    for (const [index, license] of component.licenses.entries()) {
      assertFileDescriptor(license, `${component.id}.licenses[${index}]`, license.path);
    }
  }
  assertPortableValue(sourceLock, 'source lock');
}

function validateSPDX(sbom, sourceLock) {
  assertExactKeys(sbom, [
    'spdxVersion', 'dataLicense', 'SPDXID', 'name', 'documentNamespace',
    'creationInfo', 'hasExtractedLicensingInfos', 'documentDescribes', 'packages',
  ], 'SPDX document');
  if (sbom.spdxVersion !== 'SPDX-2.3' || sbom.dataLicense !== 'CC0-1.0') {
    fail('SPDX document must use SPDX-2.3 and CC0-1.0.');
  }
  if (
    !Array.isArray(sbom.hasExtractedLicensingInfos)
    || sbom.hasExtractedLicensingInfos.length !== 1
    || sbom.hasExtractedLicensingInfos[0].licenseId !== 'LicenseRef-XZ-Utils-Public-Domain'
  ) {
    fail('SPDX document must retain the exact XZ Utils LicenseRef definition.');
  }
  if (!Array.isArray(sbom.packages) || sbom.packages.length !== COMPONENTS.length) {
    fail(`SPDX document must describe exactly ${COMPONENTS.length} linked components.`);
  }
  const expectedPackages = new Map(sourceLock.components.map((component) => [
    `SPDXRef-Package-${component.id}`,
    component,
  ]));
  const actualIds = sbom.packages.map((pkg) => pkg.SPDXID).sort();
  const expectedIds = [...expectedPackages.keys()].sort();
  if (JSON.stringify(actualIds) !== JSON.stringify(expectedIds)) fail('SPDX package set is incomplete or duplicated.');
  if (JSON.stringify([...sbom.documentDescribes].sort()) !== JSON.stringify(expectedIds)) {
    fail('SPDX documentDescribes must cover the exact package set.');
  }
  for (const pkg of sbom.packages) {
    assertExactKeys(pkg, [
      'SPDXID', 'name', 'versionInfo', 'downloadLocation', 'filesAnalyzed', 'checksums',
      'licenseConcluded', 'licenseDeclared', 'copyrightText', 'externalRefs',
    ], `SPDX package ${pkg.SPDXID}`);
    const component = expectedPackages.get(pkg.SPDXID);
    if (
      pkg.versionInfo !== component.version
      || pkg.licenseDeclared !== component.licenseDeclared
      || pkg.licenseConcluded !== component.licenseConcluded
      || pkg.filesAnalyzed !== false
      || pkg.checksums?.length !== 1
      || pkg.checksums[0].algorithm !== 'SHA256'
      || pkg.checksums[0].checksumValue !== component.sourceIdentitySHA256
      || pkg.downloadLocation !== 'NOASSERTION'
      || pkg.copyrightText !== 'NOASSERTION'
      || !Array.isArray(pkg.externalRefs)
      || pkg.externalRefs.length !== 1
      || pkg.externalRefs[0].referenceCategory !== 'PACKAGE-MANAGER'
      || pkg.externalRefs[0].referenceType !== 'purl'
    ) {
      fail(`SPDX package ${pkg.SPDXID} does not match its locked component.`);
    }
  }
  assertPortableValue(sbom, 'SPDX document');
}

function parseAndValidateObjectMap(contents, manifest, sourceLock) {
  if (!contents.endsWith('\n')) fail('Object map must end in one newline.');
  const rawLines = contents.slice(0, -1).split('\n');
  if (rawLines.length === 0 || rawLines.some((line) => line.length === 0)) fail('Object map contains an empty line.');
  const records = rawLines.map((line, index) => {
    let record;
    try { record = JSON.parse(line); } catch { fail(`Object map line ${index + 1} is invalid JSON.`); }
    if (JSON.stringify(record) !== line) fail(`Object map line ${index + 1} is not canonical compact JSON.`);
    assertExactKeys(record, [
      'format', 'distributedSlice', 'thinBuild', 'mergedArchiveSHA256', 'mergedObjectOrdinal',
      'member', 'component', 'componentArchive', 'componentArchiveSHA256',
      'componentArchiveOrdinal', 'sourceIdentitySHA256', 'generatorEvidenceSHA256',
      'sourceMapping', 'mappingException', 'sourceFiles', 'sourceFileSetSHA256',
    ], `object map line ${index + 1}`);
    if (record.format !== EVIDENCE_FORMAT || record.mergedObjectOrdinal !== index) {
      fail(`Object map line ${index + 1} has a noncontiguous ordinal or unsupported format.`);
    }
    assertDigest(record.mergedArchiveSHA256, `object map line ${index + 1} merged hash`);
    assertDigest(record.componentArchiveSHA256, `object map line ${index + 1} component archive hash`);
    assertDigest(record.sourceIdentitySHA256, `object map line ${index + 1} source identity hash`);
    assertDigest(record.generatorEvidenceSHA256, `object map line ${index + 1} generator evidence hash`);
    assertDigest(record.sourceFileSetSHA256, `object map line ${index + 1} source-file-set hash`);
    const component = sourceLock.components.find((candidate) => candidate.id === record.component);
    if (!component) fail(`Object map line ${index + 1} names an unknown component.`);
    if (
      record.sourceIdentitySHA256 !== component.sourceIdentitySHA256
      || record.generatorEvidenceSHA256 !== component.generatorEvidenceSHA256
    ) {
      fail(`Object map line ${index + 1} is not bound to its component evidence.`);
    }
    if (!Array.isArray(record.sourceFiles) || record.sourceFileSetSHA256 !== canonicalHash(record.sourceFiles)) {
      fail(`Object map line ${index + 1} source-file evidence is malformed.`);
    }
    if (
      !['compiled-source-and-normalized-generator-evidence', 'excepted-normalized-generator-evidence'].includes(record.sourceMapping)
      || (record.sourceMapping === 'compiled-source-and-normalized-generator-evidence') !== (record.sourceFiles.length > 0)
      || (record.sourceFiles.length === 0) !== (record.mappingException !== null)
    ) {
      fail(`Object map line ${index + 1} source/generator mapping semantics are invalid.`);
    }
    if (record.mappingException !== null) {
      assertExactKeys(record.mappingException, ['code', 'subject', 'reason'], `object map line ${index + 1}.mappingException`);
      if (
        record.mappingException.code !== 'generated-object-without-direct-source'
        || record.mappingException.subject !== `${record.thinBuild}:${record.componentArchive}:${record.componentArchiveOrdinal}:${record.member}`
      ) {
        fail(`Object map line ${index + 1} has an inexact mapping exception.`);
      }
    }
    const componentSourceFiles = new Map(
      component.sourceIdentity.compiledSourceFiles.map((source) => [source.path, source])
    );
    for (const [sourceIndex, source] of record.sourceFiles.entries()) {
      assertFileDescriptor(source, `object map line ${index + 1}.sourceFiles[${sourceIndex}]`, source.path);
      if (JSON.stringify(componentSourceFiles.get(source.path)) !== JSON.stringify(source)) {
        fail(`Object map line ${index + 1} source file is not in its locked component source set.`);
      }
    }
    assertPortableValue(record, `object map line ${index + 1}`);
    return record;
  });
  if (
    records.length !== manifest.distributedIOSCoverage.mappedObjectMemberCount
    || records.length !== manifest.distributedIOSCoverage.mergedObjectMemberCount
    || manifest.distributedIOSCoverage.fullObjectCoverage !== true
    || manifest.distributedIOSCoverage.fullArchiveMemberCoverage !== true
    || (
      records.length + manifest.distributedIOSCoverage.archiveMetadataMemberCount
      !== manifest.distributedIOSCoverage.mergedArchiveMemberCount
    )
    || (
      manifest.distributedIOSCoverage.mergedArchiveMemberCount
        - manifest.distributedIOSCoverage.mergedObjectMemberCount
      !== manifest.distributedIOSCoverage.archiveMetadataMemberCount
    )
  ) {
    fail('Object map plus explicit metadata accounting is not full archive-member coverage for distributed iOS.');
  }
  if (canonicalHash(records) !== manifest.distributedIOSCoverage.orderedObjectMapSHA256) {
    fail('Object map ordered digest differs from the manifest.');
  }
  return records;
}

function assertCountHash(value, label) {
  assertExactKeys(value, ['count', 'sha256'], label);
  assertInteger(value.count, `${label}.count`);
  assertDigest(value.sha256, `${label}.sha256`);
}

function assertTreeIdentity(value, label) {
  assertExactKeys(value, ['fileCount', 'sha256'], label);
  assertInteger(value.fileCount, `${label}.fileCount`);
  assertDigest(value.sha256, `${label}.sha256`);
}

function validateManifestDetails(manifest, sourceLock) {
  assertExactKeys(manifest.product, ['name', 'buildIdentity'], 'manifest.product');
  if (manifest.product.name !== 'CoreKiwix' || !/^14\.2\.0\+arkfile\.[1-9][0-9]*$/u.test(manifest.product.buildIdentity)) {
    fail('Manifest product must be the controlled CoreKiwix 14.2.0+arkfile.N identity.');
  }
  assertFileDescriptor(manifest.generator, 'manifest.generator', SCRIPT_RELATIVE_PATH);

  const sourceLicenses = collectLicenseManifest(sourceLock);
  if (JSON.stringify(manifest.licenses) !== JSON.stringify(sourceLicenses)) {
    fail('Manifest license/notice evidence is not the exact source-lock set.');
  }

  const expectedArchives = COMPONENTS.flatMap((component) => component.installedArchives).sort();
  for (const thinBuild of manifest.thinBuilds) {
    assertExactKeys(thinBuild, [
      'id', 'platform', 'architecture', 'buildPath', 'componentEvidence',
      'componentArchives', 'mergedArchive',
    ], `thin build ${thinBuild.id}`);
    assertSafeRelativePath(thinBuild.buildPath, `${thinBuild.id}.buildPath`);
    if (!Array.isArray(thinBuild.componentEvidence) || thinBuild.componentEvidence.length !== COMPONENTS.length) {
      fail(`${thinBuild.id} must contain normalized evidence for exactly ${COMPONENTS.length} components.`);
    }
    const evidenceIds = thinBuild.componentEvidence.map((item) => item.component).sort();
    if (JSON.stringify(evidenceIds) !== JSON.stringify(sourceLock.componentSet)) {
      fail(`${thinBuild.id} normalized component evidence set is incomplete or duplicated.`);
    }
    for (const evidence of thinBuild.componentEvidence) {
      assertExactKeys(evidence, [
        'component', 'buildPath', 'compileRecords', 'dependencyRecords', 'compiledSources', 'exception',
      ], `${thinBuild.id}.${evidence.component} evidence`);
      assertSafeRelativePath(evidence.buildPath, `${thinBuild.id}.${evidence.component}.buildPath`);
      assertCountHash(evidence.compileRecords, `${thinBuild.id}.${evidence.component}.compileRecords`);
      assertCountHash(evidence.dependencyRecords, `${thinBuild.id}.${evidence.component}.dependencyRecords`);
      assertCountHash(evidence.compiledSources, `${thinBuild.id}.${evidence.component}.compiledSources`);
    }

    if (!Array.isArray(thinBuild.componentArchives) || thinBuild.componentArchives.length !== expectedArchives.length) {
      fail(`${thinBuild.id} must contain exactly ${expectedArchives.length} component-archive inventories.`);
    }
    const archiveNames = thinBuild.componentArchives.map((archive) => archive.archive).sort();
    if (JSON.stringify(archiveNames) !== JSON.stringify(expectedArchives)) {
      fail(`${thinBuild.id} component-archive inventory set is incomplete or duplicated.`);
    }
    for (const archive of thinBuild.componentArchives) {
      assertExactKeys(archive, [
        'component', 'archive', 'path', 'sizeBytes', 'sha256', 'archiveMemberCount',
        'objectMemberCount', 'orderedArchiveMembersSHA256', 'orderedObjectMembersSHA256',
        'definedSymbolCount', 'definedSymbolSetSHA256',
      ], `${thinBuild.id}.${archive.archive}`);
      assertSafeRelativePath(archive.path, `${thinBuild.id}.${archive.archive}.path`);
      assertInteger(archive.sizeBytes, `${thinBuild.id}.${archive.archive}.sizeBytes`);
      assertDigest(archive.sha256, `${thinBuild.id}.${archive.archive}.sha256`);
      assertInteger(archive.archiveMemberCount, `${thinBuild.id}.${archive.archive}.archiveMemberCount`);
      assertInteger(archive.objectMemberCount, `${thinBuild.id}.${archive.archive}.objectMemberCount`);
      assertDigest(archive.orderedArchiveMembersSHA256, `${thinBuild.id}.${archive.archive}.orderedArchiveMembersSHA256`);
      assertDigest(archive.orderedObjectMembersSHA256, `${thinBuild.id}.${archive.archive}.orderedObjectMembersSHA256`);
      assertInteger(archive.definedSymbolCount, `${thinBuild.id}.${archive.archive}.definedSymbolCount`);
      assertDigest(archive.definedSymbolSetSHA256, `${thinBuild.id}.${archive.archive}.definedSymbolSetSHA256`);
      if (archive.objectMemberCount > archive.archiveMemberCount) {
        fail(`${thinBuild.id}.${archive.archive} object count exceeds full archive-member count.`);
      }
      if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(archive.sha256)) {
        fail(`${thinBuild.id}.${archive.archive} uses a stale upstream denied hash.`);
      }
    }

    const merged = thinBuild.mergedArchive;
    assertExactKeys(merged, [
      'path', 'sizeBytes', 'sha256', 'archiveMemberCount', 'objectMemberCount',
      'orderedArchiveMembersSHA256', 'orderedObjectMembersSHA256', 'definedSymbolCount',
      'definedSymbolSetSHA256', 'relinkProof',
    ], `${thinBuild.id}.mergedArchive`);
    assertSafeRelativePath(merged.path, `${thinBuild.id}.mergedArchive.path`);
    assertInteger(merged.sizeBytes, `${thinBuild.id}.mergedArchive.sizeBytes`);
    assertDigest(merged.sha256, `${thinBuild.id}.mergedArchive.sha256`);
    assertInteger(merged.archiveMemberCount, `${thinBuild.id}.mergedArchive.archiveMemberCount`);
    assertInteger(merged.objectMemberCount, `${thinBuild.id}.mergedArchive.objectMemberCount`);
    assertDigest(merged.orderedArchiveMembersSHA256, `${thinBuild.id}.mergedArchive.orderedArchiveMembersSHA256`);
    assertDigest(merged.orderedObjectMembersSHA256, `${thinBuild.id}.mergedArchive.orderedObjectMembersSHA256`);
    assertInteger(merged.definedSymbolCount, `${thinBuild.id}.mergedArchive.definedSymbolCount`);
    assertDigest(merged.definedSymbolSetSHA256, `${thinBuild.id}.mergedArchive.definedSymbolSetSHA256`);
    if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(merged.sha256)) {
      fail(`${thinBuild.id} merged archive uses a stale upstream denied hash.`);
    }
    assertExactKeys(merged.relinkProof, [
      'method', 'componentArchiveOrder', 'exactOrderedObjectMemberMultiset',
      'componentDefinedSymbolSetSHA256', 'mergedDefinedSymbolSetSHA256', 'exactDefinedSymbolSet',
    ], `${thinBuild.id}.mergedArchive.relinkProof`);
    if (
      merged.relinkProof.method !== 'exact-ordered-object-member-multiset-and-defined-symbol-set'
      || merged.relinkProof.exactOrderedObjectMemberMultiset !== true
      || merged.relinkProof.exactDefinedSymbolSet !== true
      || merged.relinkProof.mergedDefinedSymbolSetSHA256 !== merged.definedSymbolSetSHA256
      || merged.relinkProof.componentDefinedSymbolSetSHA256 !== merged.definedSymbolSetSHA256
      || JSON.stringify([...merged.relinkProof.componentArchiveOrder].sort()) !== JSON.stringify(expectedArchives)
    ) {
      fail(`${thinBuild.id} relink/symbol-set proof is incomplete.`);
    }
  }

  assertExactKeys(manifest.xcframework, [
    'packageType', 'formatVersion', 'infoPlist', 'tree', 'slices',
    'controlledDeviceThinArchiveSHA256', 'distributedDeviceSliceExactArchiveIdentity',
  ], 'manifest.xcframework');
  if (
    manifest.xcframework.packageType !== 'XFWK'
    || manifest.xcframework.formatVersion !== '1.0'
    || manifest.xcframework.distributedDeviceSliceExactArchiveIdentity !== true
  ) {
    fail('Manifest XCFramework identity is invalid.');
  }
  assertFileDescriptor(manifest.xcframework.infoPlist, 'manifest.xcframework.infoPlist', 'Info.plist');
  assertTreeIdentity(manifest.xcframework.tree, 'manifest.xcframework.tree');
  for (const slice of manifest.xcframework.slices) {
    assertExactKeys(slice, [
      'identifier', 'platform', 'variant', 'architectures', 'binary', 'sliceTree',
    ], `XCFramework slice ${slice.identifier}`);
    assertFileDescriptor(slice.binary, `${slice.identifier}.binary`, `${slice.identifier}/merged.a`);
    assertTreeIdentity(slice.sliceTree, `${slice.identifier}.sliceTree`);
    if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(slice.binary.sha256)) {
      fail(`${slice.identifier} uses a stale upstream denied hash.`);
    }
  }

  assertExactKeys(manifest.distributedIOSCoverage, [
    'sliceIdentifier', 'thinBuild', 'exactArchiveIdentity', 'mergedArchiveSHA256',
    'mergedArchiveMemberCount', 'mergedObjectMemberCount', 'mappedObjectMemberCount',
    'archiveMetadataMemberCount', 'archiveMetadataMembersSHA256', 'orderedObjectMapSHA256',
    'fullObjectCoverage', 'fullArchiveMemberCoverage',
  ], 'manifest.distributedIOSCoverage');
  assertDigest(manifest.distributedIOSCoverage.mergedArchiveSHA256, 'distributedIOSCoverage.mergedArchiveSHA256');
  assertInteger(manifest.distributedIOSCoverage.mergedArchiveMemberCount, 'distributedIOSCoverage.mergedArchiveMemberCount');
  assertInteger(manifest.distributedIOSCoverage.mergedObjectMemberCount, 'distributedIOSCoverage.mergedObjectMemberCount');
  assertInteger(manifest.distributedIOSCoverage.mappedObjectMemberCount, 'distributedIOSCoverage.mappedObjectMemberCount');
  assertInteger(manifest.distributedIOSCoverage.archiveMetadataMemberCount, 'distributedIOSCoverage.archiveMetadataMemberCount');
  assertDigest(manifest.distributedIOSCoverage.archiveMetadataMembersSHA256, 'distributedIOSCoverage.archiveMetadataMembersSHA256');
  assertDigest(manifest.distributedIOSCoverage.orderedObjectMapSHA256, 'distributedIOSCoverage.orderedObjectMapSHA256');
  const deviceThin = manifest.thinBuilds.find((thin) => thin.id === 'ios-device-arm64');
  const deviceSlice = manifest.xcframework.slices.find((slice) => slice.identifier === 'ios-arm64');
  if (
    manifest.distributedIOSCoverage.sliceIdentifier !== 'ios-arm64'
    || manifest.distributedIOSCoverage.thinBuild !== 'ios-device-arm64'
    || manifest.distributedIOSCoverage.exactArchiveIdentity !== true
    || manifest.distributedIOSCoverage.mergedArchiveSHA256 !== deviceThin.mergedArchive.sha256
    || manifest.distributedIOSCoverage.mergedArchiveSHA256 !== deviceSlice.binary.sha256
    || manifest.xcframework.controlledDeviceThinArchiveSHA256 !== deviceThin.mergedArchive.sha256
  ) {
    fail('Distributed iOS coverage is not bound to an exact controlled thin/distributed-slice archive identity.');
  }
}

export function validateEvidenceArtifacts(files) {
  const exactFileNames = Object.keys(files).sort();
  const expectedFileNames = Object.values(OUTPUT_FILES).sort();
  if (JSON.stringify(exactFileNames) !== JSON.stringify(expectedFileNames)) {
    fail(`Evidence bundle files must be exactly: ${expectedFileNames.join(', ')}.`);
  }
  const manifest = parseJSONStrict(files[OUTPUT_FILES.manifest], 'build manifest');
  const sourceLock = parseJSONStrict(files[OUTPUT_FILES.sourceLock], 'source lock');
  const sbom = parseJSONStrict(files[OUTPUT_FILES.sbom], 'SPDX SBOM');
  validateSourceLock(sourceLock);
  validateSPDX(sbom, sourceLock);
  assertExactKeys(manifest, [
    'format', 'policy', 'product', 'generator', 'staleUpstreamSHA256DenyList',
    'componentSet', 'componentSetSHA256', 'exceptionSemantics', 'outputs', 'licenses',
    'thinBuilds', 'xcframework', 'distributedIOSCoverage',
  ], 'build manifest');
  if (manifest.format !== EVIDENCE_FORMAT || manifest.policy !== EVIDENCE_POLICY) {
    fail('Build manifest format/policy is unsupported.');
  }
  if (JSON.stringify(manifest.staleUpstreamSHA256DenyList) !== JSON.stringify(STALE_UPSTREAM_SHA256_DENY_LIST)) {
    fail('Build manifest stale-upstream deny-list is not the exact required policy list.');
  }
  if (
    JSON.stringify(manifest.componentSet) !== JSON.stringify(sourceLock.componentSet)
    || manifest.componentSetSHA256 !== sourceLock.componentSetSHA256
  ) {
    fail('Build manifest and source lock component sets differ.');
  }
  validateExceptionSemantics(manifest.exceptionSemantics);
  assertExactKeys(manifest.outputs, ['sourceLock', 'sbom', 'objectMap'], 'manifest.outputs');
  assertFileDescriptor(manifest.outputs.sourceLock, 'manifest.outputs.sourceLock', OUTPUT_FILES.sourceLock);
  assertFileDescriptor(manifest.outputs.sbom, 'manifest.outputs.sbom', OUTPUT_FILES.sbom);
  assertFileDescriptor(manifest.outputs.objectMap, 'manifest.outputs.objectMap', OUTPUT_FILES.objectMap, true);
  for (const [key, outputFile] of [
    ['sourceLock', OUTPUT_FILES.sourceLock],
    ['sbom', OUTPUT_FILES.sbom],
    ['objectMap', OUTPUT_FILES.objectMap],
  ]) {
    const descriptor = manifest.outputs[key];
    if (descriptor.sizeBytes !== Buffer.byteLength(files[outputFile]) || descriptor.sha256 !== sha256(files[outputFile])) {
      fail(`manifest.outputs.${key} does not match exact artifact bytes.`);
    }
  }
  if (!Array.isArray(manifest.thinBuilds) || manifest.thinBuilds.length !== 5) {
    fail('Build manifest must contain exactly five thin builds.');
  }
  const thinIds = manifest.thinBuilds.map((thin) => thin.id).sort();
  if (JSON.stringify(thinIds) !== JSON.stringify(THIN_BUILDS.map((thin) => thin.id).sort())) {
    fail('Build manifest thin build set is incomplete or duplicated.');
  }
  if (!Array.isArray(manifest.xcframework.slices) || manifest.xcframework.slices.length !== 3) {
    fail('Build manifest must contain exactly three XCFramework slices.');
  }
  const sliceIds = manifest.xcframework.slices.map((slice) => slice.identifier).sort();
  if (JSON.stringify(sliceIds) !== JSON.stringify(EXPECTED_FRAMEWORK_SLICES.map((slice) => slice.identifier).sort())) {
    fail('Build manifest XCFramework slice set is incomplete or duplicated.');
  }
  if (manifest.outputs.objectMap.lineCount !== manifest.distributedIOSCoverage.mappedObjectMemberCount) {
    fail('Object-map output line count differs from distributed iOS coverage.');
  }
  validateManifestDetails(manifest, sourceLock);
  const objectRecords = parseAndValidateObjectMap(files[OUTPUT_FILES.objectMap], manifest, sourceLock);
  assertPortableValue(manifest, 'build manifest');
  return { manifest, sourceLock, sbom, objectRecords };
}

function atomicWrite(outputDirectory, fileName, contents) {
  const destination = path.join(outputDirectory, fileName);
  if (existsSync(destination) && lstatSync(destination).isSymbolicLink()) {
    fail(`Refusing to replace symlink output ${fileName}.`);
  }
  const temporary = path.join(outputDirectory, `.${fileName}.${process.pid}.tmp`);
  if (existsSync(temporary)) fail(`Temporary output already exists: ${temporary}`);
  writeFileSync(temporary, contents, { encoding: 'utf8', mode: 0o644, flag: 'wx' });
  renameSync(temporary, destination);
}

export function generateEvidence(options) {
  const bundle = buildEvidenceBundle(options);
  if (existsSync(bundle.output)) {
    const entry = lstatSync(bundle.output);
    if (entry.isSymbolicLink() || !entry.isDirectory()) fail('Output must be a real directory, not a symlink.');
  } else {
    mkdirSync(bundle.output, { recursive: true });
  }
  for (const fileName of Object.values(OUTPUT_FILES)) {
    atomicWrite(bundle.output, fileName, bundle.files[fileName]);
  }
  return {
    output: bundle.output,
    manifestSHA256: sha256(bundle.files[OUTPUT_FILES.manifest]),
    objectCount: bundle.objectRecords.length,
    componentCount: bundle.sourceLock.components.length,
  };
}

function readEvidenceDirectory(outputDirectory) {
  const output = requireExistingDirectory(path.resolve(outputDirectory), 'evidence output');
  const files = {};
  for (const fileName of Object.values(OUTPUT_FILES)) {
    const filePath = path.join(output, fileName);
    requireRegularFile(filePath, `evidence output ${fileName}`);
    files[fileName] = readFileSync(filePath, 'utf8');
  }
  return { output, files };
}

export function verifyEvidence(options) {
  const existing = readEvidenceDirectory(options.output);
  validateEvidenceArtifacts(existing.files);
  const expected = buildEvidenceBundle(options);
  for (const fileName of Object.values(OUTPUT_FILES)) {
    if (existing.files[fileName] !== expected.files[fileName]) {
      fail(`${fileName} differs from freshly recomputed controlled-build evidence.`);
    }
  }
  return {
    output: existing.output,
    manifestSHA256: sha256(existing.files[OUTPUT_FILES.manifest]),
    objectCount: expected.objectRecords.length,
    componentCount: expected.sourceLock.components.length,
  };
}

function usage() {
  return `Usage:
  node ${SCRIPT_RELATIVE_PATH} generate --repo <repo> --build-work <build-work> --framework <CoreKiwix.xcframework> --output <evidence-dir> [--exceptions <policy.json>]
  node ${SCRIPT_RELATIVE_PATH} verify   --repo <repo> --build-work <build-work> --framework <CoreKiwix.xcframework> --output <evidence-dir> [--exceptions <policy.json>]`;
}

function parseCLI(argv) {
  if (argv.length < 1) fail(usage());
  const mode = argv[0];
  if (mode !== 'generate' && mode !== 'verify') fail(usage());
  const allowed = new Set(['--repo', '--build-work', '--framework', '--output', '--exceptions']);
  const options = {};
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || typeof value !== 'string' || value.length === 0 || value.startsWith('--')) {
      fail(usage());
    }
    const key = flag.slice(2).replace(/-([a-z])/gu, (_match, letter) => letter.toUpperCase());
    if (Object.hasOwn(options, key)) fail(`Duplicate CLI option ${flag}.`);
    options[key] = value;
  }
  for (const key of ['repo', 'buildWork', 'framework', 'output']) {
    if (!options[key]) fail(`Missing --${key.replace(/[A-Z]/gu, (letter) => `-${letter.toLowerCase()}`)}.\n${usage()}`);
  }
  return { mode, options };
}

function isMainModule() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
  }
}

if (isMainModule()) {
  try {
    const { mode, options } = parseCLI(process.argv.slice(2));
    const result = mode === 'generate' ? generateEvidence(options) : verifyEvidence(options);
    process.stdout.write(
      `CoreKiwix controlled-build evidence ${mode === 'generate' ? 'generated' : 'verified'}: `
      + `${result.componentCount} components, ${result.objectCount} distributed iOS objects, manifest ${result.manifestSHA256}.\n`
    );
  } catch (error) {
    process.stderr.write(`CoreKiwix evidence error: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = error instanceof CoreKiwixEvidenceError ? 1 : 2;
  }
}

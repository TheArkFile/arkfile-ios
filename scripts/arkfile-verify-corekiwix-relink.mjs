#!/usr/bin/env node

/**
 * Build-plan, deterministic-archive, and relink verification primitives for
 * ArkFile's controlled CoreKiwix corresponding-source package.
 *
 * The supported relink proof is deliberately explicit: Apple static archives
 * may not reproduce byte-for-byte because their archive index/header metadata
 * is rewritten.  We therefore require the exact ordered non-index member
 * multiset and the exact externally-defined symbol set for all five thin
 * targets, plus byte identity for every component archive and extracted
 * libmicrohttpd object input.
 */

import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import {
  chmodSync,
  closeSync,
  copyFileSync,
  cpSync,
  existsSync,
  lstatSync,
  linkSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  renameSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync,
  writeSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  OUTPUT_FILES as EVIDENCE_OUTPUT_FILES,
  STALE_UPSTREAM_SHA256_DENY_LIST,
  validateEvidenceArtifacts,
} from './arkfile-corekiwix-evidence.mjs';

export const SOURCE_PACKAGE_SCHEMA_VERSION = 1;
export const SOURCE_PACKAGE_INVENTORY = 'INVENTORY.json';
export const SOURCE_PACKAGE_PROOF = 'exact-ordered-object-member-multiset-and-defined-symbol-set';

const SCRIPT_RELATIVE_PATH = 'scripts/arkfile-verify-corekiwix-relink.mjs';
const SHA256_PATTERN = /^[0-9a-f]{64}$/u;
const GIT_SHA_PATTERN = /^[0-9a-f]{40}$/u;
const CONTROLLED_SECRET_SCAN_POLICY_SHA256 = '89235cbb6d2f6a521b70063dd0d9402767531cc734b1a6362dc42452ac9946d9';
const SECRET_PATTERN = /(?:OPENFDA_API_KEY|(?:api[_-]?key|access[_-]?token|client[_-]?secret|password|private[_-]?key)\s*[:=]\s*["']?[A-Za-z0-9_./+\-=]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bsk-[A-Za-z0-9_-]{16,})/iu;
const HOST_PATH_PATTERN = /(?:^|[\s"'=])\/(?:Applications|Library|System|Users|Volumes|private|tmp|usr|bin|opt|var)\//mu;
const EVIDENCE_FILE_NAMES = Object.values(EVIDENCE_OUTPUT_FILES).sort();
const COMPONENT_ARCHIVES = [
  'libcurl.a', 'libicudata.a', 'libicui18n.a', 'libicuuc.a', 'libkiwix.a',
  'liblzma.a', 'libmicrohttpd.a', 'libpugixml.a', 'libxapian.a', 'libz.a',
  'libzim.a', 'libzstd.a',
].sort();
const EXPECTED_TARGETS = [
  { id: 'ios-device-arm64', recipeTarget: 'ios_arm64_static', architecture: 'arm64' },
  { id: 'ios-simulator-arm64', recipeTarget: 'ios_simulator_arm64_static', architecture: 'arm64' },
  { id: 'ios-simulator-x86_64', recipeTarget: 'ios_simulator_x86-64_static', architecture: 'x86_64' },
  { id: 'macos-arm64', recipeTarget: 'macos_arm64_static', architecture: 'arm64' },
  { id: 'macos-x86_64', recipeTarget: 'macos_x86-64_static', architecture: 'x86_64' },
].sort((left, right) => left.id.localeCompare(right.id));
const EXPECTED_FRAMEWORK_SLICES = [
  'ios-arm64', 'ios-arm64_x86_64-simulator', 'macos-arm64_x86_64',
].sort();

export class CoreKiwixSourcePackageError extends Error {
  constructor(message) {
    super(message);
    this.name = 'CoreKiwixSourcePackageError';
  }
}

function fail(message) {
  throw new CoreKiwixSourcePackageError(message);
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

export function sha256File(filePath) {
  const hash = createHash('sha256');
  const descriptor = openSync(filePath, 'r');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  try {
    while (true) {
      const count = readSync(descriptor, buffer, 0, buffer.length, null);
      if (count === 0) break;
      hash.update(buffer.subarray(0, count));
    }
  } finally {
    closeSync(descriptor);
  }
  return hash.digest('hex');
}

function canonicalJSON(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function canonicalHash(value) {
  return sha256(JSON.stringify(value));
}

function assertObject(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object.`);
}

function assertString(value, label) {
  if (typeof value !== 'string' || value.length === 0) fail(`${label} must be a non-empty string.`);
  if (value !== value.normalize('NFC') || /[\u0000-\u001f\u007f]/u.test(value)) {
    fail(`${label} must be normalized printable text.`);
  }
}

function assertDigest(value, label) {
  if (typeof value !== 'string' || !SHA256_PATTERN.test(value)) fail(`${label} must be a lowercase SHA-256 digest.`);
}

function assertInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} must be a nonnegative safe integer.`);
}

function assertExactKeys(value, expected, label) {
  assertObject(value, label);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    fail(`${label} has missing or unexpected fields.`);
  }
}

export function assertSafeRelativePath(value, label = 'path') {
  assertString(value, label);
  if (value.startsWith('/') || value.includes('\\') || /^[A-Za-z]:[\\/]/u.test(value)) {
    fail(`${label} must be a portable relative path.`);
  }
  const parts = value.split('/');
  if (parts.some((part) => part === '' || part === '.' || part === '..')) {
    fail(`${label} contains an empty, dot, or traversal component.`);
  }
}

function requireDirectory(directoryPath, label) {
  let metadata;
  try {
    metadata = lstatSync(directoryPath);
  } catch (error) {
    if (error?.code === 'ENOENT') fail(`Missing ${label}: ${directoryPath}`);
    fail(`Unable to inspect ${label} at ${directoryPath}: ${error?.code ?? 'filesystem-error'} ${error instanceof Error ? error.message : String(error)}`);
  }
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) fail(`${label} must be a real directory, not a symlink.`);
  try {
    return realpathSync(directoryPath);
  } catch (error) {
    fail(`Unable to resolve ${label} at ${directoryPath}: ${error?.code ?? 'filesystem-error'} ${error instanceof Error ? error.message : String(error)}`);
  }
}

function requireRegularFile(filePath, label) {
  let metadata;
  try {
    metadata = lstatSync(filePath);
  } catch (error) {
    if (error?.code === 'ENOENT') fail(`Missing ${label}: ${filePath}`);
    fail(`Unable to inspect ${label} at ${filePath}: ${error?.code ?? 'filesystem-error'} ${error instanceof Error ? error.message : String(error)}`);
  }
  if (metadata.isSymbolicLink() || !metadata.isFile()) fail(`${label} must be a regular file, not a symlink.`);
  return filePath;
}

function safeRelative(root, filePath, label) {
  const relative = path.relative(root, filePath).split(path.sep).join('/');
  assertSafeRelativePath(relative, label);
  return relative;
}

function readCanonicalJSON(filePath, label) {
  requireRegularFile(filePath, label);
  const contents = readFileSync(filePath, 'utf8');
  let value;
  try { value = JSON.parse(contents); } catch { fail(`${label} is not valid JSON.`); }
  if (canonicalJSON(value) !== contents) fail(`${label} must be canonical pretty-printed JSON.`);
  return { value, contents };
}

function resolveTool(candidates, label) {
  const result = candidates.find((candidate) => existsSync(candidate));
  if (!result) fail(`Required ${label} tool was not found at an approved path.`);
  const resolved = realpathSync(result);
  requireRegularFile(resolved, `${label} tool`);
  return resolved;
}

function tools() {
  return {
    ar: resolveTool(['/usr/bin/ar', '/usr/bin/llvm-ar'], 'ar'),
    nm: resolveTool(['/usr/bin/nm', '/usr/bin/llvm-nm'], 'nm'),
    lipo: resolveTool(['/usr/bin/lipo'], 'lipo'),
    libtool: resolveTool(['/usr/bin/libtool'], 'libtool'),
    tar: resolveTool(['/usr/bin/tar'], 'tar'),
    gzip: resolveTool(['/usr/bin/gzip'], 'gzip'),
    git: resolveTool(['/usr/bin/git'], 'git'),
  };
}

function runText(tool, args, label, options = {}) {
  try {
    return execFileSync(tool, args, {
      encoding: 'utf8',
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { COPYFILE_DISABLE: '1', PATH: '/usr/bin:/bin' },
      ...options,
    });
  } catch (error) {
    const stderr = typeof error?.stderr === 'string' ? error.stderr.trim() : '';
    fail(`${label} failed${stderr ? `: ${stderr}` : '.'}`);
  }
}

function runBuffer(tool, args, label, options = {}) {
  try {
    return execFileSync(tool, args, {
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { COPYFILE_DISABLE: '1', PATH: '/usr/bin:/bin' },
      ...options,
    });
  } catch (error) {
    const stderr = Buffer.isBuffer(error?.stderr) ? error.stderr.toString('utf8').trim() : '';
    fail(`${label} failed${stderr ? `: ${stderr}` : '.'}`);
  }
}

function runToFile(tool, args, outputPath, label, options = {}) {
  const descriptor = openSync(outputPath, 'wx', 0o600);
  let result;
  try {
    result = spawnSync(tool, args, {
      stdio: ['ignore', descriptor, 'pipe'],
      env: { COPYFILE_DISABLE: '1', PATH: '/usr/bin:/bin' },
      ...options,
    });
  } finally {
    closeSync(descriptor);
  }
  if (result.error || result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString('utf8').trim() : '';
    fail(`${label} failed${stderr ? `: ${stderr}` : '.'}`);
  }
}

function archiveMembers(toolset, archivePath, label) {
  const all = runText(toolset.ar, ['-t', archivePath], `${label} member inventory`)
    .split(/\r?\n/u).map((line) => line.trim()).filter(Boolean);
  if (all.length === 0) fail(`${label} contains no members.`);
  for (const member of all) {
    assertString(member, `${label} member`);
    if (member.includes('/') || member === '.' || member === '..') fail(`${label} has unsafe member ${member}.`);
  }
  const objects = all.filter((member) => !/^__\.SYMDEF(?: SORTED)?$/u.test(member) && member !== '/' && member !== '//');
  if (objects.length === 0) fail(`${label} contains no object members.`);
  return { all, objects };
}

function definedSymbols(toolset, archivePath, label) {
  const symbols = [...new Set(runText(toolset.nm, ['-gUj', archivePath], `${label} symbol inventory`)
    .split(/\r?\n/u).map((line) => line.trim())
    .filter((line) => line && !line.endsWith(':') && !/\s/u.test(line)))].sort();
  if (symbols.length === 0) fail(`${label} has no externally-defined symbols.`);
  return symbols;
}

function architectures(toolset, archivePath, label) {
  return runText(toolset.lipo, ['-archs', archivePath], `${label} architecture inspection`)
    .trim().split(/\s+/u).filter(Boolean).map((item) => item === 'aarch64' ? 'arm64' : item).sort();
}

export function assertNotStaleSHA256(digest, label) {
  assertDigest(digest, label);
  if (STALE_UPSTREAM_SHA256_DENY_LIST.includes(digest)) fail(`${label} matches a denied stale upstream CoreKiwix SHA-256.`);
}

function scanSecretLike(contents, label) {
  if (SECRET_PATTERN.test(contents)) fail(`${label} contains secret-like material.`);
}

function resolveScannerExecutable(value, label) {
  assertString(value, `${label} executable path`);
  const resolved = realpathSync(path.resolve(value));
  requireRegularFile(resolved, `${label} executable`);
  return resolved;
}

function runScanner(executable, args, cwd, acceptedStatuses, label) {
  const result = spawnSync(executable, args, {
    cwd,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: process.env,
  });
  if (result.error || result.signal || !acceptedStatuses.includes(result.status)) {
    fail(`${label} failed with status ${result.status ?? 'unknown'}${result.signal ? ` and signal ${result.signal}` : ''}.`);
  }
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '', status: result.status };
}

function canonicalFindingMultisetHash(records) {
  const canonicalRecords = records.map((record) => JSON.stringify(record)).sort();
  return sha256(JSON.stringify(canonicalRecords.map((record) => JSON.parse(record))));
}

function normalizeScannerFile(extractedRoot, scannerPath, label, digestCache) {
  assertString(scannerPath, `${label} scanner path`);
  const resolvedRoot = realpathSync(extractedRoot);
  const candidate = path.isAbsolute(scannerPath)
    ? path.resolve(scannerPath)
    : path.resolve(resolvedRoot, scannerPath);
  let resolved;
  try {
    resolved = realpathSync(candidate);
  } catch {
    fail(`${label} names a missing scanner file.`);
  }
  const relative = path.relative(resolvedRoot, resolved).split(path.sep).join('/');
  if (relative === '' || relative.startsWith('../') || path.isAbsolute(relative)) {
    fail(`${label} names a scanner file outside the extracted archive root.`);
  }
  assertSafeRelativePath(relative, `${label} normalized path`);
  requireRegularFile(resolved, `${label} scanner file`);
  if (!digestCache.has(relative)) digestCache.set(relative, sha256File(resolved));
  return { path: relative, fileSHA256: digestCache.get(relative) };
}

function countBy(records, keyFunction) {
  const counts = new Map();
  for (const record of records) {
    const key = keyFunction(record);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function assertCountMapMatchesPolicy(actual, declared, keyFields, label) {
  if (!Array.isArray(declared)) fail(`${label} count policy must be an array.`);
  const expected = new Map();
  for (const [index, entry] of declared.entries()) {
    assertExactKeys(entry, [...keyFields, 'findingCount'], `${label}[${index}]`);
    const values = keyFields.map((field) => {
      assertString(entry[field], `${label}[${index}].${field}`);
      return entry[field];
    });
    if (!Number.isSafeInteger(entry.findingCount) || entry.findingCount <= 0) {
      fail(`${label}[${index}].findingCount must be a positive safe integer.`);
    }
    const key = values.join('\0');
    if (expected.has(key)) fail(`${label} contains a duplicate count key.`);
    expected.set(key, entry.findingCount);
  }
  if (actual.size !== expected.size) fail(`${label} has missing or unexpected finding groups.`);
  for (const [key, count] of actual) {
    if (expected.get(key) !== count) fail(`${label} finding counts differ from the reviewed policy.`);
  }
}

function countMapPolicyDifferences(actual, declared, keyFields) {
  const expected = new Map(declared.map((entry) => [
    keyFields.map((field) => entry[field]).join('\0'),
    entry.findingCount,
  ]));
  return [...new Set([...actual.keys(), ...expected.keys()])].sort()
    .filter((key) => actual.get(key) !== expected.get(key))
    .map((key) => `${key.split('\0').join(' at ')} (actual ${actual.get(key) ?? 0}, expected ${expected.get(key) ?? 0})`);
}

function assertNamedCounts(actual, declared, label) {
  assertObject(declared, label);
  const expected = Object.entries(declared);
  if (actual.size !== expected.length) fail(`${label} has missing or unexpected names.`);
  for (const [name, count] of expected) {
    assertString(name, `${label} name`);
    if (!Number.isSafeInteger(count) || count <= 0 || actual.get(name) !== count) {
      fail(`${label} differs from the reviewed policy.`);
    }
  }
}

function parseOctal(buffer, start, length, label) {
  const raw = buffer.subarray(start, start + length).toString('ascii').replace(/\0.*$/u, '').trim();
  if (!/^[0-7]+$/u.test(raw)) fail(`${label} has invalid octal metadata.`);
  return Number.parseInt(raw, 8);
}

function parseTarString(buffer, start, length) {
  const zero = buffer.indexOf(0, start);
  const end = zero >= start && zero < start + length ? zero : start + length;
  return buffer.subarray(start, end).toString('utf8');
}

function tarHeaderChecksum(header) {
  let total = 0;
  for (let index = 0; index < 512; index += 1) {
    total += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  return total;
}

function hashFileRange(descriptor, offset, size) {
  const hash = createHash('sha256');
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  let remaining = size;
  let position = offset;
  while (remaining > 0) {
    const wanted = Math.min(buffer.length, remaining);
    const count = readSync(descriptor, buffer, 0, wanted, position);
    if (count !== wanted) fail('Tar member data ended unexpectedly.');
    hash.update(buffer.subarray(0, count));
    remaining -= count;
    position += count;
  }
  return hash.digest('hex');
}

export function inspectDeterministicTar(tarPath, expectedEpoch) {
  requireRegularFile(tarPath, 'uncompressed source package tar');
  const descriptor = openSync(tarPath, 'r');
  const totalSize = statSync(tarPath).size;
  const entries = [];
  const seen = new Set();
  let offset = 0;
  let zeroBlocks = 0;
  try {
    while (offset + 512 <= totalSize) {
      const header = Buffer.alloc(512);
      if (readSync(descriptor, header, 0, 512, offset) !== 512) fail('Tar header ended unexpectedly.');
      if (header.every((byte) => byte === 0)) {
        zeroBlocks += 1;
        offset += 512;
        continue;
      }
      if (zeroBlocks > 0) fail('Tar contains data after its zero-block terminator.');
      const storedChecksum = parseOctal(header, 148, 8, 'tar header checksum');
      if (storedChecksum !== tarHeaderChecksum(header)) fail('Tar header checksum mismatch.');
      const name = parseTarString(header, 0, 100);
      const prefix = parseTarString(header, 345, 155);
      const memberPath = prefix ? `${prefix}/${name}` : name;
      assertSafeRelativePath(memberPath, 'tar member path');
      if (seen.has(memberPath)) fail(`Tar contains duplicate member ${memberPath}.`);
      seen.add(memberPath);
      const type = String.fromCharCode(header[156] || 0x30);
      if (type !== '0') fail(`Tar member ${memberPath} is a link, directory, or special file (type ${JSON.stringify(type)}).`);
      const mode = parseOctal(header, 100, 8, `${memberPath} mode`);
      const uid = parseOctal(header, 108, 8, `${memberPath} uid`);
      const gid = parseOctal(header, 116, 8, `${memberPath} gid`);
      const size = parseOctal(header, 124, 12, `${memberPath} size`);
      const mtime = parseOctal(header, 136, 12, `${memberPath} mtime`);
      const magic = header.subarray(257, 263).toString('ascii');
      const uname = parseTarString(header, 265, 32);
      const gname = parseTarString(header, 297, 32);
      if (!['ustar\0', 'ustar '].includes(magic)) fail(`${memberPath} is not a ustar member.`);
      if (![0o644, 0o755].includes(mode) || uid !== 0 || gid !== 0 || uname !== 'root' || gname !== 'root') {
        fail(`${memberPath} has non-deterministic owner or mode metadata.`);
      }
      if (mtime !== expectedEpoch) fail(`${memberPath} has non-deterministic mtime ${mtime}; expected ${expectedEpoch}.`);
      const dataOffset = offset + 512;
      if (dataOffset + size > totalSize) fail(`${memberPath} extends beyond the tar file.`);
      entries.push({
        path: memberPath,
        mode,
        sizeBytes: size,
        sha256: hashFileRange(descriptor, dataOffset, size),
        dataOffset,
      });
      offset = dataOffset + Math.ceil(size / 512) * 512;
    }
  } finally {
    closeSync(descriptor);
  }
  if (zeroBlocks < 2) fail('Tar is missing its two-block zero terminator.');
  if (entries.length === 0) fail('Tar contains no regular files.');
  return entries;
}

function inspectGzipHeader(archivePath) {
  requireRegularFile(archivePath, 'CoreKiwix source package archive');
  const descriptor = openSync(archivePath, 'r');
  const header = Buffer.alloc(10);
  let count;
  try {
    count = readSync(descriptor, header, 0, header.length, 0);
  } finally {
    closeSync(descriptor);
  }
  if (count !== 10 || header[0] !== 0x1f || header[1] !== 0x8b || header[2] !== 8) {
    fail('Source package is not a gzip stream.');
  }
  const flags = header[3];
  const mtime = header.readUInt32LE(4);
  if (flags !== 0 || mtime !== 0) fail('Gzip header contains a filename, timestamp, or other non-deterministic fields.');
}

function decompressArchive(toolset, archivePath, destinationTar) {
  inspectGzipHeader(archivePath);
  runToFile(toolset.gzip, ['-d', '-c', archivePath], destinationTar, 'gzip decompression');
}

function copyTarEntries(tarPath, entries, destinationRoot, epoch) {
  const descriptor = openSync(tarPath, 'r');
  try {
    for (const entry of entries) {
      const destination = path.join(destinationRoot, ...entry.path.split('/'));
      mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 });
      const output = openSync(destination, 'wx', entry.mode);
      try {
        const buffer = Buffer.allocUnsafe(1024 * 1024);
        let remaining = entry.sizeBytes;
        let inputOffset = entry.dataOffset;
        while (remaining > 0) {
          const wanted = Math.min(buffer.length, remaining);
          const count = readSync(descriptor, buffer, 0, wanted, inputOffset);
          if (count !== wanted) fail(`Tar member ${entry.path} ended unexpectedly.`);
          let writtenOffset = 0;
          while (writtenOffset < count) {
            const written = writeSync(output, buffer, writtenOffset, count - writtenOffset);
            if (!Number.isSafeInteger(written) || written <= 0 || written > count - writtenOffset) {
              fail(`Tar member ${entry.path} could not be written completely.`);
            }
            writtenOffset += written;
          }
          inputOffset += count;
          remaining -= count;
        }
      } finally {
        closeSync(output);
      }
      chmodSync(destination, entry.mode);
      utimesSync(destination, epoch, epoch);
    }
  } finally {
    closeSync(descriptor);
  }
}

export function writeDeterministicTarGzip(stageRoot, memberPaths, epoch, outputArchive, toolset = tools()) {
  if (!Number.isSafeInteger(epoch) || epoch <= 0) fail('sourceDateEpoch must be a positive safe integer.');
  if (existsSync(outputArchive)) fail(`Refusing to overwrite existing output archive ${outputArchive}.`);
  const sorted = [...memberPaths].sort();
  if (new Set(sorted).size !== sorted.length) fail('Deterministic tar member list contains duplicates.');
  for (const memberPath of sorted) assertSafeRelativePath(memberPath, 'deterministic tar member path');
  const workspace = mkdtempSync(path.join(os.tmpdir(), 'arkfile-corekiwix-tar-'));
  const listPath = path.join(workspace, 'members.txt');
  const tarPath = path.join(workspace, 'package.tar');
  const gzipPath = path.join(workspace, 'package.tar.gz');
  let publishWorkspace = null;
  try {
    writeFileSync(listPath, `${sorted.join('\n')}\n`, { mode: 0o600 });
    const tarResult = spawnSync(toolset.tar, [
      '-c', '--format', 'ustar', '--uid', '0', '--gid', '0', '--uname', 'root', '--gname', 'root',
      '-f', tarPath, '-C', stageRoot, '-T', listPath,
    ], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { COPYFILE_DISABLE: '1', PATH: '/usr/bin:/bin' },
    });
    if (tarResult.error || tarResult.status !== 0) {
      fail(`Deterministic tar creation failed: ${tarResult.stderr?.toString('utf8').trim() || 'unknown error'}`);
    }
    inspectDeterministicTar(tarPath, epoch);
    runToFile(toolset.gzip, ['-n', '-9', '-c', tarPath], gzipPath, 'deterministic gzip creation');
    const outputDirectory = path.dirname(outputArchive);
    mkdirSync(outputDirectory, { recursive: true });
    publishWorkspace = mkdtempSync(path.join(outputDirectory, '.arkfile-corekiwix-publish-'));
    const publishCandidate = path.join(publishWorkspace, path.basename(outputArchive));
    copyFileSync(gzipPath, publishCandidate);
    const result = {
      archiveSHA256: sha256File(publishCandidate),
      sizeBytes: statSync(publishCandidate).size,
    };
    if (
      result.archiveSHA256 !== sha256File(gzipPath)
      || result.sizeBytes !== statSync(gzipPath).size
    ) {
      fail('Destination-side deterministic archive copy differs from the verified gzip bytes.');
    }
    // A hard link publishes the already-complete destination-side file
    // atomically and fails instead of overwriting if another process created
    // the requested output after the initial existence check.
    linkSync(publishCandidate, outputArchive);
    return result;
  } finally {
    try { rmSync(workspace, { recursive: true, force: true }); } catch {}
    if (publishWorkspace) {
      try { rmSync(publishWorkspace, { recursive: true, force: true }); } catch {}
    }
  }
}

function collectFileSpecsRecursively(value, results = []) {
  if (Array.isArray(value)) {
    value.forEach((item) => collectFileSpecsRecursively(item, results));
    return results;
  }
  if (!value || typeof value !== 'object') return results;
  if (
    typeof value.path === 'string'
    && typeof value.sha256 === 'string'
    && value.path.includes('CoreKiwixNativeNotices/')
  ) {
    results.push({ path: value.path, sha256: value.sha256 });
  }
  if (
    typeof value.noticePath === 'string'
    && typeof value.noticeSha256 === 'string'
    && value.noticePath.includes('CoreKiwixNativeNotices/')
  ) {
    results.push({ path: value.noticePath, sha256: value.noticeSha256 });
  }
  Object.values(value).forEach((item) => collectFileSpecsRecursively(item, results));
  return results;
}

function validateNotices(recipeLock, noticesRoot) {
  const indexPath = path.join(noticesRoot, 'index.json');
  const { value: index, contents } = readCanonicalJSON(indexPath, 'CoreKiwix notice index');
  if (index.schemaVersion !== 1 || index.package?.name !== 'CoreKiwix') fail('Notice index identity is invalid.');
  if (index.package.version !== recipeLock.package.version) fail('Notice index package version differs from the recipe lock.');
  const missing = Array.isArray(index.missingStandaloneLicenseTexts) ? index.missingStandaloneLicenseTexts : [];
  const lockMissing = recipeLock.noticeIndex?.missingStandaloneLicenseTextEntryIds;
  if (
    index.coverageComplete !== true
    || recipeLock.noticeIndex?.coverageComplete !== true
    || missing.length !== 0
    || (Array.isArray(lockMissing) && lockMissing.length !== 0)
  ) {
    const ids = Array.isArray(lockMissing) ? lockMissing.join(', ') : 'unclassified notice gaps';
    fail(`Curated CoreKiwix notices are incomplete; unresolved standalone notice entries: ${ids}.`);
  }
  if (recipeLock.noticeIndex?.sha256 !== sha256(contents)) {
    fail('Recipe lock notice-index SHA-256 does not match exact index.json bytes.');
  }
  const specs = collectFileSpecsRecursively(index)
    .concat(collectFileSpecsRecursively(recipeLock));
  const deduplicated = new Map();
  for (const spec of specs) {
    assertDigest(spec.sha256, `notice ${spec.path} SHA-256`);
    const marker = 'CoreKiwixNativeNotices/';
    const markerIndex = spec.path.indexOf(marker);
    const relative = spec.path.slice(markerIndex + marker.length);
    assertSafeRelativePath(relative, `notice ${spec.path}`);
    const existing = deduplicated.get(relative);
    if (existing && existing !== spec.sha256) fail(`Notice ${relative} has conflicting locked hashes.`);
    deduplicated.set(relative, spec.sha256);
  }
  for (const [relative, expected] of deduplicated) {
    const noticePath = path.join(noticesRoot, ...relative.split('/'));
    requireRegularFile(noticePath, `curated notice ${relative}`);
    const actual = sha256File(noticePath);
    if (actual !== expected) fail(`Curated notice ${relative} SHA-256 mismatch.`);
  }
  const actualFiles = [];
  const visit = (directory, prefix = '') => {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const fullPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink() || (!entry.isDirectory() && !entry.isFile())) {
        fail(`Notice directory contains link or special entry ${relative}.`);
      }
      if (entry.isDirectory()) visit(fullPath, relative);
      else actualFiles.push(relative);
    }
  };
  visit(noticesRoot);
  if (!actualFiles.includes('index.json')) fail('Notice directory lacks index.json.');
  for (const relative of actualFiles) {
    if (relative === 'index.json' || relative === 'README.md') continue;
    if (!deduplicated.has(relative)) fail(`Curated notice file ${relative} is not bound by the index/recipe lock.`);
  }
  return { index, contents, files: actualFiles };
}

function gitText(toolset, recipeRoot, args, label) {
  return runText(toolset.git, ['-C', recipeRoot, ...args], label);
}

function validateRecipeCheckout(recipeLock, recipeRoot, toolset) {
  const expected = recipeLock.buildRecipe?.source;
  if (!expected || expected.type !== 'git' || !GIT_SHA_PATTERN.test(expected.commit) || !GIT_SHA_PATTERN.test(expected.tree)) {
    fail('Recipe lock lacks an exact Git commit/tree identity.');
  }
  const commit = gitText(toolset, recipeRoot, ['rev-parse', 'HEAD'], 'recipe Git commit').trim();
  const tree = gitText(toolset, recipeRoot, ['rev-parse', 'HEAD^{tree}'], 'recipe Git tree').trim();
  if (commit !== expected.commit || tree !== expected.tree) fail('Recipe checkout HEAD commit/tree differs from the curated recipe lock.');
  const tags = gitText(toolset, recipeRoot, ['tag', '--points-at', 'HEAD'], 'recipe Git tag').split(/\r?\n/u).filter(Boolean);
  if (!tags.includes(expected.release)) fail(`Recipe checkout HEAD is not tagged ${expected.release}.`);
  const diff = gitText(toolset, recipeRoot, ['diff', '--binary', 'HEAD'], 'recipe tracked working-tree diff');
  scanSecretLike(diff, 'recipe tracked working-tree diff');
  const expectedDiff = recipeLock.buildRecipe?.trackedWorkingTreeDiff?.sha256;
  assertDigest(expectedDiff, 'recipe tracked diff SHA-256');
  if (sha256(diff) !== expectedDiff) fail('Recipe tracked working-tree diff SHA-256 differs from the curated lock.');
  const modifiedFiles = recipeLock.buildRecipe?.modifiedFiles;
  if (!Array.isArray(modifiedFiles) || modifiedFiles.length === 0) fail('Recipe lock must enumerate modified recipe files.');
  for (const [index, file] of modifiedFiles.entries()) {
    assertSafeRelativePath(file.path, `modified recipe file[${index}] path`);
    assertDigest(file.sha256, `modified recipe file[${index}] SHA-256`);
    const fullPath = path.join(recipeRoot, ...file.path.split('/'));
    requireRegularFile(fullPath, `modified recipe file ${file.path}`);
    if (sha256File(fullPath) !== file.sha256) fail(`Modified recipe file ${file.path} differs from the lock.`);
  }
  const patchFiles = recipeLock.buildRecipe?.appliedPatchFiles;
  if (!Array.isArray(patchFiles) || patchFiles.length === 0) fail('Recipe lock must enumerate applied patch files.');
  for (const [index, file] of patchFiles.entries()) {
    assertSafeRelativePath(file.path, `applied patch[${index}] path`);
    assertDigest(file.sha256, `applied patch[${index}] SHA-256`);
    const fullPath = path.join(recipeRoot, ...file.path.split('/'));
    requireRegularFile(fullPath, `applied patch ${file.path}`);
    if (sha256File(fullPath) !== file.sha256) fail(`Applied patch ${file.path} differs from the lock.`);
  }
  const tracked = runBuffer(toolset.git, ['-C', recipeRoot, 'ls-files', '-z'], 'recipe tracked file list')
    .toString('utf8').split('\0').filter(Boolean).sort();
  if (tracked.length === 0) fail('Recipe checkout has no tracked files.');
  tracked.forEach((item) => assertSafeRelativePath(item, 'recipe tracked path'));
  return { commit, tree, diff, tracked, modifiedFiles };
}

function collectEvidence(evidenceRoot) {
  const files = {};
  for (const fileName of EVIDENCE_FILE_NAMES) {
    const filePath = path.join(evidenceRoot, fileName);
    requireRegularFile(filePath, `CoreKiwix evidence ${fileName}`);
    files[fileName] = readFileSync(filePath, 'utf8');
  }
  const validated = validateEvidenceArtifacts(files);
  return { files, ...validated };
}

function validateExceptionPolicy(exceptionsPath, evidence) {
  const { value: policy, contents } = readCanonicalJSON(exceptionsPath, 'CoreKiwix exception policy');
  scanSecretLike(contents, 'CoreKiwix exception policy');
  if (policy.format !== 1 || !Array.isArray(policy.exceptions) || policy.exceptions.length !== 3) {
    fail('CoreKiwix exception policy must contain exactly three curated format-1 exceptions.');
  }
  if (JSON.stringify(policy.exceptions) !== JSON.stringify(evidence.manifest.exceptionSemantics.declared)) {
    fail('CoreKiwix exception policy differs from the exact declared-and-used evidence exceptions.');
  }
  return { policy, contents };
}

function normalizeBuildEvidence(contents, roots, label) {
  if (contents.includes('\0')) fail(`${label} contains binary material.`);
  scanSecretLike(contents, label);
  let normalized = contents.replace(/\r\n/gu, '\n');
  const canonicalReplacements = [
    [roots.framework, '<FRAMEWORK>'],
    [roots.recipeRoot, '<RECIPE_ROOT>'],
    [roots.buildWork, '<BUILD_WORK>'],
  ];
  const replacements = canonicalReplacements.flatMap(([absolute, marker]) => {
    const aliases = new Set([absolute]);
    if (absolute.startsWith('/private/')) aliases.add(absolute.slice('/private'.length));
    if (absolute.startsWith('/var/') || absolute.startsWith('/tmp/')) aliases.add(`/private${absolute}`);
    return [...aliases].map((candidate) => [candidate, marker]);
  }).sort((left, right) => right[0].length - left[0].length);
  for (const [absolute, marker] of replacements) normalized = normalized.split(absolute).join(marker);
  normalized = normalized
    .replace(/\/Applications\/Xcode[^\s"']*\/Contents\/Developer/gu, '<XCODE>')
    .replace(/\/Library\/Developer\/CommandLineTools/gu, '<COMMAND_LINE_TOOLS>')
    .replace(/\/(?:Library|System|usr|bin|opt)(?=\/)/gu, '<SYSTEM>');
  if (HOST_PATH_PATTERN.test(normalized)) fail(`${label} retains a host-absolute filesystem path after normalization.`);
  scanSecretLike(normalized, `${label} normalized output`);
  return normalized;
}

function selectedBuildEvidenceFiles(buildDirectory) {
  const files = [];
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (entry.name === 'LOGS' || entry.name === '.git' || entry.name === 'INSTALL') continue;
        visit(fullPath);
      } else if (entry.isFile() && (entry.name === 'compile_commands.json' || /\.(?:d|Po|Plo)$/u.test(entry.name))) {
        files.push(fullPath);
      } else if (!entry.isFile()) {
        fail(`Build evidence tree contains special entry ${fullPath}.`);
      }
    }
  };
  visit(buildDirectory);
  return files.sort();
}

function normalizedMode(sourcePath) {
  return (statSync(sourcePath).mode & 0o111) !== 0 ? 0o755 : 0o644;
}

class PackageEntries {
  constructor() {
    this.entries = new Map();
    this.materializedSymlinks = [];
  }

  addSource(destination, sourcePath, origin, materializedFromSymlink = null) {
    assertSafeRelativePath(destination, 'package destination');
    requireRegularFile(sourcePath, `package source ${origin}`);
    const entry = {
      path: destination,
      mode: normalizedMode(sourcePath),
      sizeBytes: statSync(sourcePath).size,
      sha256: sha256File(sourcePath),
      origin,
      sourcePath,
      data: null,
    };
    assertNotStaleSHA256(entry.sha256, destination);
    this.add(entry);
    if (materializedFromSymlink) {
      this.materializedSymlinks.push({ path: destination, target: materializedFromSymlink, sha256: entry.sha256 });
    }
  }

  addData(destination, data, origin, mode = 0o644, scan = true) {
    assertSafeRelativePath(destination, 'generated package destination');
    const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data, 'utf8');
    if (scan) scanSecretLike(buffer.toString('utf8'), origin);
    const entry = {
      path: destination,
      mode,
      sizeBytes: buffer.length,
      sha256: sha256(buffer),
      origin,
      sourcePath: null,
      data: buffer,
    };
    assertNotStaleSHA256(entry.sha256, destination);
    this.add(entry);
  }

  add(entry) {
    if (this.entries.has(entry.path)) fail(`Duplicate package path ${entry.path}.`);
    this.entries.set(entry.path, entry);
  }

  inventoryFiles() {
    return [...this.entries.values()].sort((a, b) => a.path.localeCompare(b.path)).map((entry) => ({
      path: entry.path,
      mode: entry.mode,
      sizeBytes: entry.sizeBytes,
      sha256: entry.sha256,
      origin: entry.origin,
    }));
  }
}

function addTree(entries, root, destinationPrefix, originPrefix, options = {}) {
  const canonicalRoot = requireDirectory(root, originPrefix);
  const visit = (directory, relativePrefix = '') => {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const relative = relativePrefix ? `${relativePrefix}/${entry.name}` : entry.name;
      const fullPath = path.join(directory, entry.name);
      if (options.excludeGit && entry.name === '.git') continue;
      if (entry.isDirectory()) {
        visit(fullPath, relative);
      } else if (entry.isFile()) {
        entries.addSource(`${destinationPrefix}/${relative}`, fullPath, `${originPrefix}/${relative}`);
      } else if (entry.isSymbolicLink()) {
        if (!options.materializeSymlinks) fail(`${originPrefix}/${relative} is a prohibited symlink.`);
        const resolved = realpathSync(fullPath);
        const withinRoot = path.relative(canonicalRoot, resolved);
        if (withinRoot === '..' || withinRoot.startsWith(`..${path.sep}`) || path.isAbsolute(withinRoot)) {
          fail(`${originPrefix}/${relative} symlink escapes its source root.`);
        }
        requireRegularFile(resolved, `${originPrefix}/${relative} materialized symlink target`);
        entries.addSource(
          `${destinationPrefix}/${relative}`,
          resolved,
          `${originPrefix}/${relative}`,
          safeRelative(canonicalRoot, resolved, `${originPrefix}/${relative} target`)
        );
      } else {
        fail(`${originPrefix}/${relative} is a prohibited special file.`);
      }
    }
  };
  visit(canonicalRoot);
}

function collectLockedArchiveInputs(recipeLock) {
  const results = [];
  const visit = (value) => {
    if (Array.isArray(value)) return value.forEach(visit);
    if (!value || typeof value !== 'object') return;
    if (typeof value.archiveName === 'string' && typeof value.archiveSha256 === 'string') {
      results.push({ archiveName: value.archiveName, archiveSha256: value.archiveSha256 });
    }
    Object.values(value).forEach(visit);
  };
  visit(recipeLock.sourceInputs);
  visit(recipeLock.patchArchiveInputs);
  visit(recipeLock.testOnlyInputs);
  const deduplicated = new Map();
  for (const item of results) {
    assertSafeRelativePath(item.archiveName, 'locked source archive name');
    assertDigest(item.archiveSha256, `${item.archiveName} locked SHA-256`);
    const previous = deduplicated.get(item.archiveName);
    if (previous && previous !== item.archiveSha256) fail(`${item.archiveName} has conflicting recipe-lock hashes.`);
    deduplicated.set(item.archiveName, item.archiveSha256);
  }
  if (deduplicated.size === 0) fail('Recipe lock contains no exact source/tool archive inputs.');
  return deduplicated;
}

function validateArchiveInputs(recipeLock, buildWork) {
  const archiveRoot = requireDirectory(path.join(buildWork, 'ARCHIVE'), 'build ARCHIVE input directory');
  const locked = collectLockedArchiveInputs(recipeLock);
  for (const [archiveName, digest] of locked) {
    const archivePath = path.join(archiveRoot, archiveName);
    requireRegularFile(archivePath, `locked source archive ${archiveName}`);
    if (sha256File(archivePath) !== digest) fail(`Locked source archive ${archiveName} SHA-256 mismatch.`);
    assertNotStaleSHA256(digest, archiveName);
  }
  const actual = readdirSync(archiveRoot, { withFileTypes: true })
    .filter((entry) => !entry.name.startsWith('.'));
  for (const entry of actual) {
    if (entry.isSymbolicLink() || !entry.isFile()) fail(`ARCHIVE/${entry.name} is a link or special file.`);
    if (!locked.has(entry.name)) fail(`ARCHIVE/${entry.name} is not bound by the recipe lock.`);
  }
  return archiveRoot;
}

function archiveEvidenceSpec(archivePath, toolset, label) {
  requireRegularFile(archivePath, label);
  const memberInventory = archiveMembers(toolset, archivePath, label);
  const symbols = definedSymbols(toolset, archivePath, label);
  return {
    sizeBytes: statSync(archivePath).size,
    sha256: sha256File(archivePath),
    archiveMemberCount: memberInventory.all.length,
    archiveMemberSetSHA256: canonicalHash(memberInventory.all),
    objectMemberCount: memberInventory.objects.length,
    orderedObjectMemberSetSHA256: canonicalHash(memberInventory.objects),
    definedSymbolCount: symbols.length,
    definedSymbolSetSHA256: canonicalHash(symbols),
    internal: { all: memberInventory.all, objects: memberInventory.objects, symbols },
  };
}

function collectRelinkTargets(entries, evidence, buildWork, toolset) {
  const targets = [];
  for (const thin of evidence.manifest.thinBuilds) {
    const buildDirectory = path.join(buildWork, ...thin.buildPath.split('/'));
    const libraryDirectory = path.join(buildDirectory, 'INSTALL', 'lib');
    requireDirectory(libraryDirectory, `${thin.id} component library directory`);
    const manifestByName = new Map(thin.componentArchives.map((item) => [item.archive, item]));
    const archives = [];
    for (const archiveName of COMPONENT_ARCHIVES) {
      const sourcePath = path.join(libraryDirectory, archiveName);
      requireRegularFile(sourcePath, `${thin.id} ${archiveName}`);
      const manifestArchive = manifestByName.get(archiveName);
      if (!manifestArchive || sha256File(sourcePath) !== manifestArchive.sha256) {
        fail(`${thin.id} ${archiveName} differs from the controlled evidence manifest.`);
      }
      const destination = `relink/${thin.id}/archives/${archiveName}`;
      entries.addSource(destination, sourcePath, `${thin.buildPath}/INSTALL/lib/${archiveName}`);
      const spec = archiveEvidenceSpec(sourcePath, toolset, `${thin.id} ${archiveName}`);
      assertNotStaleSHA256(spec.sha256, `${thin.id} ${archiveName}`);
      archives.push({ name: archiveName, path: destination, ...Object.fromEntries(
        Object.entries(spec).filter(([key]) => key !== 'internal')
      ) });
    }
    const mergedPath = path.join(libraryDirectory, 'merged.a');
    requireRegularFile(mergedPath, `${thin.id} merged archive`);
    if (sha256File(mergedPath) !== thin.mergedArchive.sha256) fail(`${thin.id} merged archive differs from evidence.`);
    const mergedDestination = `relink/${thin.id}/reference/merged.a`;
    entries.addSource(mergedDestination, mergedPath, `${thin.buildPath}/INSTALL/lib/merged.a`);
    const merged = archiveEvidenceSpec(mergedPath, toolset, `${thin.id} merged archive`);
    assertNotStaleSHA256(merged.sha256, `${thin.id} merged archive`);
    const order = thin.mergedArchive.relinkProof.componentArchiveOrder;
    if (JSON.stringify([...order].sort()) !== JSON.stringify(COMPONENT_ARCHIVES)) {
      fail(`${thin.id} relink order does not name the exact component archive set.`);
    }
    const mhdPath = path.join(libraryDirectory, 'libmicrohttpd.a');
    const mhdMembers = archiveMembers(toolset, mhdPath, `${thin.id} libmicrohttpd`).objects;
    if (new Set(mhdMembers).size !== mhdMembers.length) fail(`${thin.id} libmicrohttpd has duplicate member names; unambiguous extraction is impossible.`);
    const mhdObjects = mhdMembers.map((member, ordinal) => {
      const bytes = runBuffer(toolset.ar, ['-p', mhdPath, member], `${thin.id} libmicrohttpd object ${member}`);
      if (bytes.length === 0) fail(`${thin.id} libmicrohttpd object ${member} extracted empty.`);
      const safeMember = member.replace(/[^A-Za-z0-9._-]/gu, '_');
      const destination = `relink/${thin.id}/objects/libmicrohttpd/${String(ordinal).padStart(4, '0')}-${safeMember}`;
      entries.addData(destination, bytes, `${thin.buildPath}/INSTALL/lib/libmicrohttpd.a:${member}`, 0o644, false);
      return { ordinal, member, path: destination, sizeBytes: bytes.length, sha256: sha256(bytes) };
    });
    const actualArchitectures = architectures(toolset, mergedPath, `${thin.id} merged archive`);
    if (JSON.stringify(actualArchitectures) !== JSON.stringify([thin.architecture])) {
      fail(`${thin.id} merged architecture differs from its evidence identity.`);
    }
    targets.push({
      id: thin.id,
      platform: thin.platform,
      architecture: thin.architecture,
      componentArchives: archives,
      componentArchiveOrder: order,
      libmicrohttpdObjects: mhdObjects,
      referenceMergedArchive: {
        path: mergedDestination,
        ...Object.fromEntries(Object.entries(merged).filter(([key]) => key !== 'internal')),
      },
      relinkProof: {
        method: SOURCE_PACKAGE_PROOF,
        binaryByteIdentityRequired: false,
        reason: 'Apple libtool rewrites static-archive index/header metadata; ordered non-index objects and externally-defined symbols are the exact supported proof.',
        exactOrderedObjectMemberMultisetRequired: true,
        exactDefinedSymbolSetRequired: true,
      },
    });
  }
  if (targets.length !== 5) fail('Relink package must contain exactly five controlled thin targets.');
  const ids = targets.map((target) => target.id).sort();
  const expectedIds = ['ios-device-arm64', 'ios-simulator-arm64', 'ios-simulator-x86_64', 'macos-arm64', 'macos-x86_64'].sort();
  if (JSON.stringify(ids) !== JSON.stringify(expectedIds)) fail('Relink target set is incomplete or duplicated.');
  return targets;
}

function validateRecipeLock(recipeLock, recipeLockContents) {
  scanSecretLike(recipeLockContents, 'CoreKiwix recipe lock');
  if (recipeLock.schemaVersion !== 1 || recipeLock.package?.name !== 'CoreKiwix') {
    fail('Recipe lock identity is invalid.');
  }
  assertString(recipeLock.package.version, 'recipe lock package version');
  assertString(recipeLock.status, 'recipe lock status');
  if (/(?:draft|awaiting|incomplete)/iu.test(recipeLock.status)) {
    fail(`Recipe lock status is not release-ready: ${recipeLock.status}.`);
  }
  if (!Number.isSafeInteger(recipeLock.sourceDateEpoch) || recipeLock.sourceDateEpoch <= 0) {
    fail('Recipe lock sourceDateEpoch must be a positive safe integer.');
  }
  if (!Array.isArray(recipeLock.targetMatrix) || recipeLock.targetMatrix.length !== 5) {
    fail('Recipe lock target matrix must contain exactly five targets.');
  }
  const actualTargets = recipeLock.targetMatrix.map((target, index) => {
    assertObject(target, `recipe target[${index}]`);
    assertString(target.recipeTarget, `recipe target[${index}].recipeTarget`);
    assertString(target.architecture, `recipe target[${index}].architecture`);
    return { recipeTarget: target.recipeTarget, architecture: target.architecture };
  }).sort((left, right) => left.recipeTarget.localeCompare(right.recipeTarget));
  const expectedTargets = EXPECTED_TARGETS.map(({ recipeTarget, architecture }) => ({ recipeTarget, architecture }))
    .sort((left, right) => left.recipeTarget.localeCompare(right.recipeTarget));
  if (JSON.stringify(actualTargets) !== JSON.stringify(expectedTargets)) {
    fail('Recipe lock target matrix is incomplete, duplicated, or has the wrong architecture.');
  }
  if (
    !Array.isArray(recipeLock.expectedXcframeworkSlices)
    || JSON.stringify([...recipeLock.expectedXcframeworkSlices].sort()) !== JSON.stringify(EXPECTED_FRAMEWORK_SLICES)
  ) {
    fail('Recipe lock XCFramework slice set is incomplete or duplicated.');
  }
}

function addPossiblyMaterializedFile(entries, destination, sourcePath, sourceRoot, origin) {
  if (!existsSync(sourcePath)) fail(`Missing package source ${origin}: ${sourcePath}`);
  const metadata = lstatSync(sourcePath);
  if (metadata.isFile()) {
    entries.addSource(destination, sourcePath, origin);
    return;
  }
  if (!metadata.isSymbolicLink()) fail(`${origin} is a directory or special file.`);
  const resolved = realpathSync(sourcePath);
  const canonicalRoot = realpathSync(sourceRoot);
  const relativeTarget = path.relative(canonicalRoot, resolved);
  if (
    relativeTarget === '..'
    || relativeTarget.startsWith(`..${path.sep}`)
    || path.isAbsolute(relativeTarget)
  ) {
    fail(`${origin} symlink escapes its source root.`);
  }
  requireRegularFile(resolved, `${origin} materialized symlink target`);
  entries.addSource(
    destination,
    resolved,
    origin,
    safeRelative(canonicalRoot, resolved, `${origin} symlink target`)
  );
}

function nulPaths(buffer, label) {
  const values = buffer.toString('utf8').split('\0').filter(Boolean).sort();
  values.forEach((value) => assertSafeRelativePath(value, label));
  return values;
}

function collectRecipe(entries, recipeLock, recipeLockPath, recipeRoot, toolset) {
  const checkout = validateRecipeCheckout(recipeLock, recipeRoot, toolset);
  const trackedSet = new Set(checkout.tracked);
  const modified = recipeLock.buildRecipe.modifiedFiles;
  const declaredModified = new Set(modified.map((item) => item.path));
  const changedTracked = nulPaths(
    runBuffer(toolset.git, ['-C', recipeRoot, 'diff', '--name-only', '-z', 'HEAD', '--'], 'recipe modified tracked paths'),
    'recipe modified tracked path'
  );
  const expectedChangedTracked = [...declaredModified].filter((item) => trackedSet.has(item)).sort();
  if (JSON.stringify(changedTracked) !== JSON.stringify(expectedChangedTracked)) {
    fail('Recipe tracked modification set differs from the curated modified-file set.');
  }
  const declaredExtra = new Set([
    ...modified.map((item) => item.path),
    ...recipeLock.buildRecipe.appliedPatchFiles.map((item) => item.path),
  ].filter((item) => !trackedSet.has(item)));
  const untracked = nulPaths(
    runBuffer(toolset.git, ['-C', recipeRoot, 'ls-files', '--others', '--exclude-standard', '-z'], 'recipe untracked paths'),
    'recipe untracked path'
  );
  if (JSON.stringify(untracked) !== JSON.stringify([...declaredExtra].sort())) {
    fail('Recipe checkout has missing or unbound untracked files.');
  }

  const recipePaths = [...new Set([...checkout.tracked, ...untracked])].sort();
  for (const relative of recipePaths) {
    addPossiblyMaterializedFile(
      entries,
      `recipe/source/${relative}`,
      path.join(recipeRoot, ...relative.split('/')),
      recipeRoot,
      `recipe/${relative}`
    );
  }
  for (const file of [...modified].sort((left, right) => left.path.localeCompare(right.path))) {
    addPossiblyMaterializedFile(
      entries,
      `recipe/modified-files/${file.path}`,
      path.join(recipeRoot, ...file.path.split('/')),
      recipeRoot,
      `recipe modified file ${file.path}`
    );
  }
  entries.addData(
    'recipe/tracked-working-tree.diff',
    checkout.diff,
    'git diff --binary HEAD',
    0o644,
    true
  );
  entries.addSource(
    'recipe/CoreKiwixNativeBuildRecipe.lock.json',
    recipeLockPath,
    'CoreKiwixNativeBuildRecipe.lock.json'
  );
  return {
    commit: checkout.commit,
    tree: checkout.tree,
    release: recipeLock.buildRecipe.source.release,
    trackedFileCount: checkout.tracked.length,
    untrackedCuratedFileCount: untracked.length,
    trackedWorkingTreeDiff: {
      path: 'recipe/tracked-working-tree.diff',
      sha256: sha256(checkout.diff),
    },
    fullRecipeRoot: 'recipe/source',
    modifiedFilesRoot: 'recipe/modified-files',
  };
}

function validateEvidenceSourceBindings(evidence, buildWork, archiveInputs, toolset) {
  for (const [index, sourceInput] of evidence.sourceLock.sourceInputs.entries()) {
    assertSafeRelativePath(sourceInput.path, `evidence source input[${index}] path`);
    if (!sourceInput.path.startsWith('ARCHIVE/')) fail(`${sourceInput.path} is not an ARCHIVE source input.`);
    const fullPath = path.join(buildWork, ...sourceInput.path.split('/'));
    requireRegularFile(fullPath, `evidence source input ${sourceInput.path}`);
    if (statSync(fullPath).size !== sourceInput.sizeBytes || sha256File(fullPath) !== sourceInput.sha256) {
      fail(`Evidence source input ${sourceInput.path} differs from live build-work.`);
    }
    const archiveName = sourceInput.path.slice('ARCHIVE/'.length);
    if (archiveInputs.get(archiveName) !== sourceInput.sha256) {
      fail(`Evidence source input ${sourceInput.path} is not identically bound by the recipe lock.`);
    }
  }
  for (const component of evidence.sourceLock.components) {
    assertSafeRelativePath(component.sourcePath, `${component.id} source path`);
    if (!component.sourcePath.startsWith('SOURCE/')) fail(`${component.id} source path is outside SOURCE/.`);
    const sourceRoot = requireDirectory(
      path.join(buildWork, ...component.sourcePath.split('/')),
      `${component.id} exact SOURCE directory`
    );
    if (component.sourceIdentity.git) {
      const commit = gitText(toolset, sourceRoot, ['rev-parse', 'HEAD'], `${component.id} source Git commit`).trim();
      const tree = gitText(toolset, sourceRoot, ['rev-parse', 'HEAD^{tree}'], `${component.id} source Git tree`).trim();
      const status = gitText(
        toolset,
        sourceRoot,
        ['status', '--porcelain=v1', '--untracked-files=no'],
        `${component.id} source Git status`
      ).trim();
      if (
        commit !== component.sourceIdentity.git.commit
        || tree !== component.sourceIdentity.git.tree
        || status !== ''
      ) {
        fail(`${component.id} SOURCE Git identity differs from controlled evidence.`);
      }
    }
    for (const license of component.licenses) {
      assertSafeRelativePath(license.path, `${component.id} license path`);
      const fullPath = path.join(buildWork, ...license.path.split('/'));
      requireRegularFile(fullPath, `${component.id} license ${license.path}`);
      if (statSync(fullPath).size !== license.sizeBytes || sha256File(fullPath) !== license.sha256) {
        fail(`${component.id} license ${license.path} differs from controlled evidence.`);
      }
    }
    for (const source of component.sourceIdentity.compiledSourceFiles) {
      assertSafeRelativePath(source.path, `${component.id} compiled source path`);
      const fullPath = path.join(buildWork, ...source.path.split('/'));
      requireRegularFile(fullPath, `${component.id} compiled source ${source.path}`);
      if (statSync(fullPath).size !== source.sizeBytes || sha256File(fullPath) !== source.sha256) {
        fail(`${component.id} compiled source ${source.path} differs from controlled evidence.`);
      }
    }
  }
}

function collectSourceAndBuildEvidence(entries, evidence, buildWork, roots) {
  const sourceRoot = path.join(buildWork, 'SOURCE');
  addTree(entries, sourceRoot, 'source/SOURCE', 'SOURCE', {
    excludeGit: true,
    materializeSymlinks: true,
  });
  const compiledSources = new Map();
  for (const component of evidence.sourceLock.components) {
    for (const source of component.sourceIdentity.compiledSourceFiles) {
      const previous = compiledSources.get(source.path);
      if (previous && previous !== source.sha256) fail(`Compiled source ${source.path} has conflicting evidence hashes.`);
      compiledSources.set(source.path, source.sha256);
    }
  }
  for (const [relative] of [...compiledSources.entries()].sort((left, right) => left[0].localeCompare(right[0]))) {
    entries.addSource(
      `build-evidence/compiled-sources/${relative}`,
      path.join(buildWork, ...relative.split('/')),
      `compiled source ${relative}`
    );
  }

  const normalizedRecords = [];
  const seen = new Set();
  for (const thin of evidence.manifest.thinBuilds) {
    assertSafeRelativePath(thin.buildPath, `${thin.id} build path`);
    const buildDirectory = requireDirectory(path.join(buildWork, ...thin.buildPath.split('/')), `${thin.id} build directory`);
    for (const selectedPath of selectedBuildEvidenceFiles(buildDirectory)) {
      const relative = safeRelative(buildWork, selectedPath, 'selected build evidence path');
      if (seen.has(relative)) continue;
      seen.add(relative);
      const contents = readFileSync(selectedPath, 'utf8');
      const normalized = normalizeBuildEvidence(contents, roots, `selected build evidence ${relative}`);
      const destination = `build-evidence/normalized/${relative}`;
      entries.addData(destination, normalized, `normalized ${relative}`, 0o644, true);
      normalizedRecords.push({
        sourcePath: relative,
        packagedPath: destination,
        sourceSizeBytes: statSync(selectedPath).size,
        sourceSHA256: sha256File(selectedPath),
        normalizedSizeBytes: Buffer.byteLength(normalized),
        normalizedSHA256: sha256(normalized),
      });
    }
  }
  normalizedRecords.sort((left, right) => left.sourcePath.localeCompare(right.sourcePath));
  const index = {
    schemaVersion: 1,
    policy: 'selected compile_commands.json and dependency files only; LOGS, INSTALL, .git, and ambient environment are excluded',
    pathNormalization: {
      buildWork: '<BUILD_WORK>',
      framework: '<FRAMEWORK>',
      recipeRoot: '<RECIPE_ROOT>',
      xcode: '<XCODE>',
      commandLineTools: '<COMMAND_LINE_TOOLS>',
      stableSystemRoots: '<SYSTEM>',
    },
    normalizedFileCount: normalizedRecords.length,
    normalizedFiles: normalizedRecords,
    compiledSourceFileCount: compiledSources.size,
  };
  entries.addData('build-evidence/NORMALIZATION.json', canonicalJSON(index), 'normalized build evidence index');
  return index;
}

function collectFrameworkTree(entries, frameworkRoot, evidence, recipeLock) {
  const files = [];
  const visit = (directory, prefix = '') => {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const fullPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink() || (!entry.isDirectory() && !entry.isFile())) {
        fail(`XCFramework contains prohibited link or special entry ${relative}.`);
      }
      if (entry.isDirectory()) visit(fullPath, relative);
      else files.push({ path: relative, sizeBytes: statSync(fullPath).size, sha256: sha256File(fullPath) });
    }
  };
  visit(frameworkRoot);
  if (
    files.length !== evidence.manifest.xcframework.tree.fileCount
    || canonicalHash(files) !== evidence.manifest.xcframework.tree.sha256
  ) {
    fail('XCFramework tree differs from controlled evidence.');
  }
  if (JSON.stringify([...recipeLock.expectedXcframeworkSlices].sort()) !== JSON.stringify(EXPECTED_FRAMEWORK_SLICES)) {
    fail('Recipe lock does not bind the exact XCFramework slice set.');
  }
  for (const slice of evidence.manifest.xcframework.slices) {
    const binaryPath = path.join(frameworkRoot, ...slice.binary.path.split('/'));
    requireRegularFile(binaryPath, `${slice.identifier} XCFramework binary`);
    const digest = sha256File(binaryPath);
    if (digest !== slice.binary.sha256 || statSync(binaryPath).size !== slice.binary.sizeBytes) {
      fail(`${slice.identifier} XCFramework binary differs from controlled evidence.`);
    }
    assertNotStaleSHA256(digest, `${slice.identifier} XCFramework binary`);
  }
  addTree(entries, frameworkRoot, 'framework/CoreKiwix.xcframework', 'CoreKiwix.xcframework');
  return {
    root: 'framework/CoreKiwix.xcframework',
    fileCount: files.length,
    treeSHA256: canonicalHash(files),
    slices: evidence.manifest.xcframework.slices.map((slice) => ({
      identifier: slice.identifier,
      architectures: slice.architectures,
      binaryPath: `framework/CoreKiwix.xcframework/${slice.binary.path}`,
      binarySHA256: slice.binary.sha256,
    })),
  };
}

function collectArchivePayload(entries, archiveInputs, archiveRoot) {
  const archives = [];
  for (const [archiveName, expected] of [...archiveInputs.entries()].sort((left, right) => left[0].localeCompare(right[0]))) {
    const sourcePath = path.join(archiveRoot, archiveName);
    entries.addSource(`source/ARCHIVE/${archiveName}`, sourcePath, `ARCHIVE/${archiveName}`);
    archives.push({
      path: `source/ARCHIVE/${archiveName}`,
      sizeBytes: statSync(sourcePath).size,
      sha256: expected,
    });
  }
  return archives;
}

function collectBuildToolInputs(entries, recipeLock, toolInputRoot) {
  const lockedTools = recipeLock.toolchain?.tools;
  if (!Array.isArray(lockedTools) || lockedTools.length !== 5) {
    fail('Recipe lock must bind exactly five build-tool archive inputs.');
  }
  const seen = new Set();
  const results = [];
  for (const [index, tool] of lockedTools.entries()) {
    assertString(tool.name, `build tool[${index}] name`);
    assertSafeRelativePath(tool.archiveName, `build tool[${index}] archive name`);
    if (tool.archiveName.includes('/')) fail(`Build tool archive ${tool.archiveName} must be a basename.`);
    assertDigest(tool.archiveSha256, `build tool[${index}] archive SHA-256`);
    if (seen.has(tool.archiveName)) fail(`Build tool archive ${tool.archiveName} is duplicated in the recipe lock.`);
    seen.add(tool.archiveName);
    const candidates = [
      path.join(toolInputRoot, tool.archiveName),
      path.join(toolInputRoot, 'tooling-wheels', tool.archiveName),
    ].filter((candidate) => existsSync(candidate));
    if (candidates.length !== 1) {
      fail(`Build tool archive ${tool.archiveName} must exist at exactly one approved path under --tool-input-root.`);
    }
    const sourcePath = requireRegularFile(candidates[0], `build tool archive ${tool.archiveName}`);
    const actual = sha256File(sourcePath);
    if (actual !== tool.archiveSha256) fail(`Build tool archive ${tool.archiveName} SHA-256 mismatch.`);
    assertNotStaleSHA256(actual, `build tool archive ${tool.archiveName}`);
    const destination = `source/BUILD-TOOL-INPUTS/${tool.archiveName}`;
    entries.addSource(destination, sourcePath, `build tool input ${tool.archiveName}`);
    results.push({
      name: tool.name,
      path: destination,
      sizeBytes: statSync(sourcePath).size,
      sha256: actual,
    });
  }
  return results.sort((left, right) => left.path.localeCompare(right.path));
}

function relinkingGuide(targets) {
  const lines = [
    '# CoreKiwix corresponding source and relinking material',
    '',
    'This deterministic package retains the exact source inputs, build recipe, controlled evidence, notices, framework, component archives, and libmicrohttpd object inputs for the shipped CoreKiwix build.',
    '',
    'For each thin target below, run Apple libtool with the component archives in the recorded order. The verifier in the ArkFile source tree automates this for all five targets.',
    '',
    'Binary byte identity of the rebuilt static archive is not required because Apple libtool rewrites archive index and header metadata. The supported exact proof is the ordered non-index object-member multiset plus the externally-defined symbol set.',
    '',
  ];
  for (const target of targets) {
    lines.push(`## ${target.id}`, '', '```sh');
    lines.push(`/usr/bin/libtool -static -o rebuilt.a ${target.componentArchiveOrder.map((name) => `relink/${target.id}/archives/${name}`).join(' ')}`);
    lines.push('```', '');
  }
  return `${lines.join('\n')}\n`;
}

export function createCoreKiwixPackagePlan(options) {
  assertObject(options, 'package options');
  const buildWork = requireDirectory(path.resolve(options.buildWork), 'build-work');
  const framework = requireDirectory(path.resolve(options.framework), 'CoreKiwix XCFramework');
  const recipeRoot = requireDirectory(path.resolve(options.recipeRoot), 'CoreKiwix recipe checkout');
  const toolInputRoot = requireDirectory(path.resolve(options.toolInputRoot), 'CoreKiwix build-tool input root');
  const noticesRoot = requireDirectory(path.resolve(options.notices), 'CoreKiwix curated notices');
  const evidenceRoot = requireDirectory(path.resolve(options.evidence), 'CoreKiwix evidence directory');
  const recipeLockPath = path.resolve(options.recipeLock);
  const exceptionsPath = path.resolve(options.exceptions);
  const { value: recipeLock, contents: recipeLockContents } = readCanonicalJSON(recipeLockPath, 'CoreKiwix recipe lock');
  validateRecipeLock(recipeLock, recipeLockContents);
  const toolset = tools();
  const evidence = collectEvidence(evidenceRoot);
  const exceptions = validateExceptionPolicy(exceptionsPath, evidence);
  if (evidence.manifest.product?.buildIdentity !== recipeLock.package.version) {
    fail('Evidence product build identity differs from the recipe lock package version.');
  }
  const archiveRoot = validateArchiveInputs(recipeLock, buildWork);
  const archiveInputs = collectLockedArchiveInputs(recipeLock);
  validateEvidenceSourceBindings(evidence, buildWork, archiveInputs, toolset);
  const notices = validateNotices(recipeLock, noticesRoot);
  const entries = new PackageEntries();

  const recipe = collectRecipe(entries, recipeLock, recipeLockPath, recipeRoot, toolset);
  const sourceArchives = collectArchivePayload(entries, archiveInputs, archiveRoot);
  const buildToolInputs = collectBuildToolInputs(entries, recipeLock, toolInputRoot);
  const buildEvidence = collectSourceAndBuildEvidence(
    entries,
    evidence,
    buildWork,
    { buildWork, framework, recipeRoot }
  );
  const frameworkIdentity = collectFrameworkTree(entries, framework, evidence, recipeLock);
  addTree(entries, noticesRoot, 'notices', 'CoreKiwixNativeNotices');
  for (const fileName of EVIDENCE_FILE_NAMES) {
    entries.addSource(`evidence/${fileName}`, path.join(evidenceRoot, fileName), `controlled evidence ${fileName}`);
  }
  entries.addSource(
    'evidence/CoreKiwixNativeExceptions.json',
    exceptionsPath,
    'CoreKiwixNativeExceptions.json'
  );
  const relinkTargets = collectRelinkTargets(entries, evidence, buildWork, toolset);
  entries.addData('RELINKING.md', relinkingGuide(relinkTargets), 'CoreKiwix relinking guide');

  const payloadFiles = entries.inventoryFiles();
  const evidenceFiles = EVIDENCE_FILE_NAMES.map((fileName) => ({
    path: `evidence/${fileName}`,
    sizeBytes: Buffer.byteLength(evidence.files[fileName]),
    sha256: sha256(evidence.files[fileName]),
  }));
  const inventory = {
    schemaVersion: SOURCE_PACKAGE_SCHEMA_VERSION,
    package: recipeLock.package,
    purpose: 'deterministic corresponding-source and static-relink evidence for ArkFile CoreKiwix',
    sourceDateEpoch: recipeLock.sourceDateEpoch,
    deterministicArchivePolicy: {
      format: 'ustar plus gzip',
      memberOrder: 'lexicographic portable relative path',
      owner: { uid: 0, gid: 0, uname: 'root', gname: 'root' },
      modes: ['0644', '0755'],
      gzip: 'gzip -n -9 with zero timestamp and no original filename',
      linksAndSpecialFiles: 'prohibited; safe in-root SOURCE/recipe symlinks are materialized as regular files and inventoried',
    },
    exclusions: {
      rawBuildLogs: true,
      gitMetadata: true,
      ambientEnvironment: true,
      unnormalizedCompileAndDependencyEvidence: true,
    },
    recipe,
    source: {
      root: 'source/SOURCE',
      exactArchiveInputs: sourceArchives,
      exactBuildToolInputs: buildToolInputs,
    },
    framework: frameworkIdentity,
    notices: {
      root: 'notices',
      coverageComplete: true,
      indexPath: 'notices/index.json',
      indexSHA256: sha256(notices.contents),
      fileCount: notices.files.length,
    },
    evidence: {
      validationPolicy: evidence.manifest.policy,
      fileCount: evidenceFiles.length,
      files: evidenceFiles,
      exceptionPolicy: {
        path: 'evidence/CoreKiwixNativeExceptions.json',
        exceptionCount: exceptions.policy.exceptions.length,
        sizeBytes: Buffer.byteLength(exceptions.contents),
        sha256: sha256(exceptions.contents),
        exactDeclaredAndUsedMatch: true,
      },
      thinTargetCount: evidence.manifest.thinBuilds.length,
      frameworkSliceCount: evidence.manifest.xcframework.slices.length,
    },
    normalizedBuildEvidence: {
      indexPath: 'build-evidence/NORMALIZATION.json',
      normalizedFileCount: buildEvidence.normalizedFileCount,
      compiledSourceFileCount: buildEvidence.compiledSourceFileCount,
    },
    relinkProof: {
      method: SOURCE_PACKAGE_PROOF,
      targetCount: relinkTargets.length,
      binaryByteIdentityRequired: false,
      reason: 'Apple libtool rewrites static-archive index/header metadata; the exact supported proof is ordered non-index objects plus externally-defined symbols.',
      targets: relinkTargets,
    },
    materializedSymlinks: [...entries.materializedSymlinks].sort((left, right) => left.path.localeCompare(right.path)),
    payloadFileCount: payloadFiles.length,
    payloadSetSHA256: canonicalHash(payloadFiles),
    payloadFiles,
  };
  const inventoryContents = canonicalJSON(inventory);
  scanSecretLike(inventoryContents, SOURCE_PACKAGE_INVENTORY);
  const memberPaths = [...payloadFiles.map((file) => file.path), SOURCE_PACKAGE_INVENTORY].sort();
  return {
    sourceDateEpoch: recipeLock.sourceDateEpoch,
    entries,
    inventory,
    inventoryContents,
    memberPaths,
  };
}

export function materializeCoreKiwixPackagePlan(plan, stageRoot) {
  assertObject(plan, 'CoreKiwix package plan');
  if (existsSync(stageRoot)) {
    const metadata = lstatSync(stageRoot);
    if (metadata.isSymbolicLink() || !metadata.isDirectory() || readdirSync(stageRoot).length !== 0) {
      fail('Package staging root must be a new or empty real directory.');
    }
  } else {
    mkdirSync(stageRoot, { recursive: true, mode: 0o755 });
  }
  for (const entry of [...plan.entries.entries.values()].sort((left, right) => left.path.localeCompare(right.path))) {
    const destination = path.join(stageRoot, ...entry.path.split('/'));
    mkdirSync(path.dirname(destination), { recursive: true, mode: 0o755 });
    if (existsSync(destination)) fail(`Package staging collision at ${entry.path}.`);
    if (entry.sourcePath) copyFileSync(entry.sourcePath, destination);
    else writeFileSync(destination, entry.data, { flag: 'wx', mode: entry.mode });
    chmodSync(destination, entry.mode);
    if (statSync(destination).size !== entry.sizeBytes || sha256File(destination) !== entry.sha256) {
      fail(`Package source changed while staging ${entry.path}.`);
    }
    utimesSync(destination, plan.sourceDateEpoch, plan.sourceDateEpoch);
  }
  const inventoryPath = path.join(stageRoot, SOURCE_PACKAGE_INVENTORY);
  writeFileSync(inventoryPath, plan.inventoryContents, { flag: 'wx', mode: 0o644 });
  chmodSync(inventoryPath, 0o644);
  utimesSync(inventoryPath, plan.sourceDateEpoch, plan.sourceDateEpoch);
  return { memberPaths: plan.memberPaths, inventoryPath };
}

function listRegularTree(rootPath, label) {
  const root = requireDirectory(rootPath, label);
  const files = [];
  const visit = (directory, prefix = '') => {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((left, right) => left.name.localeCompare(right.name))) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const fullPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink() || (!entry.isDirectory() && !entry.isFile())) {
        fail(`${label} contains a link or special entry ${relative}.`);
      }
      if (entry.isDirectory()) visit(fullPath, relative);
      else files.push({ path: relative, sizeBytes: statSync(fullPath).size, sha256: sha256File(fullPath) });
    }
  };
  visit(root);
  return { root, files };
}

function payloadEntryMap(inventory, tarEntries, inventoryContents) {
  if (!Array.isArray(inventory.payloadFiles) || inventory.payloadFiles.length === 0) {
    fail('Source-package payload inventory is empty or malformed.');
  }
  const payload = new Map();
  for (const [index, entry] of inventory.payloadFiles.entries()) {
    assertExactKeys(entry, ['path', 'mode', 'sizeBytes', 'sha256', 'origin'], `payloadFiles[${index}]`);
    assertSafeRelativePath(entry.path, `payloadFiles[${index}].path`);
    if (![0o644, 0o755].includes(entry.mode)) fail(`payloadFiles[${index}].mode is unsupported.`);
    assertInteger(entry.sizeBytes, `payloadFiles[${index}].sizeBytes`);
    assertDigest(entry.sha256, `payloadFiles[${index}].sha256`);
    assertString(entry.origin, `payloadFiles[${index}].origin`);
    assertNotStaleSHA256(entry.sha256, `source package payload ${entry.path}`);
    if (payload.has(entry.path)) fail(`Source-package payload inventory duplicates ${entry.path}.`);
    payload.set(entry.path, entry);
  }
  if (
    inventory.payloadFileCount !== payload.size
    || inventory.payloadFiles.length !== payload.size
    || inventory.payloadSetSHA256 !== canonicalHash(inventory.payloadFiles)
  ) {
    fail('Source-package payload inventory count or ordered digest is invalid.');
  }
  const expectedPaths = [...payload.keys(), SOURCE_PACKAGE_INVENTORY].sort();
  const actualPaths = tarEntries.map((entry) => entry.path);
  if (JSON.stringify(actualPaths) !== JSON.stringify(expectedPaths)) {
    fail('Source package has missing, extra, duplicated, renamed, or non-canonically ordered members.');
  }
  const tarByPath = new Map(tarEntries.map((entry) => [entry.path, entry]));
  for (const [relative, descriptor] of payload) {
    const actual = tarByPath.get(relative);
    if (
      !actual
      || actual.mode !== descriptor.mode
      || actual.sizeBytes !== descriptor.sizeBytes
      || actual.sha256 !== descriptor.sha256
    ) {
      fail(`Source-package payload ${relative} differs from its inventory descriptor.`);
    }
  }
  const inventoryEntry = tarByPath.get(SOURCE_PACKAGE_INVENTORY);
  if (
    !inventoryEntry
    || inventoryEntry.mode !== 0o644
    || inventoryEntry.sizeBytes !== Buffer.byteLength(inventoryContents)
    || inventoryEntry.sha256 !== sha256(inventoryContents)
  ) {
    fail('Source-package inventory member bytes or metadata are invalid.');
  }
  return { payload, expectedPaths };
}

function requirePayloadFile(extractedRoot, payload, relative, label) {
  const descriptor = payload.get(relative);
  if (!descriptor) fail(`Source-package inventory is missing ${label}: ${relative}`);
  const filePath = path.join(extractedRoot, ...relative.split('/'));
  requireRegularFile(filePath, `packaged ${label}`);
  if (statSync(filePath).size !== descriptor.sizeBytes || sha256File(filePath) !== descriptor.sha256) {
    fail(`Packaged ${label} differs from its inventory descriptor.`);
  }
  return { descriptor, filePath };
}

function bindCheckedFile(extractedRoot, payload, relative, checkedPath, label) {
  const packaged = requirePayloadFile(extractedRoot, payload, relative, label);
  requireRegularFile(checkedPath, `checked ${label}`);
  if (
    statSync(checkedPath).size !== packaged.descriptor.sizeBytes
    || sha256File(checkedPath) !== packaged.descriptor.sha256
  ) {
    fail(`Packaged ${label} differs from the checked release input bytes.`);
  }
  return packaged;
}

function payloadPathsWithPrefix(payload, prefix) {
  return [...payload.keys()].filter((item) => item.startsWith(prefix)).sort();
}

function validatePortableInventoryIdentity(inventory, recipeLock, evidence, exceptions, notices) {
  assertExactKeys(inventory, [
    'schemaVersion', 'package', 'purpose', 'sourceDateEpoch', 'deterministicArchivePolicy',
    'exclusions', 'recipe', 'source', 'framework', 'notices', 'evidence',
    'normalizedBuildEvidence', 'relinkProof', 'materializedSymlinks',
    'payloadFileCount', 'payloadSetSHA256', 'payloadFiles',
  ], 'source-package inventory');
  if (
    inventory.schemaVersion !== SOURCE_PACKAGE_SCHEMA_VERSION
    || inventory.purpose !== 'deterministic corresponding-source and static-relink evidence for ArkFile CoreKiwix'
    || JSON.stringify(inventory.package) !== JSON.stringify(recipeLock.package)
    || inventory.sourceDateEpoch !== recipeLock.sourceDateEpoch
  ) {
    fail('Source-package identity, purpose, or checked source epoch is invalid.');
  }
  const deterministicPolicy = {
    format: 'ustar plus gzip',
    memberOrder: 'lexicographic portable relative path',
    owner: { uid: 0, gid: 0, uname: 'root', gname: 'root' },
    modes: ['0644', '0755'],
    gzip: 'gzip -n -9 with zero timestamp and no original filename',
    linksAndSpecialFiles: 'prohibited; safe in-root SOURCE/recipe symlinks are materialized as regular files and inventoried',
  };
  if (JSON.stringify(inventory.deterministicArchivePolicy) !== JSON.stringify(deterministicPolicy)) {
    fail('Source-package deterministic archive policy is unsupported.');
  }
  if (JSON.stringify(inventory.exclusions) !== JSON.stringify({
    rawBuildLogs: true,
    gitMetadata: true,
    ambientEnvironment: true,
    unnormalizedCompileAndDependencyEvidence: true,
  })) {
    fail('Source-package exclusions do not fail closed.');
  }
  if (
    inventory.evidence?.validationPolicy !== evidence.manifest.policy
    || inventory.evidence?.fileCount !== EVIDENCE_FILE_NAMES.length
    || inventory.evidence?.thinTargetCount !== evidence.manifest.thinBuilds.length
    || inventory.evidence?.frameworkSliceCount !== evidence.manifest.xcframework.slices.length
    || inventory.evidence?.exceptionPolicy?.exceptionCount !== exceptions.policy.exceptions.length
    || inventory.evidence?.exceptionPolicy?.exactDeclaredAndUsedMatch !== true
  ) {
    fail('Source-package evidence coverage differs from checked evidence and policy.');
  }
  if (
    inventory.notices?.coverageComplete !== true
    || inventory.notices?.indexPath !== 'notices/index.json'
    || inventory.notices?.indexSHA256 !== recipeLock.noticeIndex.sha256
    || inventory.notices?.indexSHA256 !== sha256(notices.contents)
    || inventory.notices?.fileCount !== notices.files.length
  ) {
    fail('Source-package notice coverage differs from the checked recipe and notices.');
  }
  if (evidence.manifest.product?.buildIdentity !== recipeLock.package.version) {
    fail('Checked evidence product identity differs from the checked recipe lock.');
  }
}

function validatePortablePayloadPolicy(payload) {
  const allowed = /^(?:RELINKING\.md|build-evidence\/(?:NORMALIZATION\.json|compiled-sources\/.+|normalized\/.+)|evidence\/.+|framework\/CoreKiwix\.xcframework\/.+|notices\/.+|recipe\/.+|relink\/.+|source\/(?:ARCHIVE|BUILD-TOOL-INPUTS|SOURCE)\/.+)$/u;
  const prohibitedRawTree = /(?:^|\/)(?:LOGS?|\.git)(?:\/|$)|(?:^|\/)INSTALL\//u;
  for (const relative of payload.keys()) {
    if (!allowed.test(relative)) fail(`Source package contains an unsupported payload path ${relative}.`);
    if (prohibitedRawTree.test(relative)) fail(`Source package contains prohibited raw build material ${relative}.`);
  }
}

function validatePortableEvidenceAndPolicies(
  extractedRoot,
  payload,
  inventory,
  evidenceRoot,
  evidence,
  exceptionsPath,
  exceptions,
  recipeLockPath,
  recipeLockContents,
  noticesRoot,
  notices
) {
  const inventoryEvidence = new Map();
  if (!Array.isArray(inventory.evidence.files)) fail('Source-package evidence descriptors are malformed.');
  for (const descriptor of inventory.evidence.files) {
    assertExactKeys(descriptor, ['path', 'sizeBytes', 'sha256'], 'source-package evidence descriptor');
    assertSafeRelativePath(descriptor.path, 'source-package evidence descriptor path');
    assertInteger(descriptor.sizeBytes, `${descriptor.path} size`);
    assertDigest(descriptor.sha256, `${descriptor.path} SHA-256`);
    if (inventoryEvidence.has(descriptor.path)) fail(`Duplicate source-package evidence descriptor ${descriptor.path}.`);
    inventoryEvidence.set(descriptor.path, descriptor);
  }
  const expectedEvidencePaths = EVIDENCE_FILE_NAMES.map((name) => `evidence/${name}`).sort();
  if (JSON.stringify([...inventoryEvidence.keys()].sort()) !== JSON.stringify(expectedEvidencePaths)) {
    fail('Source-package evidence descriptor set is not exact.');
  }
  for (const fileName of EVIDENCE_FILE_NAMES) {
    const relative = `evidence/${fileName}`;
    const packaged = bindCheckedFile(
      extractedRoot,
      payload,
      relative,
      path.join(evidenceRoot, fileName),
      `native evidence ${fileName}`
    );
    const descriptor = inventoryEvidence.get(relative);
    if (
      descriptor.sizeBytes !== packaged.descriptor.sizeBytes
      || descriptor.sha256 !== packaged.descriptor.sha256
    ) {
      fail(`Source-package evidence descriptor differs for ${fileName}.`);
    }
  }
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'evidence/')) !== JSON.stringify([
    ...expectedEvidencePaths,
    'evidence/CoreKiwixNativeExceptions.json',
  ].sort())) {
    fail('Source-package evidence directory contains missing or unbound files.');
  }
  const packagedExceptions = bindCheckedFile(
    extractedRoot,
    payload,
    'evidence/CoreKiwixNativeExceptions.json',
    exceptionsPath,
    'native exception policy'
  );
  if (
    inventory.evidence.exceptionPolicy.path !== 'evidence/CoreKiwixNativeExceptions.json'
    || inventory.evidence.exceptionPolicy.sizeBytes !== packagedExceptions.descriptor.sizeBytes
    || inventory.evidence.exceptionPolicy.sha256 !== packagedExceptions.descriptor.sha256
    || inventory.evidence.exceptionPolicy.sha256 !== sha256(exceptions.contents)
  ) {
    fail('Source-package exception policy descriptor differs from checked policy.');
  }
  bindCheckedFile(
    extractedRoot,
    payload,
    'recipe/CoreKiwixNativeBuildRecipe.lock.json',
    recipeLockPath,
    'native build recipe lock'
  );
  const packagedRecipeLock = readFileSync(
    path.join(extractedRoot, 'recipe/CoreKiwixNativeBuildRecipe.lock.json'),
    'utf8'
  );
  if (packagedRecipeLock !== recipeLockContents) fail('Packaged recipe lock text differs from checked canonical bytes.');

  const checkedNoticeSpecs = notices.files.map((relative) => {
    const checkedPath = path.join(noticesRoot, ...relative.split('/'));
    return { relative, checkedPath };
  }).sort((left, right) => left.relative.localeCompare(right.relative));
  const expectedNoticePayloads = checkedNoticeSpecs.map((item) => `notices/${item.relative}`).sort();
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'notices/')) !== JSON.stringify(expectedNoticePayloads)) {
    fail('Source-package notice set differs from the checked curated notice set.');
  }
  for (const notice of checkedNoticeSpecs) {
    bindCheckedFile(extractedRoot, payload, `notices/${notice.relative}`, notice.checkedPath, `native notice ${notice.relative}`);
  }
}

function combinations(values, count, start = 0, prefix = [], output = []) {
  if (prefix.length === count) {
    output.push([...prefix]);
    return output;
  }
  for (let index = start; index <= values.length - (count - prefix.length); index += 1) {
    prefix.push(values[index]);
    combinations(values, count, index + 1, prefix, output);
    prefix.pop();
    if (output.length > 4096) fail('Recipe untracked-file reconstruction has too many candidate combinations.');
  }
  return output;
}

function verifyPackagedRecipeTree(extractedRoot, inventory, recipeLock, diffPath, toolset) {
  const workspace = mkdtempSync(path.join(os.tmpdir(), 'arkfile-corekiwix-recipe-tree-'));
  try {
    const reconstructed = path.join(workspace, 'recipe');
    cpSync(path.join(extractedRoot, 'recipe/source'), reconstructed, {
      recursive: true,
      dereference: false,
      preserveTimestamps: true,
    });
    const diff = readFileSync(diffPath, 'utf8');
    const changedPaths = new Set();
    for (const match of diff.matchAll(/^diff --git a\/([^\n]+) b\/([^\n]+)$/gmu)) {
      if (match[1] !== match[2]) fail('Packaged recipe diff contains a rename that portable tree reconstruction does not support.');
      assertSafeRelativePath(match[1], 'tracked recipe diff path');
      changedPaths.add(match[1]);
    }
    if (changedPaths.size === 0) fail('Packaged tracked recipe diff contains no bound paths.');
    runText(toolset.git, ['apply', '--reverse', '--binary', '--whitespace=nowarn', diffPath], 'tracked recipe diff reversal', {
      cwd: reconstructed,
    });
    const declaredCandidates = [...new Set([
      ...recipeLock.buildRecipe.modifiedFiles.map((file) => file.path),
      ...recipeLock.buildRecipe.appliedPatchFiles.map((file) => file.path),
    ])].filter((relative) => !changedPaths.has(relative)).sort();
    const untrackedCount = inventory.recipe.untrackedCuratedFileCount;
    if (
      !Number.isSafeInteger(untrackedCount)
      || untrackedCount < 0
      || untrackedCount > declaredCandidates.length
    ) {
      fail('Source-package untracked recipe count cannot be reconstructed from the checked lock.');
    }
    for (const relative of declaredCandidates) {
      requireRegularFile(path.join(reconstructed, ...relative.split('/')), `candidate untracked recipe file ${relative}`);
    }
    runText(toolset.git, ['init', '-q', reconstructed], 'temporary recipe Git initialization');
    const matches = [];
    for (const omitted of combinations(declaredCandidates, untrackedCount)) {
      rmSync(path.join(reconstructed, '.git/index'), { force: true });
      runText(toolset.git, ['-C', reconstructed, 'add', '-f', '--all', '--', '.'], 'temporary recipe tree staging');
      for (const relative of omitted) {
        runText(
          toolset.git,
          ['-C', reconstructed, 'update-index', '--force-remove', '--', relative],
          `temporary recipe tree omission ${relative}`
        );
      }
      const tree = runText(toolset.git, ['-C', reconstructed, 'write-tree'], 'reconstructed recipe tree').trim();
      if (tree === recipeLock.buildRecipe.source.tree) matches.push(omitted);
    }
    if (matches.length !== 1) {
      fail('Packaged recipe/source bytes do not reconstruct exactly one checked recipe Git tree.');
    }
    if (
      inventory.recipe.tree !== recipeLock.buildRecipe.source.tree
      || inventory.recipe.commit !== recipeLock.buildRecipe.source.commit
    ) {
      fail('Source-package recipe commit/tree descriptor differs from the checked lock.');
    }
    return { tree: recipeLock.buildRecipe.source.tree, omittedUntrackedPaths: matches[0] };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function validatePortableRecipeAndInputs(extractedRoot, payload, inventory, recipeLock, evidence, toolset) {
  const expectedRecipeIdentity = {
    commit: recipeLock.buildRecipe.source.commit,
    tree: recipeLock.buildRecipe.source.tree,
    release: recipeLock.buildRecipe.source.release,
    trackedFileCount: inventory.recipe?.trackedFileCount,
    untrackedCuratedFileCount: inventory.recipe?.untrackedCuratedFileCount,
    trackedWorkingTreeDiff: {
      path: 'recipe/tracked-working-tree.diff',
      sha256: recipeLock.buildRecipe.trackedWorkingTreeDiff.sha256,
    },
    fullRecipeRoot: 'recipe/source',
    modifiedFilesRoot: 'recipe/modified-files',
  };
  if (JSON.stringify(inventory.recipe) !== JSON.stringify(expectedRecipeIdentity)) {
    fail('Source-package recipe identity differs from the checked recipe lock.');
  }
  const recipeSourcePaths = payloadPathsWithPrefix(payload, 'recipe/source/');
  if (
    !Number.isSafeInteger(inventory.recipe.trackedFileCount)
    || !Number.isSafeInteger(inventory.recipe.untrackedCuratedFileCount)
    || recipeSourcePaths.length !== inventory.recipe.trackedFileCount + inventory.recipe.untrackedCuratedFileCount
  ) {
    fail('Source-package recipe source-file count is invalid.');
  }
  const diff = requirePayloadFile(extractedRoot, payload, 'recipe/tracked-working-tree.diff', 'tracked recipe diff');
  const diffContents = readFileSync(diff.filePath, 'utf8');
  if (sha256(diffContents) !== recipeLock.buildRecipe.trackedWorkingTreeDiff.sha256) {
    fail('Packaged tracked recipe diff differs from the checked recipe lock.');
  }
  scanSecretLike(diffContents, 'packaged tracked recipe diff');
  verifyPackagedRecipeTree(extractedRoot, inventory, recipeLock, diff.filePath, toolset);

  const modifiedPaths = [];
  for (const [index, file] of recipeLock.buildRecipe.modifiedFiles.entries()) {
    assertSafeRelativePath(file.path, `modified recipe file[${index}] path`);
    assertDigest(file.sha256, `modified recipe file[${index}] SHA-256`);
    for (const prefix of ['recipe/source/', 'recipe/modified-files/']) {
      const packaged = requirePayloadFile(extractedRoot, payload, `${prefix}${file.path}`, `modified recipe file ${file.path}`);
      if (packaged.descriptor.sha256 !== file.sha256) fail(`Modified recipe file ${file.path} differs from the checked lock.`);
    }
    modifiedPaths.push(`recipe/modified-files/${file.path}`);
  }
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'recipe/modified-files/')) !== JSON.stringify(modifiedPaths.sort())) {
    fail('Source-package modified recipe file set is not exact.');
  }
  for (const [index, file] of recipeLock.buildRecipe.appliedPatchFiles.entries()) {
    assertSafeRelativePath(file.path, `applied recipe patch[${index}] path`);
    assertDigest(file.sha256, `applied recipe patch[${index}] SHA-256`);
    const packaged = requirePayloadFile(extractedRoot, payload, `recipe/source/${file.path}`, `applied recipe patch ${file.path}`);
    if (packaged.descriptor.sha256 !== file.sha256) fail(`Applied recipe patch ${file.path} differs from the checked lock.`);
  }

  const lockedArchives = collectLockedArchiveInputs(recipeLock);
  const expectedArchivePaths = [...lockedArchives.keys()].sort().map((name) => `source/ARCHIVE/${name}`);
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'source/ARCHIVE/')) !== JSON.stringify(expectedArchivePaths)) {
    fail('Source-package exact archive-input set differs from the checked recipe lock.');
  }
  const inventoryArchives = new Map();
  for (const [index, descriptor] of inventory.source.exactArchiveInputs.entries()) {
    assertExactKeys(descriptor, ['path', 'sizeBytes', 'sha256'], `source.exactArchiveInputs[${index}]`);
    if (inventoryArchives.has(descriptor.path)) fail(`Duplicate exact source archive ${descriptor.path}.`);
    inventoryArchives.set(descriptor.path, descriptor);
  }
  if (JSON.stringify([...inventoryArchives.keys()].sort()) !== JSON.stringify(expectedArchivePaths)) {
    fail('Source-package archive descriptors differ from the checked recipe lock.');
  }
  for (const [archiveName, expectedDigest] of lockedArchives) {
    const relative = `source/ARCHIVE/${archiveName}`;
    const packaged = requirePayloadFile(extractedRoot, payload, relative, `source archive ${archiveName}`);
    const descriptor = inventoryArchives.get(relative);
    if (
      packaged.descriptor.sha256 !== expectedDigest
      || descriptor.sha256 !== expectedDigest
      || descriptor.sizeBytes !== packaged.descriptor.sizeBytes
    ) {
      fail(`Source archive ${archiveName} differs from the checked recipe lock.`);
    }
  }

  const lockedTools = recipeLock.toolchain?.tools;
  if (!Array.isArray(lockedTools) || lockedTools.length !== 5) fail('Checked recipe lock must bind exactly five build-tool inputs.');
  const toolByPath = new Map();
  for (const [index, tool] of lockedTools.entries()) {
    assertSafeRelativePath(tool.archiveName, `build tool[${index}] archive name`);
    assertDigest(tool.archiveSha256, `build tool[${index}] SHA-256`);
    const relative = `source/BUILD-TOOL-INPUTS/${tool.archiveName}`;
    if (toolByPath.has(relative)) fail(`Duplicate checked build-tool archive ${tool.archiveName}.`);
    toolByPath.set(relative, tool);
  }
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'source/BUILD-TOOL-INPUTS/')) !== JSON.stringify([...toolByPath.keys()].sort())) {
    fail('Source-package build-tool input set differs from the checked recipe lock.');
  }
  const inventoryTools = new Map(inventory.source.exactBuildToolInputs.map((item) => [item.path, item]));
  if (inventoryTools.size !== toolByPath.size || JSON.stringify([...inventoryTools.keys()].sort()) !== JSON.stringify([...toolByPath.keys()].sort())) {
    fail('Source-package build-tool descriptors are missing, duplicated, or unexpected.');
  }
  for (const [relative, tool] of toolByPath) {
    const packaged = requirePayloadFile(extractedRoot, payload, relative, `build-tool input ${tool.name}`);
    const descriptor = inventoryTools.get(relative);
    if (
      descriptor.name !== tool.name
      || descriptor.sha256 !== tool.archiveSha256
      || packaged.descriptor.sha256 !== tool.archiveSha256
      || descriptor.sizeBytes !== packaged.descriptor.sizeBytes
    ) {
      fail(`Build-tool input ${tool.name} differs from the checked recipe lock.`);
    }
  }

  const evidenceArchives = new Map();
  for (const [index, sourceInput] of evidence.sourceLock.sourceInputs.entries()) {
    assertSafeRelativePath(sourceInput.path, `source-lock input[${index}] path`);
    if (!sourceInput.path.startsWith('ARCHIVE/')) fail(`${sourceInput.path} is not a portable ARCHIVE source input.`);
    const relative = `source/${sourceInput.path}`;
    if (evidenceArchives.has(relative)) fail(`Duplicate source-lock archive input ${sourceInput.path}.`);
    evidenceArchives.set(relative, sourceInput);
    const packaged = requirePayloadFile(extractedRoot, payload, relative, `source-lock input ${sourceInput.path}`);
    if (
      packaged.descriptor.sizeBytes !== sourceInput.sizeBytes
      || packaged.descriptor.sha256 !== sourceInput.sha256
    ) {
      fail(`Source-lock input ${sourceInput.path} differs from packaged bytes.`);
    }
  }
  if (JSON.stringify([...evidenceArchives.keys()].sort()) !== JSON.stringify(expectedArchivePaths)) {
    fail('Checked source lock and recipe lock bind different source archive sets.');
  }
}

function validatePortableSourceBindings(extractedRoot, payload, inventory, evidence) {
  if (inventory.source?.root !== 'source/SOURCE') fail('Source-package source root is unsupported.');
  const compiled = new Map();
  for (const component of evidence.sourceLock.components) {
    for (const license of component.licenses) {
      const relative = `source/${license.path}`;
      const packaged = requirePayloadFile(extractedRoot, payload, relative, `${component.id} license ${license.path}`);
      if (packaged.descriptor.sizeBytes !== license.sizeBytes || packaged.descriptor.sha256 !== license.sha256) {
        fail(`${component.id} license ${license.path} differs from checked source evidence.`);
      }
    }
    for (const source of component.sourceIdentity.compiledSourceFiles) {
      const previous = compiled.get(source.path);
      if (previous && (previous.sha256 !== source.sha256 || previous.sizeBytes !== source.sizeBytes)) {
        fail(`Compiled source ${source.path} has conflicting checked evidence.`);
      }
      compiled.set(source.path, source);
      const evidenceFile = requirePayloadFile(
        extractedRoot,
        payload,
        `build-evidence/compiled-sources/${source.path}`,
        `compiled-source evidence ${source.path}`
      );
      const sourceFile = source.path.startsWith('SOURCE/')
        ? requirePayloadFile(extractedRoot, payload, `source/${source.path}`, `compiled source ${source.path}`)
        : null;
      if (!sourceFile && !source.path.startsWith('BUILD_')) {
        fail(`Compiled source ${source.path} is outside portable SOURCE/ or generated BUILD_ evidence.`);
      }
      if (
        (sourceFile && (
          sourceFile.descriptor.sizeBytes !== source.sizeBytes
          || sourceFile.descriptor.sha256 !== source.sha256
        ))
        || evidenceFile.descriptor.sizeBytes !== source.sizeBytes
        || evidenceFile.descriptor.sha256 !== source.sha256
      ) {
        fail(`Compiled source ${source.path} differs from checked source evidence.`);
      }
    }
  }
  const expectedCompiledPaths = [...compiled.keys()].sort().map((item) => `build-evidence/compiled-sources/${item}`);
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'build-evidence/compiled-sources/')) !== JSON.stringify(expectedCompiledPaths)) {
    fail('Source-package compiled-source evidence set is not exact.');
  }
  if (inventory.normalizedBuildEvidence?.compiledSourceFileCount !== compiled.size) {
    fail('Source-package compiled-source count differs from checked evidence.');
  }
}

function validatePortableNormalizedEvidence(extractedRoot, payload, inventory, evidence) {
  if (inventory.normalizedBuildEvidence?.indexPath !== 'build-evidence/NORMALIZATION.json') {
    fail('Source-package normalized build-evidence index path is unsupported.');
  }
  const indexPath = requirePayloadFile(
    extractedRoot,
    payload,
    inventory.normalizedBuildEvidence.indexPath,
    'normalized build-evidence index'
  ).filePath;
  const { value: index } = readCanonicalJSON(indexPath, 'normalized build-evidence index');
  assertExactKeys(index, [
    'schemaVersion', 'policy', 'pathNormalization', 'normalizedFileCount',
    'normalizedFiles', 'compiledSourceFileCount',
  ], 'normalized build-evidence index');
  if (
    index.schemaVersion !== 1
    || index.policy !== 'selected compile_commands.json and dependency files only; LOGS, INSTALL, .git, and ambient environment are excluded'
    || JSON.stringify(index.pathNormalization) !== JSON.stringify({
      buildWork: '<BUILD_WORK>',
      framework: '<FRAMEWORK>',
      recipeRoot: '<RECIPE_ROOT>',
      xcode: '<XCODE>',
      commandLineTools: '<COMMAND_LINE_TOOLS>',
      stableSystemRoots: '<SYSTEM>',
    })
    || index.normalizedFileCount !== inventory.normalizedBuildEvidence.normalizedFileCount
    || index.compiledSourceFileCount !== inventory.normalizedBuildEvidence.compiledSourceFileCount
    || !Array.isArray(index.normalizedFiles)
    || index.normalizedFiles.length !== index.normalizedFileCount
  ) {
    fail('Normalized build-evidence index policy or counts are invalid.');
  }
  const componentEvidence = evidence.manifest.thinBuilds.flatMap((thin) => thin.componentEvidence);
  const allowedBuildRoots = new Set(componentEvidence.map((component) => component.buildPath));
  const requiredBuildRoots = new Set(componentEvidence
    .filter((component) => component.compileRecords.count > 0 || component.dependencyRecords.count > 0)
    .map((component) => component.buildPath));
  const representedBuildRoots = new Set();
  const normalizedPaths = [];
  const seenSourcePaths = new Set();
  for (const [recordIndex, record] of index.normalizedFiles.entries()) {
    assertExactKeys(record, [
      'sourcePath', 'packagedPath', 'sourceSizeBytes', 'sourceSHA256',
      'normalizedSizeBytes', 'normalizedSHA256',
    ], `normalizedFiles[${recordIndex}]`);
    assertSafeRelativePath(record.sourcePath, `normalizedFiles[${recordIndex}].sourcePath`);
    assertSafeRelativePath(record.packagedPath, `normalizedFiles[${recordIndex}].packagedPath`);
    assertInteger(record.sourceSizeBytes, `normalizedFiles[${recordIndex}].sourceSizeBytes`);
    assertDigest(record.sourceSHA256, `normalizedFiles[${recordIndex}].sourceSHA256`);
    assertInteger(record.normalizedSizeBytes, `normalizedFiles[${recordIndex}].normalizedSizeBytes`);
    assertDigest(record.normalizedSHA256, `normalizedFiles[${recordIndex}].normalizedSHA256`);
    if (record.packagedPath !== `build-evidence/normalized/${record.sourcePath}`) {
      fail(`Normalized build-evidence path does not correspond to ${record.sourcePath}.`);
    }
    if (seenSourcePaths.has(record.sourcePath)) fail(`Normalized source path ${record.sourcePath} is duplicated.`);
    seenSourcePaths.add(record.sourcePath);
    const buildRoot = [...allowedBuildRoots].find((candidate) => (
      record.sourcePath === candidate || record.sourcePath.startsWith(`${candidate}/`)
    ));
    if (!buildRoot) fail(`Normalized build evidence ${record.sourcePath} is outside checked component build paths.`);
    representedBuildRoots.add(buildRoot);
    const packaged = requirePayloadFile(extractedRoot, payload, record.packagedPath, `normalized build evidence ${record.sourcePath}`);
    if (
      packaged.descriptor.sizeBytes !== record.normalizedSizeBytes
      || packaged.descriptor.sha256 !== record.normalizedSHA256
    ) {
      fail(`Normalized build evidence ${record.sourcePath} differs from its index.`);
    }
    const contents = readFileSync(packaged.filePath, 'utf8');
    if (contents.includes('\0')) fail(`Normalized build evidence ${record.sourcePath} contains binary material.`);
    if (HOST_PATH_PATTERN.test(contents)) fail(`Normalized build evidence ${record.sourcePath} retains a host path.`);
    scanSecretLike(contents, `normalized build evidence ${record.sourcePath}`);
    normalizedPaths.push(record.packagedPath);
  }
  if ([...requiredBuildRoots].some((buildRoot) => !representedBuildRoots.has(buildRoot))) {
    fail('Normalized build evidence does not represent every checked component build path.');
  }
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'build-evidence/normalized/')) !== JSON.stringify(normalizedPaths.sort())) {
    fail('Source-package normalized build-evidence file set is not exact.');
  }
  // sourceSizeBytes/sourceSHA256 describe the pre-normalization private build
  // files and intentionally cannot be recomputed by this portable verifier.
}

function validatePortableFramework(extractedRoot, payload, inventory, frameworkRoot, evidence, recipeLock, toolset) {
  const installed = listRegularTree(frameworkRoot, 'checked CoreKiwix XCFramework');
  if (
    inventory.framework?.root !== 'framework/CoreKiwix.xcframework'
    || inventory.framework?.fileCount !== installed.files.length
    || inventory.framework?.fileCount !== evidence.manifest.xcframework.tree.fileCount
    || inventory.framework?.treeSHA256 !== canonicalHash(installed.files)
    || inventory.framework?.treeSHA256 !== evidence.manifest.xcframework.tree.sha256
    || JSON.stringify([...recipeLock.expectedXcframeworkSlices].sort()) !== JSON.stringify(EXPECTED_FRAMEWORK_SLICES)
  ) {
    fail('Installed XCFramework tree differs from inventory, evidence, or recipe lock.');
  }
  const expectedPayloadPaths = installed.files.map((file) => `framework/CoreKiwix.xcframework/${file.path}`).sort();
  if (JSON.stringify(payloadPathsWithPrefix(payload, 'framework/CoreKiwix.xcframework/')) !== JSON.stringify(expectedPayloadPaths)) {
    fail('Packaged XCFramework file set differs from the installed framework.');
  }
  for (const file of installed.files) {
    const packaged = requirePayloadFile(
      extractedRoot,
      payload,
      `framework/CoreKiwix.xcframework/${file.path}`,
      `XCFramework file ${file.path}`
    );
    if (packaged.descriptor.sizeBytes !== file.sizeBytes || packaged.descriptor.sha256 !== file.sha256) {
      fail(`Packaged XCFramework file ${file.path} differs from installed bytes.`);
    }
  }
  const inventorySlices = new Map(inventory.framework.slices.map((slice) => [slice.identifier, slice]));
  const evidenceSlices = new Map(evidence.manifest.xcframework.slices.map((slice) => [slice.identifier, slice]));
  if (
    inventorySlices.size !== EXPECTED_FRAMEWORK_SLICES.length
    || evidenceSlices.size !== EXPECTED_FRAMEWORK_SLICES.length
    || EXPECTED_FRAMEWORK_SLICES.some((identifier) => !inventorySlices.has(identifier) || !evidenceSlices.has(identifier))
  ) {
    fail('Source-package XCFramework slice set is incomplete or duplicated.');
  }
  for (const identifier of EXPECTED_FRAMEWORK_SLICES) {
    const inventorySlice = inventorySlices.get(identifier);
    const evidenceSlice = evidenceSlices.get(identifier);
    const expectedBinaryPath = `framework/CoreKiwix.xcframework/${evidenceSlice.binary.path}`;
    if (
      inventorySlice.binaryPath !== expectedBinaryPath
      || inventorySlice.binarySHA256 !== evidenceSlice.binary.sha256
      || JSON.stringify(inventorySlice.architectures) !== JSON.stringify(evidenceSlice.architectures)
    ) {
      fail(`${identifier} packaged slice identity differs from checked evidence.`);
    }
    const binary = requirePayloadFile(extractedRoot, payload, expectedBinaryPath, `${identifier} framework binary`);
    const installedPath = path.join(frameworkRoot, ...evidenceSlice.binary.path.split('/'));
    if (
      binary.descriptor.sha256 !== evidenceSlice.binary.sha256
      || binary.descriptor.sizeBytes !== evidenceSlice.binary.sizeBytes
      || JSON.stringify(architectures(toolset, installedPath, `${identifier} installed framework binary`))
        !== JSON.stringify([...evidenceSlice.architectures].sort())
    ) {
      fail(`${identifier} installed framework binary differs from checked evidence.`);
    }
    assertNotStaleSHA256(binary.descriptor.sha256, `${identifier} framework binary`);
  }
}

function compareInventoryArchiveToEvidence(inventoryArchive, evidenceArchive, label) {
  const pairs = [
    ['sizeBytes', 'sizeBytes'],
    ['sha256', 'sha256'],
    ['archiveMemberCount', 'archiveMemberCount'],
    ['archiveMemberSetSHA256', 'orderedArchiveMembersSHA256'],
    ['objectMemberCount', 'objectMemberCount'],
    ['orderedObjectMemberSetSHA256', 'orderedObjectMembersSHA256'],
    ['definedSymbolCount', 'definedSymbolCount'],
    ['definedSymbolSetSHA256', 'definedSymbolSetSHA256'],
  ];
  for (const [inventoryKey, evidenceKey] of pairs) {
    if (inventoryArchive[inventoryKey] !== evidenceArchive[evidenceKey]) {
      fail(`${label} ${inventoryKey} differs from checked build evidence.`);
    }
  }
}

function validatePortableRelinkBindings(extractedRoot, inventory, evidence, frameworkRoot, toolset) {
  if (
    inventory.relinkProof?.method !== SOURCE_PACKAGE_PROOF
    || inventory.relinkProof?.targetCount !== EXPECTED_TARGETS.length
    || inventory.relinkProof?.binaryByteIdentityRequired !== false
    || !Array.isArray(inventory.relinkProof?.targets)
    || inventory.relinkProof.targets.length !== EXPECTED_TARGETS.length
  ) {
    fail('Source-package five-target relink policy is incomplete or unsupported.');
  }
  const targets = new Map();
  for (const target of inventory.relinkProof.targets) {
    if (targets.has(target.id)) fail(`Duplicate relink target ${target.id}.`);
    targets.set(target.id, target);
  }
  for (const thin of evidence.manifest.thinBuilds) {
    const target = targets.get(thin.id);
    if (!target || target.architecture !== thin.architecture || target.platform !== thin.platform) {
      fail(`${thin.id} relink target identity differs from checked evidence.`);
    }
    if (
      target.referenceMergedArchive.path !== `relink/${thin.id}/reference/merged.a`
      || target.componentArchiveOrder.join('\0') !== thin.mergedArchive.relinkProof.componentArchiveOrder.join('\0')
      || target.relinkProof?.method !== SOURCE_PACKAGE_PROOF
      || target.relinkProof?.exactOrderedObjectMemberMultisetRequired !== true
      || target.relinkProof?.exactDefinedSymbolSetRequired !== true
    ) {
      fail(`${thin.id} relink recipe differs from checked evidence.`);
    }
    compareInventoryArchiveToEvidence(target.referenceMergedArchive, thin.mergedArchive, `${thin.id} reference archive`);
    const targetArchives = new Map(target.componentArchives.map((archive) => [archive.name, archive]));
    const evidenceArchives = new Map(thin.componentArchives.map((archive) => [archive.archive, archive]));
    if (
      targetArchives.size !== COMPONENT_ARCHIVES.length
      || evidenceArchives.size !== COMPONENT_ARCHIVES.length
      || COMPONENT_ARCHIVES.some((name) => !targetArchives.has(name) || !evidenceArchives.has(name))
    ) {
      fail(`${thin.id} component archive set is incomplete or duplicated.`);
    }
    for (const name of COMPONENT_ARCHIVES) {
      const packaged = targetArchives.get(name);
      if (packaged.path !== `relink/${thin.id}/archives/${name}`) fail(`${thin.id} ${name} path is unsupported.`);
      compareInventoryArchiveToEvidence(packaged, evidenceArchives.get(name), `${thin.id} ${name}`);
      assertNotStaleSHA256(packaged.sha256, `${thin.id} ${name}`);
    }
  }

  const deviceTarget = targets.get('ios-device-arm64');
  const referencePath = path.join(extractedRoot, ...deviceTarget.referenceMergedArchive.path.split('/'));
  const referenceMembers = archiveMembers(toolset, referencePath, 'packaged ios-device-arm64 reference archive');
  const objectMembers = evidence.objectRecords.map((record) => record.member);
  if (JSON.stringify(referenceMembers.objects) !== JSON.stringify(objectMembers)) {
    fail('Distributed iOS object map differs from the actual packaged reference archive member order.');
  }
  const deviceThin = evidence.manifest.thinBuilds.find((thin) => thin.id === 'ios-device-arm64');
  const deviceSlice = evidence.manifest.xcframework.slices.find((slice) => slice.identifier === 'ios-arm64');
  const referenceDigest = sha256File(referencePath);
  const installedDigest = sha256File(path.join(frameworkRoot, ...deviceSlice.binary.path.split('/')));
  if (
    referenceDigest !== deviceTarget.referenceMergedArchive.sha256
    || referenceDigest !== deviceThin.mergedArchive.sha256
    || referenceDigest !== deviceSlice.binary.sha256
    || referenceDigest !== installedDigest
    || referenceMembers.all.length - referenceMembers.objects.length
      !== evidence.manifest.distributedIOSCoverage.archiveMetadataMemberCount
  ) {
    fail('Distributed iOS framework, relink reference, object map, and archive metadata are not one exact identity.');
  }
}

function validateSecretScanPolicy(policy, archivePath, archiveSHA256, tarEntries, recipeLock) {
  assertExactKeys(policy, [
    'format', 'policy', 'buildIdentity', 'archive', 'decision', 'pathPolicy',
    'scanners', 'releaseGate',
  ], 'CoreKiwix native secret-scan policy');
  if (
    policy.format !== 1
    || policy.policy !== 'arkfile-corekiwix-native-secret-scan-v1'
    || policy.buildIdentity !== recipeLock.package.version
  ) {
    fail('CoreKiwix native secret-scan policy identity is unsupported.');
  }
  assertExactKeys(policy.archive, ['fileName', 'sha256', 'memberCount'], 'secret-scan archive binding');
  assertDigest(policy.archive.sha256, 'secret-scan archive SHA-256');
  assertInteger(policy.archive.memberCount, 'secret-scan archive member count');
  if (
    policy.archive.fileName !== path.basename(archivePath)
    || policy.archive.sha256 !== archiveSHA256
    || policy.archive.memberCount !== tarEntries.length
  ) {
    fail('Secret-scan policy is not bound to this exact source archive and member inventory.');
  }
  assertExactKeys(policy.releaseGate, [
    'requireArchiveSHA256MatchBeforeExtraction',
    'requireSafeArchivePathAndTypeInspectionBeforeExtraction',
    'requireExactCredentialPathPolicy',
    'requireBothScannerVersions',
    'requireExactFindingCounts',
    'requireExactRuleAndDetectorPathCounts',
    'requireExactCanonicalFindingMultisets',
    'requireZeroVerifiedCredentials',
    'requireZeroPostExclusionScannerErrors',
    'permitBroadPathOrDetectorSuppressions',
  ], 'secret-scan release gate');
  for (const [key, value] of Object.entries(policy.releaseGate)) {
    const expected = key === 'permitBroadPathOrDetectorSuppressions' ? false : true;
    if (value !== expected) fail(`Secret-scan release gate ${key} must be ${expected}.`);
  }
  assertExactKeys(policy.scanners, ['gitleaks', 'trufflehog'], 'secret scanners');
  const gitleaks = policy.scanners.gitleaks;
  assertExactKeys(gitleaks, [
    'version', 'workingDirectory', 'arguments', 'acceptedProcessExitCodesBeforePolicyEvaluation',
    'findingCount', 'uniquePathCount', 'ruleCounts', 'canonicalRecordFieldsInOrder',
    'canonicalization', 'canonicalFindingMultisetSHA256', 'allowedRulePathCounts',
  ], 'Gitleaks policy');
  if (
    gitleaks.version !== '8.30.1'
    || gitleaks.workingDirectory !== 'extracted-archive-root'
    || JSON.stringify(gitleaks.arguments) !== JSON.stringify([
      'dir', '.', '--redact', '--no-banner', '--report-format', 'json', '--report-path', '-',
    ])
    || JSON.stringify(gitleaks.acceptedProcessExitCodesBeforePolicyEvaluation) !== JSON.stringify([0, 1])
    || JSON.stringify(gitleaks.canonicalRecordFieldsInOrder) !== JSON.stringify([
      'ruleID', 'path', 'startLine', 'endLine', 'fileSHA256',
    ])
  ) {
    fail('Gitleaks invocation, version, or canonicalization fields differ from the controlled policy.');
  }
  assertDigest(gitleaks.canonicalFindingMultisetSHA256, 'Gitleaks canonical finding multiset SHA-256');
  assertInteger(gitleaks.findingCount, 'Gitleaks finding count');
  assertInteger(gitleaks.uniquePathCount, 'Gitleaks unique path count');

  const trufflehog = policy.scanners.trufflehog;
  assertExactKeys(trufflehog, [
    'version', 'workingDirectory', 'arguments', 'findingCount', 'uniquePathCount',
    'verifiedFindingCount', 'detectorCounts', 'allowedDetectorPathCounts', 'outputHandling',
    'decompressionErrorPolicy', 'canonicalRecordFieldsInOrder', 'canonicalization',
    'canonicalFindingMultisetSHA256', 'distinctRawCandidateCounts',
  ], 'TruffleHog policy');
  if (
    trufflehog.version !== '3.95.9'
    || trufflehog.workingDirectory !== 'extracted-archive-root'
    || JSON.stringify(trufflehog.arguments) !== JSON.stringify([
      'filesystem', '.', '--results=verified,unknown,unverified', '--json', '--no-update', '--no-verification',
    ])
    || JSON.stringify(trufflehog.canonicalRecordFieldsInOrder) !== JSON.stringify([
      'detector', 'path', 'line', 'verified', 'rawSHA256', 'fileSHA256',
    ])
    || trufflehog.verifiedFindingCount !== 0
  ) {
    fail('TruffleHog invocation, version, verified-finding policy, or canonicalization fields differ from the controlled policy.');
  }
  assertDigest(trufflehog.canonicalFindingMultisetSHA256, 'TruffleHog canonical finding multiset SHA-256');
  assertInteger(trufflehog.findingCount, 'TruffleHog finding count');
  assertInteger(trufflehog.uniquePathCount, 'TruffleHog unique path count');
  assertExactKeys(trufflehog.decompressionErrorPolicy, [
    'preExclusionObservedErrorCount', 'requiredPostExclusionErrorCount', 'rule', 'exactExclusions',
  ], 'TruffleHog decompression-error policy');
  if (
    trufflehog.decompressionErrorPolicy.requiredPostExclusionErrorCount !== 0
    || trufflehog.decompressionErrorPolicy.preExclusionObservedErrorCount
      !== trufflehog.decompressionErrorPolicy.exactExclusions.length
  ) {
    fail('TruffleHog decompression-error policy must fail closed over its exact observed fixture set.');
  }
}

function validateSecretPathPolicy(extractedRoot, payload, policy) {
  const declared = policy.pathPolicy;
  assertExactKeys(declared, [
    'caseSensitiveProhibitedPathComponents', 'prohibitedCredentialPathSuffixes',
    'prohibitedEnvironmentBasenames', 'expectedProhibitedPathCounts',
    'knownLowercaseNonBuildLogFile', 'allowedCredentialShapedUpstreamFiles',
    'upstreamBindings',
  ], 'secret-scan path policy');
  if (
    JSON.stringify(declared.caseSensitiveProhibitedPathComponents) !== JSON.stringify(['LOGS'])
    || JSON.stringify(declared.prohibitedCredentialPathSuffixes) !== JSON.stringify(['.p8', '.p12', '.mobileprovision'])
    || JSON.stringify(declared.prohibitedEnvironmentBasenames) !== JSON.stringify(['.env', '.env.*'])
    || JSON.stringify(declared.expectedProhibitedPathCounts) !== JSON.stringify({
      uppercaseLOGS: 0,
      environmentFiles: 0,
      appleCredentialFiles: 0,
    })
  ) {
    fail('Secret-scan prohibited path policy differs from the controlled fail-closed policy.');
  }
  const paths = [SOURCE_PACKAGE_INVENTORY, ...payload.keys()];
  const prohibitedCounts = {
    uppercaseLOGS: paths.filter((relative) => relative.split('/').includes('LOGS')).length,
    environmentFiles: paths.filter((relative) => {
      const base = path.posix.basename(relative);
      return base === '.env' || base.startsWith('.env.');
    }).length,
    appleCredentialFiles: paths.filter((relative) => (
      ['.p8', '.p12', '.mobileprovision'].some((suffix) => relative.toLowerCase().endsWith(suffix))
    )).length,
  };
  if (JSON.stringify(prohibitedCounts) !== JSON.stringify(declared.expectedProhibitedPathCounts)) {
    fail('Source archive contains a prohibited raw-log, environment, or Apple credential path.');
  }

  const credentialPaths = paths.filter((relative) => {
    const lower = relative.toLowerCase();
    return lower.endsWith('.key') || lower.endsWith('.pem');
  }).sort();
  if (!Array.isArray(declared.allowedCredentialShapedUpstreamFiles)) {
    fail('Secret-scan credential-shaped fixture policy must be an array.');
  }
  const allowedCredentialPaths = [];
  for (const [index, fixture] of declared.allowedCredentialShapedUpstreamFiles.entries()) {
    assertExactKeys(fixture, ['path', 'sha256'], `allowed credential-shaped fixture[${index}]`);
    assertSafeRelativePath(fixture.path, `allowed credential-shaped fixture[${index}] path`);
    assertDigest(fixture.sha256, `allowed credential-shaped fixture[${index}] SHA-256`);
    const packaged = requirePayloadFile(
      extractedRoot,
      payload,
      fixture.path,
      `allowed credential-shaped upstream fixture ${fixture.path}`
    );
    if (packaged.descriptor.sha256 !== fixture.sha256) {
      fail(`Credential-shaped upstream fixture ${fixture.path} differs from the reviewed bytes.`);
    }
    allowedCredentialPaths.push(fixture.path);
  }
  if (JSON.stringify(credentialPaths) !== JSON.stringify(allowedCredentialPaths.sort())) {
    fail('Credential-shaped .key/.pem paths differ from the exact reviewed upstream fixture set.');
  }

  assertExactKeys(declared.knownLowercaseNonBuildLogFile, ['path', 'sha256', 'reason'], 'known lowercase non-build log file');
  const knownLog = requirePayloadFile(
    extractedRoot,
    payload,
    declared.knownLowercaseNonBuildLogFile.path,
    'known lowercase non-build log file'
  );
  if (knownLog.descriptor.sha256 !== declared.knownLowercaseNonBuildLogFile.sha256) {
    fail('Known lowercase upstream log-feature file differs from reviewed bytes.');
  }

  if (!Array.isArray(declared.upstreamBindings)) fail('Secret-scan upstream bindings must be an array.');
  const componentPrefixes = new Map([
    ['curl', 'source/SOURCE/libcurl/'],
    ['libmicrohttpd', 'source/SOURCE/libmicrohttpd-0.9.76/'],
  ]);
  for (const [index, binding] of declared.upstreamBindings.entries()) {
    assertExactKeys(
      binding,
      ['component', 'archivePath', 'archiveSHA256', 'allowedCredentialShapedFileCount'],
      `secret-scan upstream binding[${index}]`
    );
    const prefix = componentPrefixes.get(binding.component);
    if (!prefix) fail(`Secret-scan upstream binding names unsupported component ${binding.component}.`);
    const archive = requirePayloadFile(extractedRoot, payload, binding.archivePath, `${binding.component} exact upstream archive`);
    if (
      archive.descriptor.sha256 !== binding.archiveSHA256
      || allowedCredentialPaths.filter((relative) => relative.startsWith(prefix)).length
        !== binding.allowedCredentialShapedFileCount
    ) {
      fail(`${binding.component} secret-scan fixture policy is not bound to the exact upstream input.`);
    }
  }
}

function evaluateGitleaks(extractedRoot, executable, scannerPolicy, digestCache) {
  const version = runScanner(executable, ['version'], extractedRoot, [0], 'Gitleaks version check').stdout.trim();
  if (version !== scannerPolicy.version) {
    fail(`Gitleaks ${scannerPolicy.version} is required; found ${version || 'unknown'}. Run scripts/arkfile-install-secret-scanners.sh.`);
  }
  const result = runScanner(
    executable,
    scannerPolicy.arguments,
    extractedRoot,
    scannerPolicy.acceptedProcessExitCodesBeforePolicyEvaluation,
    'Gitleaks archive scan'
  );
  let findings;
  try {
    findings = JSON.parse(result.stdout);
  } catch {
    fail('Gitleaks did not return a JSON finding array.');
  }
  if (!Array.isArray(findings)) fail('Gitleaks did not return a JSON finding array.');
  const records = findings.map((finding, index) => {
    assertObject(finding, `Gitleaks finding[${index}]`);
    assertString(finding.RuleID, `Gitleaks finding[${index}].RuleID`);
    if (!Number.isSafeInteger(finding.StartLine) || finding.StartLine < 0) fail('Gitleaks finding has an invalid start line.');
    if (!Number.isSafeInteger(finding.EndLine) || finding.EndLine < finding.StartLine) fail('Gitleaks finding has an invalid end line.');
    const normalized = normalizeScannerFile(extractedRoot, finding.File, `Gitleaks finding[${index}]`, digestCache);
    return {
      ruleID: finding.RuleID,
      path: normalized.path,
      startLine: finding.StartLine,
      endLine: finding.EndLine,
      fileSHA256: normalized.fileSHA256,
    };
  });
  if (
    records.length !== scannerPolicy.findingCount
    || new Set(records.map((record) => record.path)).size !== scannerPolicy.uniquePathCount
    || canonicalFindingMultisetHash(records) !== scannerPolicy.canonicalFindingMultisetSHA256
  ) {
    fail('Gitleaks findings differ from the exact reviewed finding multiset.');
  }
  assertNamedCounts(countBy(records, (record) => record.ruleID), scannerPolicy.ruleCounts, 'Gitleaks rule counts');
  assertCountMapMatchesPolicy(
    countBy(records, (record) => `${record.ruleID}\0${record.path}`),
    scannerPolicy.allowedRulePathCounts,
    ['ruleID', 'path'],
    'Gitleaks rule/path counts'
  );
  return records.length;
}

function evaluateTruffleHog(extractedRoot, executable, scannerPolicy, digestCache) {
  const expectedVersion = `trufflehog ${scannerPolicy.version}`;
  const version = runScanner(executable, ['--version'], extractedRoot, [0], 'TruffleHog version check').stdout.trim();
  if (version !== expectedVersion) {
    fail(`TruffleHog ${scannerPolicy.version} is required; found ${version || 'unknown'}. Run scripts/arkfile-install-secret-scanners.sh.`);
  }
  const result = runScanner(executable, scannerPolicy.arguments, extractedRoot, [0], 'TruffleHog archive scan');
  const records = [];
  for (const [index, line] of result.stdout.split(/\r?\n/u).filter(Boolean).entries()) {
    let finding;
    try { finding = JSON.parse(line); } catch { fail(`TruffleHog finding line ${index + 1} is not JSON.`); }
    assertObject(finding, `TruffleHog finding[${index}]`);
    assertString(finding.DetectorName, `TruffleHog finding[${index}].DetectorName`);
    if (typeof finding.Raw !== 'string' || typeof finding.Verified !== 'boolean') {
      fail('TruffleHog finding has missing raw or verification fields.');
    }
    const filesystem = finding.SourceMetadata?.Data?.Filesystem;
    assertObject(filesystem, `TruffleHog finding[${index}] filesystem metadata`);
    if (!Number.isSafeInteger(filesystem.line) || filesystem.line < 0) fail('TruffleHog finding has an invalid line.');
    const normalized = normalizeScannerFile(extractedRoot, filesystem.file, `TruffleHog finding[${index}]`, digestCache);
    records.push({
      detector: finding.DetectorName,
      path: normalized.path,
      line: filesystem.line,
      verified: finding.Verified,
      rawSHA256: sha256(Buffer.from(finding.Raw, 'utf8')),
      fileSHA256: normalized.fileSHA256,
    });
  }
  const errorPaths = [];
  for (const [index, line] of result.stderr.split(/\r?\n/u).filter(Boolean).entries()) {
    let event;
    try { event = JSON.parse(line); } catch { fail(`TruffleHog stderr line ${index + 1} is not JSON.`); }
    if (event.level !== 'error') continue;
    if (event.msg !== 'error scanning file') {
      fail(`TruffleHog reported an unreviewed scanner error: ${String(event.msg || 'unknown error')}.`);
    }
    const normalized = normalizeScannerFile(extractedRoot, event.path, `TruffleHog scanner error[${index}]`, digestCache);
    errorPaths.push(normalized);
  }
  const declaredErrors = scannerPolicy.decompressionErrorPolicy.exactExclusions;
  if (!Array.isArray(declaredErrors)) fail('TruffleHog exact decompression-error exclusions must be an array.');
  const expectedErrors = new Map();
  for (const [index, fixture] of declaredErrors.entries()) {
    assertExactKeys(fixture, ['path', 'sha256'], `TruffleHog exact error fixture[${index}]`);
    assertSafeRelativePath(fixture.path, `TruffleHog exact error fixture[${index}] path`);
    assertDigest(fixture.sha256, `TruffleHog exact error fixture[${index}] SHA-256`);
    if (expectedErrors.has(fixture.path)) fail('TruffleHog exact error policy contains a duplicate path.');
    expectedErrors.set(fixture.path, fixture.sha256);
  }
  if (errorPaths.length !== expectedErrors.size || new Set(errorPaths.map((entry) => entry.path)).size !== expectedErrors.size) {
    fail('TruffleHog scanner-error multiset differs from the exact reviewed fixture set.');
  }
  for (const error of errorPaths) {
    if (expectedErrors.get(error.path) !== error.fileSHA256) {
      fail('TruffleHog scanner error is missing, additional, or bound to changed bytes.');
    }
  }
  // TruffleHog's concurrent filesystem enumerator can emit a byte-identical
  // duplicate JSON result for one file. Treat records as exact tuples: only
  // duplicate output events collapse, while any new or changed tuple remains a
  // hard mismatch against the reviewed canonical set.
  const uniqueRecordMap = new Map(records.map((record) => [JSON.stringify(record), record]));
  const uniqueRecords = [...uniqueRecordMap.values()];
  const duplicateFindingEventCount = records.length - uniqueRecords.length;
  const uniquePathCount = new Set(uniqueRecords.map((record) => record.path)).size;
  const verifiedFindingCount = uniqueRecords.filter((record) => record.verified).length;
  const findingMultisetSHA256 = canonicalFindingMultisetHash(uniqueRecords);
  if (uniqueRecords.length !== scannerPolicy.findingCount) {
    const mismatches = countMapPolicyDifferences(
      countBy(uniqueRecords, (record) => `${record.detector}\0${record.path}`),
      scannerPolicy.allowedDetectorPathCounts,
      ['detector', 'path']
    );
    fail(
      `TruffleHog unique finding count ${uniqueRecords.length} differs from reviewed count ${scannerPolicy.findingCount}`
      + `${mismatches.length > 0 ? `: ${mismatches.slice(0, 5).join('; ')}` : ''}.`
    );
  }
  if (uniquePathCount !== scannerPolicy.uniquePathCount) {
    fail(`TruffleHog unique-path count ${uniquePathCount} differs from reviewed count ${scannerPolicy.uniquePathCount}.`);
  }
  if (verifiedFindingCount !== scannerPolicy.verifiedFindingCount || verifiedFindingCount !== 0) {
    fail(`TruffleHog reported ${verifiedFindingCount} verified credentials; zero are permitted.`);
  }
  if (findingMultisetSHA256 !== scannerPolicy.canonicalFindingMultisetSHA256) {
    fail(`TruffleHog canonical finding multiset ${findingMultisetSHA256} differs from reviewed ${scannerPolicy.canonicalFindingMultisetSHA256}.`);
  }
  assertNamedCounts(countBy(uniqueRecords, (record) => record.detector), scannerPolicy.detectorCounts, 'TruffleHog detector counts');
  assertCountMapMatchesPolicy(
    countBy(uniqueRecords, (record) => `${record.detector}\0${record.path}`),
    scannerPolicy.allowedDetectorPathCounts,
    ['detector', 'path'],
    'TruffleHog detector/path counts'
  );
  const distinctRawCounts = new Map();
  for (const detector of new Set(uniqueRecords.map((record) => record.detector))) {
    distinctRawCounts.set(
      detector,
      new Set(uniqueRecords.filter((record) => record.detector === detector).map((record) => record.rawSHA256)).size
    );
  }
  assertNamedCounts(distinctRawCounts, scannerPolicy.distinctRawCandidateCounts, 'TruffleHog distinct raw candidate counts');
  return {
    findingCount: uniqueRecords.length,
    duplicateFindingEventCount,
    scannerErrorFixtureCount: errorPaths.length,
  };
}

function verifyPortableSecretScan(extractedRoot, payload, policy, executables) {
  validateSecretPathPolicy(extractedRoot, payload, policy);
  const digestCache = new Map();
  const gitleaksFindingCount = evaluateGitleaks(extractedRoot, executables.gitleaks, policy.scanners.gitleaks, digestCache);
  const trufflehog = evaluateTruffleHog(extractedRoot, executables.trufflehog, policy.scanners.trufflehog, digestCache);
  return { gitleaksFindingCount, ...trufflehog };
}

export function verifyPortableCoreKiwixRelinkPackage(options) {
  assertObject(options, 'portable verification options');
  assertString(options.secretScanPolicy, 'portable secret-scan policy path');
  const archivePath = path.resolve(options.archive);
  const frameworkRoot = requireDirectory(path.resolve(options.framework), 'checked CoreKiwix XCFramework');
  const evidenceRoot = requireDirectory(path.resolve(options.evidence), 'checked CoreKiwix evidence directory');
  const noticesRoot = requireDirectory(path.resolve(options.notices), 'checked CoreKiwix curated notices');
  const recipeLockPath = path.resolve(options.recipeLock);
  const exceptionsPath = path.resolve(options.exceptions);
  const secretScanPolicyPath = path.resolve(options.secretScanPolicy);
  const scannerExecutables = {
    gitleaks: resolveScannerExecutable(options.gitleaks, 'Gitleaks'),
    trufflehog: resolveScannerExecutable(options.trufflehog, 'TruffleHog'),
  };
  requireRegularFile(archivePath, 'CoreKiwix corresponding-source archive');
  const archiveSHA256 = sha256File(archivePath);
  assertNotStaleSHA256(archiveSHA256, 'CoreKiwix corresponding-source archive');

  const { value: recipeLock, contents: recipeLockContents } = readCanonicalJSON(
    recipeLockPath,
    'checked CoreKiwix recipe lock'
  );
  validateRecipeLock(recipeLock, recipeLockContents);
  const { value: secretScanPolicy, contents: secretScanPolicyContents } = readCanonicalJSON(
    secretScanPolicyPath,
    'checked CoreKiwix native secret-scan policy'
  );
  if (sha256(secretScanPolicyContents) !== CONTROLLED_SECRET_SCAN_POLICY_SHA256) {
    fail('Checked CoreKiwix native secret-scan policy differs from the reviewed controlled policy.');
  }
  const evidence = collectEvidence(evidenceRoot);
  const exceptions = validateExceptionPolicy(exceptionsPath, evidence);
  const notices = validateNotices(recipeLock, noticesRoot);
  const toolset = tools();
  const workspace = mkdtempSync(path.join(os.tmpdir(), 'arkfile-corekiwix-portable-verify-'));
  try {
    const tarPath = path.join(workspace, 'package.tar');
    const extractedRoot = path.join(workspace, 'extracted');
    mkdirSync(extractedRoot, { mode: 0o755 });
    decompressArchive(toolset, archivePath, tarPath);
    const tarEntries = inspectDeterministicTar(tarPath, recipeLock.sourceDateEpoch);
    validateSecretScanPolicy(secretScanPolicy, archivePath, archiveSHA256, tarEntries, recipeLock);
    copyTarEntries(tarPath, tarEntries, extractedRoot, recipeLock.sourceDateEpoch);
    const { value: inventory, contents: inventoryContents } = readCanonicalJSON(
      path.join(extractedRoot, SOURCE_PACKAGE_INVENTORY),
      'packaged CoreKiwix inventory'
    );
    validatePortableInventoryIdentity(inventory, recipeLock, evidence, exceptions, notices);
    const { payload, expectedPaths } = payloadEntryMap(inventory, tarEntries, inventoryContents);
    validatePortablePayloadPolicy(payload);
    const secretScan = verifyPortableSecretScan(extractedRoot, payload, secretScanPolicy, scannerExecutables);
    validatePortableEvidenceAndPolicies(
      extractedRoot,
      payload,
      inventory,
      evidenceRoot,
      evidence,
      exceptionsPath,
      exceptions,
      recipeLockPath,
      recipeLockContents,
      noticesRoot,
      notices
    );
    validatePortableRecipeAndInputs(extractedRoot, payload, inventory, recipeLock, evidence, toolset);
    validatePortableSourceBindings(extractedRoot, payload, inventory, evidence);
    validatePortableNormalizedEvidence(extractedRoot, payload, inventory, evidence);
    validatePortableFramework(extractedRoot, payload, inventory, frameworkRoot, evidence, recipeLock, toolset);
    validatePortableRelinkBindings(extractedRoot, inventory, evidence, frameworkRoot, toolset);

    const reproducedPath = path.join(workspace, 'reproduced.tar.gz');
    writeDeterministicTarGzip(
      extractedRoot,
      expectedPaths,
      recipeLock.sourceDateEpoch,
      reproducedPath,
      toolset
    );
    if (
      statSync(reproducedPath).size !== statSync(archivePath).size
      || sha256File(reproducedPath) !== archiveSHA256
    ) {
      fail('Source package is not byte-for-byte reproducible from its portable inventory and metadata.');
    }
    const relinkedTargets = verifyRelinkTargets(extractedRoot, inventory, toolset);
    return {
      archive: archivePath,
      archiveSHA256,
      sizeBytes: statSync(archivePath).size,
      payloadFileCount: inventory.payloadFileCount,
      relinkedTargets,
      byteIdenticalRelinkRequired: false,
      preNormalizationSourceDigestsRecomputed: false,
      secretScan,
    };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function compareArchiveSpec(actual, expected, label) {
  for (const key of [
    'sizeBytes', 'sha256', 'archiveMemberCount', 'archiveMemberSetSHA256',
    'objectMemberCount', 'orderedObjectMemberSetSHA256', 'definedSymbolCount',
    'definedSymbolSetSHA256',
  ]) {
    if (actual[key] !== expected[key]) fail(`${label} ${key} differs from the package inventory.`);
  }
}

function verifyRelinkTargets(extractedRoot, inventory, toolset) {
  const workspace = mkdtempSync(path.join(os.tmpdir(), 'arkfile-corekiwix-relink-'));
  const verified = [];
  try {
    for (const target of inventory.relinkProof.targets) {
      const archiveByName = new Map();
      for (const archive of target.componentArchives) {
        const archivePath = path.join(extractedRoot, ...archive.path.split('/'));
        const spec = archiveEvidenceSpec(archivePath, toolset, `${target.id} packaged ${archive.name}`);
        compareArchiveSpec(spec, archive, `${target.id} ${archive.name}`);
        assertNotStaleSHA256(spec.sha256, `${target.id} ${archive.name}`);
        archiveByName.set(archive.name, archivePath);
      }
      if (archiveByName.size !== COMPONENT_ARCHIVES.length) fail(`${target.id} does not contain all component archives.`);
      const mhdPath = archiveByName.get('libmicrohttpd.a');
      const packagedMhdMembers = archiveMembers(toolset, mhdPath, `${target.id} packaged libmicrohttpd`).objects;
      if (JSON.stringify(packagedMhdMembers) !== JSON.stringify(target.libmicrohttpdObjects.map((item) => item.member))) {
        fail(`${target.id} libmicrohttpd object-input set is incomplete or out of order.`);
      }
      for (const object of target.libmicrohttpdObjects) {
        const objectPath = path.join(extractedRoot, ...object.path.split('/'));
        requireRegularFile(objectPath, `${target.id} packaged libmicrohttpd object ${object.member}`);
        const extractedBytes = runBuffer(toolset.ar, ['-p', mhdPath, object.member], `${target.id} libmicrohttpd object extraction`);
        if (
          extractedBytes.length !== object.sizeBytes
          || sha256(extractedBytes) !== object.sha256
          || sha256File(objectPath) !== object.sha256
        ) {
          fail(`${target.id} libmicrohttpd object ${object.member} is not byte-identical to its packaged input.`);
        }
      }

      const referencePath = path.join(extractedRoot, ...target.referenceMergedArchive.path.split('/'));
      const reference = archiveEvidenceSpec(referencePath, toolset, `${target.id} packaged reference merged archive`);
      compareArchiveSpec(reference, target.referenceMergedArchive, `${target.id} reference merged archive`);
      assertNotStaleSHA256(reference.sha256, `${target.id} reference merged archive`);
      const rebuiltPath = path.join(workspace, `${target.id}.a`);
      const orderedArchives = target.componentArchiveOrder.map((archiveName) => {
        const archivePath = archiveByName.get(archiveName);
        if (!archivePath) fail(`${target.id} relink order names missing archive ${archiveName}.`);
        return archivePath;
      });
      runText(toolset.libtool, ['-static', '-o', rebuiltPath, ...orderedArchives], `${target.id} five-target relink`);
      const rebuiltMembers = archiveMembers(toolset, rebuiltPath, `${target.id} rebuilt archive`).objects;
      const rebuiltSymbols = definedSymbols(toolset, rebuiltPath, `${target.id} rebuilt archive`);
      if (JSON.stringify(rebuiltMembers) !== JSON.stringify(reference.internal.objects)) {
        fail(`${target.id} rebuilt ordered non-index object-member multiset differs from the reference.`);
      }
      if (JSON.stringify(rebuiltSymbols) !== JSON.stringify(reference.internal.symbols)) {
        fail(`${target.id} rebuilt externally-defined symbol set differs from the reference.`);
      }
      const rebuiltArchitectures = architectures(toolset, rebuiltPath, `${target.id} rebuilt archive`);
      if (JSON.stringify(rebuiltArchitectures) !== JSON.stringify([target.architecture])) {
        fail(`${target.id} rebuilt archive architecture differs from the controlled target.`);
      }
      verified.push({
        id: target.id,
        orderedObjectMemberCount: rebuiltMembers.length,
        definedSymbolCount: rebuiltSymbols.length,
        binaryByteIdentityRequired: false,
      });
    }
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
  if (verified.length !== 5) fail('Verifier did not relink all five controlled thin targets.');
  return verified;
}

export function verifyCoreKiwixRelinkPackage(options) {
  assertObject(options, 'verification options');
  const archivePath = path.resolve(options.archive);
  requireRegularFile(archivePath, 'CoreKiwix corresponding-source archive');
  const digest = sha256File(archivePath);
  assertNotStaleSHA256(digest, 'CoreKiwix corresponding-source archive');
  const expectedPlan = createCoreKiwixPackagePlan(options);
  const toolset = tools();
  const workspace = mkdtempSync(path.join(os.tmpdir(), 'arkfile-corekiwix-package-verify-'));
  try {
    const tarPath = path.join(workspace, 'package.tar');
    const extractedRoot = path.join(workspace, 'extracted');
    mkdirSync(extractedRoot, { mode: 0o755 });
    decompressArchive(toolset, archivePath, tarPath);
    const tarEntries = inspectDeterministicTar(tarPath, expectedPlan.sourceDateEpoch);
    const actualPaths = tarEntries.map((entry) => entry.path).sort();
    if (JSON.stringify(actualPaths) !== JSON.stringify(expectedPlan.memberPaths)) {
      fail('Source package has missing, extra, duplicated, or renamed members.');
    }
    const expectedByPath = new Map(expectedPlan.inventory.payloadFiles.map((entry) => [entry.path, entry]));
    for (const entry of tarEntries) {
      if (entry.path === SOURCE_PACKAGE_INVENTORY) {
        if (
          entry.mode !== 0o644
          || entry.sizeBytes !== Buffer.byteLength(expectedPlan.inventoryContents)
          || entry.sha256 !== sha256(expectedPlan.inventoryContents)
        ) {
          fail('Source package inventory member bytes or metadata differ from the fresh deterministic plan.');
        }
        continue;
      }
      const expected = expectedByPath.get(entry.path);
      if (
        !expected
        || entry.mode !== expected.mode
        || entry.sizeBytes !== expected.sizeBytes
        || entry.sha256 !== expected.sha256
      ) {
        fail(`Source package payload ${entry.path} differs from the fresh inventory.`);
      }
      assertNotStaleSHA256(entry.sha256, `source package payload ${entry.path}`);
    }
    copyTarEntries(tarPath, tarEntries, extractedRoot, expectedPlan.sourceDateEpoch);
    const { contents: inventoryContents } = readCanonicalJSON(
      path.join(extractedRoot, SOURCE_PACKAGE_INVENTORY),
      'packaged CoreKiwix inventory'
    );
    if (inventoryContents !== expectedPlan.inventoryContents) {
      fail('Packaged inventory differs from freshly recomputed explicit inputs.');
    }

    const reproducedPath = path.join(workspace, 'reproduced.tar.gz');
    writeDeterministicTarGzip(
      extractedRoot,
      expectedPlan.memberPaths,
      expectedPlan.sourceDateEpoch,
      reproducedPath,
      toolset
    );
    if (statSync(reproducedPath).size !== statSync(archivePath).size || sha256File(reproducedPath) !== digest) {
      fail('Source package is not byte-for-byte reproducible from its normalized members and metadata.');
    }
    const relinkedTargets = verifyRelinkTargets(extractedRoot, expectedPlan.inventory, toolset);
    return {
      archive: archivePath,
      archiveSHA256: digest,
      sizeBytes: statSync(archivePath).size,
      payloadFileCount: expectedPlan.inventory.payloadFileCount,
      relinkedTargets,
      byteIdenticalRelinkRequired: false,
    };
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

function usage() {
  return `Usage:
  node ${SCRIPT_RELATIVE_PATH} full --archive <tar.gz> --build-work <build-work> --framework <CoreKiwix.xcframework> --recipe-root <kiwix-build> --recipe-lock <lock.json> --tool-input-root <tool-input-root> --exceptions <exceptions.json> --notices <notice-dir> --evidence <evidence-dir>
  node ${SCRIPT_RELATIVE_PATH} portable --archive <tar.gz> --framework <CoreKiwix.xcframework> --recipe-lock <lock.json> --exceptions <exceptions.json> --notices <notice-dir> --evidence <evidence-dir> --secret-scan-policy <policy.json> --gitleaks <gitleaks> --trufflehog <trufflehog>

The portable verifier recomputes package, normalized-evidence, framework, and
five-target relink proofs from public package inputs. Pre-normalization private
build-file sourceSizeBytes/sourceSHA256 fields remain bound by the pinned archive
and inventory but cannot be independently recomputed without private build-work.`;
}

function parseCLI(argv) {
  const values = [...argv];
  const mode = values[0] === 'portable' || values[0] === 'full' ? values.shift() : 'full';
  const fullAllowed = [
    '--archive', '--build-work', '--framework', '--recipe-root', '--recipe-lock',
    '--tool-input-root', '--exceptions', '--notices', '--evidence',
  ];
  const portableAllowed = [
    '--archive', '--framework', '--recipe-lock', '--exceptions', '--notices', '--evidence',
    '--secret-scan-policy', '--gitleaks', '--trufflehog',
  ];
  const allowed = new Set(mode === 'portable' ? portableAllowed : fullAllowed);
  const options = {};
  for (let index = 0; index < values.length; index += 2) {
    const flag = values[index];
    const value = values[index + 1];
    if (!allowed.has(flag) || typeof value !== 'string' || value.length === 0 || value.startsWith('--')) fail(usage());
    const key = flag.slice(2).replace(/-([a-z])/gu, (_match, letter) => letter.toUpperCase());
    if (Object.hasOwn(options, key)) fail(`Duplicate CLI option ${flag}.`);
    options[key] = value;
  }
  for (const flag of allowed) {
    const key = flag.slice(2).replace(/-([a-z])/gu, (_match, letter) => letter.toUpperCase());
    if (!options[key]) fail(`Missing ${flag}.\n${usage()}`);
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
    const result = mode === 'portable'
      ? verifyPortableCoreKiwixRelinkPackage(options)
      : verifyCoreKiwixRelinkPackage(options);
    process.stdout.write(
      `CoreKiwix corresponding-source package ${mode === 'portable' ? 'portably ' : ''}verified: ${result.relinkedTargets.length} thin targets, `
      + `${result.payloadFileCount} payload files, archive ${result.archiveSHA256}; byte-identical relink is not required`
      + `${result.secretScan ? `; exact reviewed secret-candidate baseline matched (${result.secretScan.gitleaksFindingCount} Gitleaks, ${result.secretScan.findingCount} TruffleHog; network verification intentionally disabled)` : ''}.\n`
    );
  } catch (error) {
    process.stderr.write(`CoreKiwix source-package verification error: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = error instanceof CoreKiwixSourcePackageError ? 1 : 2;
  }
}

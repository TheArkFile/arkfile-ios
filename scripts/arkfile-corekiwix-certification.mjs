#!/usr/bin/env node

import { createHash } from 'node:crypto';
import {
  closeSync,
  lstatSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = realpathSync(path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const receiptPath = path.join(root, 'Dependencies', 'CoreKiwixNativeCertification.json');
const policyPath = path.join(root, 'Dependencies', 'CoreKiwixNativeSecretScanPolicy.json');
const frameworkPath = process.env.ARKFILE_COREKIWIX_FRAMEWORK
  ? realpathSync(process.env.ARKFILE_COREKIWIX_FRAMEWORK)
  : path.join(root, 'CoreKiwix.xcframework');

const fileInputs = [
  'Dependencies/CoreKiwixNativeBuildManifest.json',
  'Dependencies/CoreKiwixNativeSource.lock.json',
  'Dependencies/CoreKiwixNativeSBOM.spdx.json',
  'Dependencies/CoreKiwixNativeObjectMap.jsonl',
  'Dependencies/CoreKiwixNativeExceptions.json',
  'Dependencies/CoreKiwixNativeBuildRecipe.lock.json',
  'Dependencies/CoreKiwixNativeSecretScanPolicy.json',
  'Support/CoreKiwix.modulemap',
  'scripts/arkfile-corekiwix-evidence.mjs',
  'scripts/arkfile-verify-corekiwix-relink.mjs',
  'scripts/arkfile-verify-corekiwix.sh',
];

function fail(message) {
  process.stderr.write(`error: ${message}\n`);
  process.exit(1);
}

function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function sha256FilePath(filePath) {
  const hash = createHash('sha256');
  const descriptor = openSync(filePath, 'r');
  const buffer = Buffer.allocUnsafe(4 * 1024 * 1024);
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

function fileRecord(relativePath) {
  const absolutePath = path.join(root, relativePath);
  const stat = lstatSync(absolutePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`Certification input must be a regular file: ${relativePath}`);
  }
  const bytes = readFileSync(absolutePath);
  return { sha256: sha256(bytes), sizeBytes: bytes.length };
}

function treeRecord(absoluteRoot, logicalRoot) {
  const rootStat = lstatSync(absoluteRoot);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    fail(`Certification input must be a real directory: ${logicalRoot}`);
  }
  const records = [];
  const visit = (absoluteDirectory, relativeDirectory) => {
    for (const name of readdirSync(absoluteDirectory).sort()) {
      const absolutePath = path.join(absoluteDirectory, name);
      const relativePath = path.posix.join(relativeDirectory, name);
      const stat = lstatSync(absolutePath);
      if (stat.isSymbolicLink()) {
        fail(`Certification input contains a symlink: ${relativePath}`);
      }
      if (stat.isDirectory()) {
        visit(absolutePath, relativePath);
      } else if (stat.isFile()) {
        const bytes = readFileSync(absolutePath);
        records.push(`${relativePath}\0${bytes.length}\0${sha256(bytes)}\n`);
      } else {
        fail(`Certification input contains an unsupported entry: ${relativePath}`);
      }
    }
  };
  visit(absoluteRoot, logicalRoot);
  return {
    sha256: sha256(records.join('')),
    fileCount: records.length,
  };
}

function expectedSnapshot() {
  const policy = JSON.parse(readFileSync(policyPath, 'utf8'));
  if (policy.buildIdentity !== '14.2.0+arkfile.1') {
    fail('Controlled CoreKiwix build identity is unsupported.');
  }
  if (!/^[0-9a-f]{64}$/u.test(policy.archive?.sha256 ?? '')) {
    fail('Controlled CoreKiwix source archive SHA-256 is invalid.');
  }

  return {
    format: 1,
    policy: 'arkfile-corekiwix-native-certification-v1',
    buildIdentity: policy.buildIdentity,
    proof: 'full-five-target-relink',
    sourceArchive: {
      fileName: policy.archive.fileName,
      sha256: policy.archive.sha256,
    },
    inputs: {
      framework: treeRecord(frameworkPath, 'CoreKiwix.xcframework'),
      notices: treeRecord(
        path.join(root, 'Dependencies', 'CoreKiwixNativeNotices'),
        'Dependencies/CoreKiwixNativeNotices',
      ),
      files: Object.fromEntries(fileInputs.map((input) => [input, fileRecord(input)])),
    },
  };
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}

function usage() {
  process.stdout.write(`Usage:\n  scripts/arkfile-corekiwix-certification.mjs check\n  scripts/arkfile-corekiwix-certification.mjs snapshot\n  scripts/arkfile-corekiwix-certification.mjs write --source-archive PATH\n\nUse scripts/arkfile-certify-corekiwix.sh for recertification.\n`);
}

const command = process.argv[2];
if (command === 'check') {
  let receipt;
  try {
    receipt = JSON.parse(readFileSync(receiptPath, 'utf8'));
  } catch {
    fail('CoreKiwix certification receipt is missing or unreadable. Run scripts/arkfile-certify-corekiwix.sh with the controlled source archive.');
  }
  const { certifiedAt: _certifiedAt, ...recorded } = receipt;
  const expected = expectedSnapshot();
  if (JSON.stringify(stable(recorded)) !== JSON.stringify(stable(expected))) {
    fail('CoreKiwix changed after its last full certification. Run scripts/arkfile-certify-corekiwix.sh with the controlled source archive.');
  }
  process.stdout.write(`CoreKiwix ${expected.buildIdentity} certification is current (${expected.inputs.framework.fileCount} framework files).\n`);
} else if (command === 'snapshot') {
  process.stdout.write(`${JSON.stringify(expectedSnapshot(), null, 2)}\n`);
} else if (command === 'write') {
  const sourceIndex = process.argv.indexOf('--source-archive');
  const sourcePath = sourceIndex >= 0 ? process.argv[sourceIndex + 1] : '';
  if (!sourcePath) fail('Pass --source-archive after the full verifier succeeds.');
  const sourceStat = lstatSync(sourcePath);
  if (!sourceStat.isFile() || sourceStat.isSymbolicLink()) fail('Controlled source archive must be a regular file.');
  const expected = expectedSnapshot();
  if (sha256FilePath(sourcePath) !== expected.sourceArchive.sha256) {
    fail('Controlled source archive does not match the reviewed SHA-256.');
  }
  const receipt = {
    ...expected,
    certifiedAt: new Date().toISOString().replace(/\.\d{3}Z$/u, 'Z'),
  };
  writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'w' });
  process.stdout.write(`Wrote ${path.relative(root, receiptPath)}. Commit it with the native change.\n`);
} else if (command === '--help' || command === '-h' || command === 'help') {
  usage();
} else {
  usage();
  fail(`Unknown command: ${command ?? '(none)'}`);
}

#!/usr/bin/env node

/**
 * Create ArkFile's deterministic CoreKiwix corresponding-source/relink
 * archive from explicit, already-frozen controlled-build inputs.  The archive
 * is retained only after the independent five-target relink verifier passes.
 */

import {
  existsSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  statSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  CoreKiwixSourcePackageError,
  createCoreKiwixPackagePlan,
  materializeCoreKiwixPackagePlan,
  verifyCoreKiwixRelinkPackage,
  verifyPortableCoreKiwixRelinkPackage,
  writeDeterministicTarGzip,
} from './arkfile-verify-corekiwix-relink.mjs';

const SCRIPT_RELATIVE_PATH = 'scripts/arkfile-package-corekiwix-source.mjs';

function fail(message) {
  throw new CoreKiwixSourcePackageError(message);
}

function packageCoreKiwixSourceInternal(options, requirePortableGate) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) fail('Package options must be an object.');
  const output = path.resolve(options.output);
  if (existsSync(output)) fail(`Refusing to overwrite existing output archive ${output}.`);
  const portableGateKeys = ['secretScanPolicy', 'gitleaks', 'trufflehog'];
  const portableGateValueCount = portableGateKeys.filter((key) => (
    typeof options[key] === 'string' && options[key].length > 0
  )).length;
  if (
    (requirePortableGate && portableGateValueCount !== portableGateKeys.length)
    || (!requirePortableGate && portableGateValueCount !== 0)
  ) {
    fail('Secret-scan policy, Gitleaks, and TruffleHog are required together for production post-package verification.');
  }
  const plan = createCoreKiwixPackagePlan(options);
  const workspace = mkdtempSync(path.join(os.tmpdir(), 'arkfile-corekiwix-package-stage-'));
  let created = false;
  try {
    const stageRoot = path.join(workspace, 'stage');
    materializeCoreKiwixPackagePlan(plan, stageRoot);
    const written = writeDeterministicTarGzip(
      stageRoot,
      plan.memberPaths,
      plan.sourceDateEpoch,
      output
    );
    created = true;
    const verified = verifyCoreKiwixRelinkPackage({ ...options, archive: output });
    if (
      verified.archiveSHA256 !== written.archiveSHA256
      || verified.sizeBytes !== written.sizeBytes
      || verified.relinkedTargets.length !== 5
    ) {
      fail('Post-package verification result differs from the created archive.');
    }
    if (requirePortableGate) {
      const portable = verifyPortableCoreKiwixRelinkPackage({ ...options, archive: output });
      if (
        portable.archiveSHA256 !== written.archiveSHA256
        || portable.sizeBytes !== written.sizeBytes
        || portable.relinkedTargets.length !== 5
        || portable.secretScan?.gitleaksFindingCount !== 54
        || portable.secretScan?.findingCount !== 141
      ) {
        fail('Portable post-package secret-scan/relink result differs from the created archive.');
      }
      return portable;
    }
    return verified;
  } catch (error) {
    if (created && existsSync(output) && statSync(output).isFile()) rmSync(output, { force: true });
    throw error;
  } finally {
    rmSync(workspace, { recursive: true, force: true });
  }
}

export function packageCoreKiwixSource(options) {
  return packageCoreKiwixSourceInternal(options, true);
}

// Synthetic unit fixtures intentionally cannot satisfy the production archive's
// exact, hash-bound scanner policy. Keep that omission behind an explicit test
// entrypoint that is unavailable to ordinary scripts and callers.
export function packageCoreKiwixCandidateForTesting(options) {
  if (!process.env.NODE_TEST_CONTEXT) {
    fail('The scanner-free CoreKiwix package helper is available only under the Node test runner.');
  }
  return packageCoreKiwixSourceInternal(options, false);
}

function usage() {
  return `Usage:
  node ${SCRIPT_RELATIVE_PATH} --build-work <build-work> --framework <CoreKiwix.xcframework> --recipe-root <kiwix-build> --recipe-lock <lock.json> --tool-input-root <tool-input-root> --exceptions <exceptions.json> --notices <notice-dir> --evidence <evidence-dir> --secret-scan-policy <policy.json> --gitleaks <gitleaks> --trufflehog <trufflehog> --output <tar.gz>`;
}

function parseCLI(argv) {
  const allowed = new Set([
    '--build-work', '--framework', '--recipe-root', '--recipe-lock', '--tool-input-root', '--exceptions', '--notices', '--evidence',
    '--secret-scan-policy', '--gitleaks', '--trufflehog', '--output',
  ]);
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || typeof value !== 'string' || value.length === 0 || value.startsWith('--')) fail(usage());
    const key = flag.slice(2).replace(/-([a-z])/gu, (_match, letter) => letter.toUpperCase());
    if (Object.hasOwn(options, key)) fail(`Duplicate CLI option ${flag}.`);
    options[key] = value;
  }
  for (const flag of allowed) {
    const key = flag.slice(2).replace(/-([a-z])/gu, (_match, letter) => letter.toUpperCase());
    if (!options[key]) fail(`Missing ${flag}.\n${usage()}`);
  }
  return options;
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
    const result = packageCoreKiwixSource(parseCLI(process.argv.slice(2)));
    process.stdout.write(
      `CoreKiwix corresponding-source package created and verified: ${result.relinkedTargets.length} thin targets, `
      + `${result.payloadFileCount} payload files, ${result.sizeBytes} bytes, SHA-256 ${result.archiveSHA256}.\n`
    );
  } catch (error) {
    process.stderr.write(`CoreKiwix source-package error: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = error instanceof CoreKiwixSourcePackageError ? 1 : 2;
  }
}

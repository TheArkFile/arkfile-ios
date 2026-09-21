#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const usageDescription = 'With your permission, ArkFile shares your advertising identifier and install, purchase, and first-download events with Meta to measure and improve ArkFile ads.';
const domain = 'events.thearkfile.com';
const setting = 'ARKFILE_AD_MEASUREMENT_ENABLED';
const purposeKey = 'NSPrivacyCollectedDataTypePurposes';
const trackingKey = 'NSPrivacyCollectedDataTypeTracking';
const typeKey = 'NSPrivacyCollectedDataType';
const measurementPurposes = ['NSPrivacyCollectedDataTypePurposeDeveloperAdvertising', 'NSPrivacyCollectedDataTypePurposeAnalytics'];
const measurementTypes = ['NSPrivacyCollectedDataTypePurchaseHistory', 'NSPrivacyCollectedDataTypeDeviceID', 'NSPrivacyCollectedDataTypeProductInteraction'];

export function validateConfiguration(info, manifest) {
  const errors = [];
  const enabled = info[setting];
  if (typeof enabled !== 'boolean') errors.push('Measurement switch must be an explicit Boolean.');
  const types = manifest.NSPrivacyCollectedDataTypes;
  if (!Array.isArray(types)) return [...errors, 'Privacy collected-data declarations must be an array.'];
  if (enabled === true) {
    if (info.NSUserTrackingUsageDescription !== usageDescription) errors.push('Enabled measurement requires the reviewed tracking permission description.');
    if (manifest.NSPrivacyTracking !== true) errors.push('Enabled measurement requires the tracking declaration.');
    if (JSON.stringify(manifest.NSPrivacyTrackingDomains) !== JSON.stringify([domain])) errors.push('Enabled measurement must use only the dedicated tracking domain.');
    for (const name of measurementTypes) {
      const matching = types.filter((entry) => entry[typeKey] === name);
      if (matching.length !== 1 || matching[0][trackingKey] !== true || matching[0].NSPrivacyCollectedDataTypeLinked !== true
        || !measurementPurposes.every((purpose) => matching[0][purposeKey]?.includes(purpose))) {
        errors.push(`Enabled measurement is missing its linked/tracking/purpose declaration for ${name}.`);
      }
    }
  } else {
    if (Object.hasOwn(info, 'NSUserTrackingUsageDescription')) errors.push('Disabled measurement must not ship a tracking permission description.');
    if (manifest.NSPrivacyTracking !== false) errors.push('Disabled measurement requires NSPrivacyTracking=false.');
    if (!Array.isArray(manifest.NSPrivacyTrackingDomains) || manifest.NSPrivacyTrackingDomains.length !== 0) errors.push('Disabled measurement must not ship tracking domains.');
    for (const entry of types) {
      if (entry[trackingKey] === true || entry[purposeKey]?.some((purpose) => measurementPurposes.includes(purpose))) {
        errors.push('Disabled measurement must not ship tracking or advertising/measurement-purpose declarations.');
      }
      if (measurementTypes.slice(1).includes(entry[typeKey])) errors.push('Disabled measurement must not declare measurement identifiers or interaction events.');
    }
  }
  return errors;
}

export function configuredDocuments(info, manifest, config, enabledTemplate) {
  if (!config || Object.keys(config).length !== 1 || typeof config.enabled !== 'boolean') {
    throw new Error('Configuration must contain exactly an explicit Boolean enabled; never put credentials in this file.');
  }
  const nextInfo = structuredClone(info);
  const nextManifest = structuredClone(manifest);
  if (!Array.isArray(nextManifest.NSPrivacyCollectedDataTypes)) throw new Error('Invalid base privacy manifest.');
  nextInfo[setting] = config.enabled;
  if (config.enabled) {
    const checkedInfo = { ...nextInfo, NSUserTrackingUsageDescription: usageDescription };
    const errors = validateConfiguration(checkedInfo, enabledTemplate ?? {});
    if (errors.length) throw new Error(`Enabled privacy template is missing or invalid: ${errors.join(' ')}`);
    nextInfo.NSUserTrackingUsageDescription = usageDescription;
    nextManifest.NSPrivacyTracking = true;
    nextManifest.NSPrivacyTrackingDomains = [domain];
    for (const name of measurementTypes) {
      const replacement = structuredClone(enabledTemplate.NSPrivacyCollectedDataTypes.find((entry) => entry[typeKey] === name));
      const index = nextManifest.NSPrivacyCollectedDataTypes.findIndex((entry) => entry[typeKey] === name);
      if (index >= 0) nextManifest.NSPrivacyCollectedDataTypes[index] = replacement;
      else nextManifest.NSPrivacyCollectedDataTypes.push(replacement);
    }
  } else {
    delete nextInfo.NSUserTrackingUsageDescription;
    nextManifest.NSPrivacyTracking = false;
    nextManifest.NSPrivacyTrackingDomains = [];
    nextManifest.NSPrivacyCollectedDataTypes = nextManifest.NSPrivacyCollectedDataTypes
      .filter((entry) => !measurementTypes.slice(1).includes(entry[typeKey]))
      .map((entry) => {
        if (entry[typeKey] !== measurementTypes[0]) return entry;
        return { ...entry, [trackingKey]: false, [purposeKey]: entry[purposeKey].filter((purpose) => !measurementPurposes.includes(purpose)) };
      });
  }
  const errors = validateConfiguration(nextInfo, nextManifest);
  if (errors.length) throw new Error(errors.join(' '));
  return { info: nextInfo, manifest: nextManifest };
}

function readPlist(file) {
  return JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }));
}
function plistBytes(document) {
  return execFileSync('/usr/bin/plutil', ['-convert', 'xml1', '-o', '-', '-'], { input: JSON.stringify(document), stdio: ['pipe', 'pipe', 'pipe'] });
}
function main(args) {
  let root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  let configPath;
  let appRoot;
  let check = false;
  for (let index = 0; index < args.length; index++) {
    if (args[index] === '--root') root = path.resolve(args[++index]);
    else if (args[index] === '--configure') configPath = path.resolve(args[++index]);
    else if (args[index] === '--app-root') appRoot = path.resolve(args[++index]);
    else if (args[index] === '--check') check = true;
    else throw new Error('Usage: arkfile-configure-ad-measurement.mjs --check [--root SOURCE] [--app-root APP] | --configure CONFIG.json [--root SOURCE]');
  }
  if (check === Boolean(configPath) || (appRoot && !check)) throw new Error('Choose exactly --check or --configure CONFIG.json.');
  const infoPath = path.join(appRoot ?? root, appRoot ? 'Info.plist' : 'Support/Info.plist');
  const manifestPath = path.join(appRoot ?? root, 'PrivacyInfo.xcprivacy');
  const info = readPlist(infoPath);
  const manifest = readPlist(manifestPath);
  if (check) {
    const errors = validateConfiguration(info, manifest);
    if (errors.length) throw new Error(errors.join(' '));
    console.log(`Ad measurement privacy configuration is coherent (${info[setting] ? 'enabled' : 'disabled'}).`);
    return;
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  // This private operator template is never bundled or needed by a public build.
  const template = config.enabled === true ? readPlist(path.join(root, 'ReleaseInputs/AdMeasurement/PrivacyInfo.enabled.xcprivacy')) : undefined;
  const next = configuredDocuments(info, manifest, config, template);
  const originalInfo = fs.readFileSync(infoPath);
  const originalManifest = fs.readFileSync(manifestPath);
  try {
    fs.writeFileSync(infoPath, plistBytes(next.info));
    fs.writeFileSync(manifestPath, plistBytes(next.manifest));
  } catch (error) {
    fs.writeFileSync(infoPath, originalInfo);
    fs.writeFileSync(manifestPath, originalManifest);
    throw error;
  }
  console.log(`Ad measurement ${config.enabled ? 'enabled' : 'disabled'} in source. A new binary and matching privacy disclosures are required; no service was configured or contacted.`);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}

import crypto from 'node:crypto';

export function stableJSON(value) {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`;
  return JSON.stringify(value);
}
export function digest(value) {
  return crypto.createHash('sha256').update(typeof value === 'string' || Buffer.isBuffer(value) ? value : stableJSON(value)).digest('hex');
}
export function publicLicenseIndex(input) {
  const output = {schemaVersion: 2, entries: input.entries.map(({decision, ...entry}) => entry)};
  return {...output, projectionHash: digest(output)};
}
export function publicCatalog(input, licenseIndex) {
  const output = structuredClone(input);
  output.contentLicenses = {projectionHash: licenseIndex.projectionHash};
  for (const item of Object.values(output.categories).flat()) {
    delete item.contentLicenseLedgerVersion;
    delete item.contentLicenseDecisionStatus;
    if (item.contentLicenseProjectionHash) item.contentLicenseProjectionHash = licenseIndex.projectionHash;
  }
  return output;
}
// A cleanup changes serialized catalog bytes but cannot authorize a different
// title, path, tier, selection, file size, notice or compatibility relationship.
export function catalogRuntimeIdentity(catalog) {
  const copy = structuredClone(catalog);
  delete copy.source;
  delete copy.contentLicenses;
  for (const item of Object.values(copy.categories).flat()) {
    delete item.contentLicenseLedgerVersion;
    delete item.contentLicenseDecisionStatus;
    delete item.contentLicenseProjectionHash;
  }
  return digest(copy);
}

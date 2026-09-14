#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const defaultOutput = resolve(
  repositoryRoot,
  "Support/ArkFileWeather/noaa-nwr-catalog-v1.json"
);
const fields = [
  "ST",
  "STATE",
  "COUNTY",
  "SAME",
  "SITENAME",
  "SITELOC",
  "SITESTATE",
  "FREQ",
  "CALLSIGN",
  "LAT",
  "LON",
  "PWR",
  "STATUS",
  "WFO",
  "REMARKS"
];
const allowedFrequencies = new Set([
  162.400,
  162.425,
  162.450,
  162.475,
  162.500,
  162.525,
  162.550
]);
const allowedStatuses = new Set(["normal", "degraded", "outOfService"]);

function fail(message) {
  process.stderr.write(`Weather radio catalog error: ${message}\n`);
  process.exit(1);
}

function parseArguments(argv) {
  const values = new Map();
  let validateOnly = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--validate-only") {
      validateOnly = true;
      continue;
    }
    if (!argument.startsWith("--")) {
      fail(`Unexpected argument ${argument}`);
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) {
      fail(`Missing value for ${argument}`);
    }
    values.set(argument, value);
    index += 1;
  }
  return { validateOnly, values };
}

function cleanString(value, maximumLength, fieldName) {
  if (typeof value !== "string") {
    fail(`${fieldName} is not a string`);
  }
  const cleaned = value.replace(/[\u0000-\u001F\u007F]/g, " ").trim();
  if (cleaned.length > maximumLength) {
    fail(`${fieldName} exceeds ${maximumLength} characters`);
  }
  return cleaned;
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function stablePayload(catalog) {
  return JSON.stringify({
    schemaVersion: catalog.schemaVersion,
    areas: catalog.areas
  });
}

function parseAssignments(source) {
  const arrays = new Map(fields.map((field) => [field, []]));
  const declarationPattern = /^var ([A-Z]+) = \[\];$/;
  const assignmentPattern = /^([A-Z]+)\[(\d+)\] = ("(?:[^"\\]|\\.)*");$/;
  const declared = new Set();

  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) {
      continue;
    }
    const declaration = line.match(declarationPattern);
    if (declaration) {
      if (!arrays.has(declaration[1])) {
        fail(`Unexpected array declaration ${declaration[1]}`);
      }
      declared.add(declaration[1]);
      continue;
    }
    const assignment = line.match(assignmentPattern);
    if (!assignment || !arrays.has(assignment[1])) {
      fail(`Unrecognized CCL.js line: ${line.slice(0, 120)}`);
    }
    const field = assignment[1];
    const index = Number.parseInt(assignment[2], 10);
    const value = JSON.parse(assignment[3]);
    const target = arrays.get(field);
    if (target[index] !== undefined) {
      fail(`Duplicate ${field}[${index}] assignment`);
    }
    target[index] = value;
  }

  if (declared.size !== fields.length) {
    fail("CCL.js does not declare every expected parallel array");
  }
  const rowCount = arrays.get(fields[0]).length;
  if (rowCount < 100 || rowCount > 20_000) {
    fail(`Unexpected CCL.js row count ${rowCount}`);
  }
  for (const field of fields) {
    const values = arrays.get(field);
    if (values.length !== rowCount || values.some((value) => value === undefined)) {
      fail(`${field} is not aligned with the other CCL.js arrays`);
    }
  }
  return { arrays, rowCount };
}

function parseSameCodes(source) {
  const matches = source.matchAll(
    /(\d{6}),(.+?), ([A-Z]{2})(?=\s+\d{6},|\s*$)/gs
  );
  const codes = new Map();
  for (const match of matches) {
    const code = match[1];
    const county = cleanString(match[2], 120, "SAME county");
    const state = match[3];
    if (codes.has(code)) {
      fail(`Duplicate SAME reference code ${code}`);
    }
    codes.set(code, { county, state });
  }
  if (codes.size < 3_000 || codes.size > 10_000) {
    fail(`Unexpected SAME reference count ${codes.size}`);
  }
  return codes;
}

function normalizedStatus(value) {
  switch (value) {
  case "NORMAL":
    return "normal";
  case "DEGRADED":
    return "degraded";
  case "OUT OF SERVICE":
    return "outOfService";
  default:
    fail(`Unsupported transmitter status ${value}`);
  }
}

function buildCatalog(cclSource, sameSource, metadata) {
  const { arrays, rowCount } = parseAssignments(cclSource);
  const sameCodes = parseSameCodes(sameSource);
  const groups = new Map();
  let sameReferenceMatchCount = 0;
  let sameReferenceMissingCount = 0;
  let noCoverageAssignmentCount = 0;

  for (let index = 0; index < rowCount; index += 1) {
    const stateCode = cleanString(arrays.get("ST")[index], 2, "state code");
    const stateName = cleanString(arrays.get("STATE")[index], 80, "state name");
    const areaName = cleanString(arrays.get("COUNTY")[index], 120, "area name");
    const sameCode = cleanString(arrays.get("SAME")[index], 6, "SAME code");
    if (!/^[A-Z]{2}$/.test(stateCode) || !/^\d{6}$/.test(sameCode)) {
      fail(`Invalid area identity at row ${index}`);
    }
    const canonicalWholeAreaCode = `0${sameCode.slice(1)}`;
    const reference = sameCodes.get(canonicalWholeAreaCode);
    if (reference && reference.state !== stateCode) {
      fail(`SAME reference state disagrees for ${sameCode}`);
    }
    if (reference) {
      sameReferenceMatchCount += 1;
    } else {
      // NOAA's current CCL assignments can lead its separately published
      // SameCode.txt list after county-equivalent changes. Preserve the current
      // CCL row and record the cross-check gap instead of silently dropping
      // coverage.
      sameReferenceMissingCount += 1;
    }

    const key = `${sameCode}|${stateCode}|${areaName}`;
    const isNoCoverageAssignment =
      arrays.get("FREQ")[index] === ""
      && arrays.get("CALLSIGN")[index] === ""
      && /no\s+nwr\s+coverage/i.test(arrays.get("SITENAME")[index]);
    if (isNoCoverageAssignment) {
      if (groups.has(key)) {
        fail(`Conflicting no-coverage assignment for ${key}`);
      }
      groups.set(key, {
        sameCode,
        countyZoneID: `${stateCode}C${sameCode.slice(-3)}`,
        stateCode,
        stateName,
        areaName,
        coverage: "none",
        transmitters: []
      });
      noCoverageAssignmentCount += 1;
      continue;
    }

    const frequencyMHz = Number(arrays.get("FREQ")[index]);
    if (!allowedFrequencies.has(frequencyMHz)) {
      fail(`Invalid NOAA Weather Radio frequency at row ${index}`);
    }
    const transmitterState = cleanString(
      arrays.get("SITESTATE")[index],
      2,
      "transmitter state"
    );
    const callSign = cleanString(arrays.get("CALLSIGN")[index], 12, "call sign");
    if (!/^[A-Z0-9]{3,12}$/.test(callSign) || !/^[A-Z]{2}$/.test(transmitterState)) {
      fail(`Invalid transmitter identity at row ${index}`);
    }
    const powerWatts = Number(arrays.get("PWR")[index]);
    if (!Number.isFinite(powerWatts) || powerWatts < 0 || powerWatts > 100_000) {
      fail(`Invalid transmitter power at row ${index}`);
    }
    const [officeName = "", officeStateRaw = ""] = arrays.get("WFO")[index].split("|");
    const officeState = officeStateRaw.trim().match(/^([A-Z]{2})/)?.[1] ?? "";
    const transmitter = {
      callSign,
      frequencyMHz,
      transmitterName: cleanString(
        arrays.get("SITENAME")[index],
        120,
        "transmitter name"
      ),
      siteLocation: cleanString(
        arrays.get("SITELOC")[index],
        120,
        "site location"
      ),
      siteState: transmitterState,
      powerWatts,
      listedStatus: normalizedStatus(arrays.get("STATUS")[index]),
      weatherForecastOffice: {
        name: cleanString(officeName, 120, "weather forecast office"),
        state: cleanString(officeState, 2, "weather forecast office state")
      },
      coverageRemarks: cleanString(
        arrays.get("REMARKS")[index],
        160,
        "coverage remarks"
      )
    };

    let area = groups.get(key);
    if (!area) {
      area = {
        sameCode,
        countyZoneID: `${stateCode}C${sameCode.slice(-3)}`,
        stateCode,
        stateName,
        areaName,
        coverage: "designated",
        transmitters: []
      };
      groups.set(key, area);
    } else if (area.coverage !== "designated") {
      fail(`Conflicting coverage assignments for ${key}`);
    }
    area.transmitters.push(transmitter);
  }

  const areas = [...groups.values()]
    .map((area) => ({
      ...area,
      transmitters: area.transmitters.sort((left, right) =>
        left.callSign.localeCompare(right.callSign)
          || left.frequencyMHz - right.frequencyMHz
      )
    }))
    .sort((left, right) =>
      left.sameCode.localeCompare(right.sameCode)
        || left.areaName.localeCompare(right.areaName)
    );

  const catalog = {
    schemaVersion: 1,
    generatedAt: metadata.retrievedAt,
    source: {
      cclURL: "https://www.weather.gov/source/nwr/JS/CCL.js",
      sameCodeURL: "https://www.weather.gov/source/nwr/SameCode.txt",
      retrievedAt: metadata.retrievedAt,
      cclLastModified: metadata.cclLastModified,
      cclSHA256: sha256(Buffer.from(cclSource)),
      sameCodeSHA256: sha256(Buffer.from(sameSource)),
      sourceRowCount: rowCount,
      sameReferenceMatchCount,
      sameReferenceMissingCount,
      noCoverageAssignmentCount
    },
    areas
  };
  catalog.payloadSHA256 = sha256(Buffer.from(stablePayload(catalog)));
  validateCatalog(catalog);
  return catalog;
}

function validateCatalog(catalog) {
  if (catalog?.schemaVersion !== 1 || !Array.isArray(catalog.areas)) {
    fail("Unsupported weather radio catalog schema");
  }
  if (catalog.areas.length < 3_000 || catalog.areas.length > 10_000) {
    fail(`Unexpected weather radio area count ${catalog.areas.length}`);
  }
  const expectedChecksum = sha256(Buffer.from(stablePayload(catalog)));
  if (catalog.payloadSHA256 !== expectedChecksum) {
    fail("Weather radio catalog payload checksum does not match");
  }
  if (!catalog.source || !Number.isInteger(catalog.source.sourceRowCount)) {
    fail("Weather radio catalog provenance is incomplete");
  }
  if (
    catalog.source.sameReferenceMatchCount
      + catalog.source.sameReferenceMissingCount
    !== catalog.source.sourceRowCount
  ) {
    fail("Weather radio SAME reference cross-check counts do not add up");
  }

  let transmitterCount = 0;
  const areaKeys = new Set();
  for (const area of catalog.areas) {
    const key = `${area.sameCode}|${area.stateCode}|${area.areaName}`;
    if (areaKeys.has(key)) {
      fail(`Duplicate weather radio area ${key}`);
    }
    areaKeys.add(key);
    if (
      !/^\d{6}$/.test(area.sameCode)
      || !/^[A-Z]{2}C\d{3}$/.test(area.countyZoneID)
      || area.countyZoneID !== `${area.stateCode}C${area.sameCode.slice(-3)}`
      || !Array.isArray(area.transmitters)
      || area.transmitters.length > 50
    ) {
      fail(`Invalid weather radio area ${key}`);
    }
    if (
      (area.coverage === "none" && area.transmitters.length !== 0)
      || (area.coverage === "designated" && area.transmitters.length < 1)
      || !["none", "designated"].includes(area.coverage)
    ) {
      fail(`Invalid coverage state for weather radio area ${key}`);
    }
    for (const transmitter of area.transmitters) {
      transmitterCount += 1;
      if (
        !/^[A-Z0-9]{3,12}$/.test(transmitter.callSign)
        || !allowedFrequencies.has(transmitter.frequencyMHz)
        || !allowedStatuses.has(transmitter.listedStatus)
      ) {
        fail(`Invalid transmitter in weather radio area ${key}`);
      }
    }
  }
  if (
    transmitterCount + catalog.source.noCoverageAssignmentCount
    !== catalog.source.sourceRowCount
  ) {
    fail(
      `Catalog has ${transmitterCount} transmitters and `
        + `${catalog.source.noCoverageAssignmentCount} no-coverage assignments, `
        + "but provenance records "
        + `${catalog.source.sourceRowCount} rows`
    );
  }
}

const { validateOnly, values } = parseArguments(process.argv.slice(2));
const output = resolve(values.get("--output") ?? defaultOutput);

if (validateOnly) {
  const catalog = JSON.parse(readFileSync(output, "utf8"));
  validateCatalog(catalog);
  process.stdout.write(
    `Validated ${catalog.areas.length} NOAA Weather Radio SAME areas from `
      + `${catalog.source.sourceRowCount} official assignments.\n`
  );
  process.exit(0);
}

const inputCCL = values.get("--input-ccl");
const inputSame = values.get("--input-same");
const retrievedAt = values.get("--retrieved-at");
const cclLastModified = values.get("--ccl-last-modified");
if (!inputCCL || !inputSame || !retrievedAt || !cclLastModified) {
  fail(
    "Generation requires --input-ccl, --input-same, --retrieved-at, "
      + "and --ccl-last-modified"
  );
}
if (
  !Number.isFinite(Date.parse(retrievedAt))
  || !Number.isFinite(Date.parse(cclLastModified))
) {
  fail("Source timestamps must be valid ISO-8601 or HTTP dates");
}

const cclSource = readFileSync(resolve(inputCCL), "utf8");
const sameSource = readFileSync(resolve(inputSame), "utf8");
const catalog = buildCatalog(cclSource, sameSource, {
  retrievedAt: new Date(retrievedAt).toISOString(),
  cclLastModified: new Date(cclLastModified).toISOString()
});
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, `${JSON.stringify(catalog, null, 2)}\n`, {
  encoding: "utf8",
  mode: 0o644
});
process.stdout.write(
  `Wrote ${catalog.areas.length} NOAA Weather Radio SAME areas from `
    + `${catalog.source.sourceRowCount} official assignments to ${output}.\n`
);

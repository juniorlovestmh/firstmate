#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(scriptDir, "..");
const policySkill = path.join(root, ".agents/skills/secrets-management/SKILL.md");
const agentsFile = path.join(root, "AGENTS.md");
const policySchema = path.join(root, "docs/secrets-policy.schema.json");
const rolloutSchema = path.join(root, "docs/secrets-rollout.schema.json");
const rolloutFile = path.join(root, "docs/secrets-rollout.json");
const exampleFile = path.join(root, "docs/examples/project-secrets-policy.json");
const serviceTokenTemplate = path.join(root, "docs/examples/doppler-service-token-job.yml");
const oidcTemplate = path.join(root, "docs/examples/doppler-oidc-job.yml");
const standardArtifacts = [
  policySkill,
  path.join(root, ".agents/skills/project-management/SKILL.md"),
  path.join(root, ".github/workflows/ci.yml"),
  agentsFile,
  path.join(root, "README.md"),
  path.join(root, "bin/fm-secrets-check.mjs"),
  path.join(root, "bin/fm-secrets-check.sh"),
  path.join(root, "bin/fm-test-run.sh"),
  path.join(root, "docs/promotion-ladder.md"),
  path.join(root, "docs/scripts.md"),
  policySchema,
  rolloutSchema,
  rolloutFile,
  exampleFile,
  serviceTokenTemplate,
  oidcTemplate,
  path.join(root, "tests/fm-secrets-check.test.sh"),
];

const allowedClassifications = new Set(["doppler", "secretless", "platform-native"]);
const allowedRunners = new Set([
  "owned-linux",
  "owned-macos",
  "github-hosted-public-fork",
  "none",
]);
const allowedIdentities = new Set([
  "none",
  "doppler-service-token",
  "doppler-oidc",
  "provider-oidc",
  "github-job-token",
  "mixed",
]);
const allowedInjections = new Set([
  "none",
  "per-job-doppler-fetch",
  "job-oidc",
  "github-job-context",
  "mixed",
]);
const allowedExceptions = new Set([
  "secretless",
  "provider-oidc",
  "platform-mandated",
  "break-glass",
  "hosted-runner",
  "shared-nonproduction-config",
  "temporary-migration",
  "non-owned-runner-doppler",
]);
const canonicalConfigs = new Set(["dev", "stg", "prd"]);
const expectedBacklogIds = [
  "ci-selfhost-appheat-site-h1",
  "ci-selfhost-bible-agents-h2",
  "ci-selfhost-boostin-h3",
  "ci-selfhost-resume-matcher-h4",
  "ci-selfhost-factory-h5",
  "ci-selfhost-organicops-h6",
  "ci-selfhost-tab-agent-h7",
  "ci-selfhost-macops-registry-h8",
];

function fail(message) {
  process.stderr.write(`fm-secrets-check: ${message}\n`);
  process.exitCode = 1;
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    fail(`${file}: invalid JSON: ${error.message}`);
    return null;
  }
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function parseIsoDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || "");
  if (!match) {
    return null;
  }
  const timestamp = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
  const date = new Date(timestamp);
  return date.toISOString().slice(0, 10) === value ? date : null;
}

function policyToday() {
  return new Date(`${new Date().toISOString().slice(0, 10)}T00:00:00Z`);
}

function validateSchemaDocument(file, expectedTitle) {
  const doc = readJson(file);
  if (!doc) {
    return;
  }
  if (doc.$schema !== "https://json-schema.org/draft/2020-12/schema") {
    fail(`${file}: $schema must be JSON Schema draft 2020-12`);
  }
  if (doc.title !== expectedTitle) {
    fail(`${file}: title must be ${JSON.stringify(expectedTitle)}`);
  }
  if (doc.type !== "object") {
    fail(`${file}: root type must be object`);
  }
  if (!Array.isArray(doc.required) || doc.required.length === 0) {
    fail(`${file}: required must be a non-empty array`);
  }
}

function sameJsonValue(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function schemaTypeMatches(value, type) {
  switch (type) {
    case "null":
      return value === null;
    case "array":
      return Array.isArray(value);
    case "object":
      return value !== null && typeof value === "object" && !Array.isArray(value);
    case "integer":
      return Number.isInteger(value);
    case "number":
      return typeof value === "number" && Number.isFinite(value);
    default:
      return typeof value === type;
  }
}

function schemaPath(parent, key) {
  if (typeof key === "number") {
    return `${parent}[${key}]`;
  }
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key)
    ? `${parent}.${key}`
    : `${parent}[${JSON.stringify(key)}]`;
}

function resolveJsonPointer(document, fragment, ref) {
  if (!fragment) {
    return document;
  }
  if (!fragment.startsWith("/")) {
    throw new Error(`unsupported schema fragment in ${ref}`);
  }
  return fragment
    .slice(1)
    .split("/")
    .map((part) => part.replace(/~1/g, "/").replace(/~0/g, "~"))
    .reduce((value, part) => {
      if (value === undefined || value === null || !(part in value)) {
        throw new Error(`unresolved schema pointer ${ref}`);
      }
      return value[part];
    }, document);
}

const schemaCache = new Map();

function loadSchema(file) {
  if (!schemaCache.has(file)) {
    const document = readJson(file);
    if (!document) {
      return null;
    }
    schemaCache.set(file, document);
  }
  return schemaCache.get(file);
}

function validateSchemaValue(value, schema, sourceFile, instancePath = "$") {
  const errors = [];
  const add = (message) => errors.push(`${instancePath} ${message}`);

  if (typeof schema === "boolean") {
    if (!schema) {
      add("is forbidden by the schema");
    }
    return errors;
  }
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    add("has an invalid schema");
    return errors;
  }

  if (schema.$ref) {
    try {
      const [relativeFile, fragment = ""] = schema.$ref.split("#", 2);
      const refFile = relativeFile
        ? path.resolve(path.dirname(sourceFile), decodeURIComponent(relativeFile))
        : sourceFile;
      const refDocument = loadSchema(refFile);
      if (refDocument) {
        const target = resolveJsonPointer(refDocument, fragment, schema.$ref);
        errors.push(...validateSchemaValue(value, target, refFile, instancePath));
      }
    } catch (error) {
      add(`cannot resolve schema reference ${JSON.stringify(schema.$ref)}: ${error.message}`);
    }
  }

  if ("const" in schema && !sameJsonValue(value, schema.const)) {
    add(`must equal ${JSON.stringify(schema.const)}`);
  }
  if (Array.isArray(schema.enum) && !schema.enum.some((item) => sameJsonValue(value, item))) {
    add(`must be one of ${schema.enum.map((item) => JSON.stringify(item)).join(", ")}`);
  }

  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((type) => schemaTypeMatches(value, type))) {
      add(`must have type ${types.join(" or ")}`);
      return errors;
    }
  }

  if (Array.isArray(schema.allOf)) {
    schema.allOf.forEach((part) => {
      errors.push(...validateSchemaValue(value, part, sourceFile, instancePath));
    });
  }
  if (schema.if) {
    const conditionErrors = validateSchemaValue(value, schema.if, sourceFile, instancePath);
    if (conditionErrors.length === 0 && schema.then) {
      errors.push(...validateSchemaValue(value, schema.then, sourceFile, instancePath));
    } else if (conditionErrors.length > 0 && schema.else) {
      errors.push(...validateSchemaValue(value, schema.else, sourceFile, instancePath));
    }
  }

  if (typeof value === "string") {
    if (Number.isInteger(schema.minLength) && value.length < schema.minLength) {
      add(`must have length at least ${schema.minLength}`);
    }
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) {
      add(`must match ${JSON.stringify(schema.pattern)}`);
    }
    if (schema.format === "date") {
      const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
      const timestamp = match
        ? Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
        : Number.NaN;
      const canonical = Number.isNaN(timestamp)
        ? ""
        : new Date(timestamp).toISOString().slice(0, 10);
      if (canonical !== value) {
        add("must be a valid YYYY-MM-DD date");
      }
    }
  }

  if (Array.isArray(value)) {
    if (Number.isInteger(schema.minItems) && value.length < schema.minItems) {
      add(`must contain at least ${schema.minItems} items`);
    }
    if (Number.isInteger(schema.maxItems) && value.length > schema.maxItems) {
      add(`must contain at most ${schema.maxItems} items`);
    }
    if (schema.uniqueItems) {
      const serialized = value.map((item) => JSON.stringify(item));
      if (new Set(serialized).size !== serialized.length) {
        add("must contain unique items");
      }
    }
    if (schema.items) {
      value.forEach((item, index) => {
        errors.push(
          ...validateSchemaValue(item, schema.items, sourceFile, schemaPath(instancePath, index)),
        );
      });
    }
    if (schema.contains) {
      const matching = value.filter(
        (item, index) =>
          validateSchemaValue(
            item,
            schema.contains,
            sourceFile,
            schemaPath(instancePath, index),
          ).length === 0,
      ).length;
      const minimum = Number.isInteger(schema.minContains) ? schema.minContains : 1;
      if (matching < minimum) {
        add(`must contain at least ${minimum} matching item`);
      }
    }
  }

  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    const properties = schema.properties || {};
    if (Array.isArray(schema.required)) {
      schema.required.forEach((key) => {
        if (!(key in value)) {
          errors.push(`${schemaPath(instancePath, key)} is required`);
        }
      });
    }
    Object.entries(properties).forEach(([key, propertySchema]) => {
      if (key in value) {
        errors.push(
          ...validateSchemaValue(
            value[key],
            propertySchema,
            sourceFile,
            schemaPath(instancePath, key),
          ),
        );
      }
    });
    if (schema.additionalProperties === false) {
      Object.keys(value)
        .filter((key) => !(key in properties))
        .forEach((key) => {
          errors.push(`${schemaPath(instancePath, key)} is not allowed`);
        });
    }
  }

  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) {
      add(`must be at least ${schema.minimum}`);
    }
    if (typeof schema.maximum === "number" && value > schema.maximum) {
      add(`must be at most ${schema.maximum}`);
    }
  }

  return errors;
}

function validateAgainstSchema(doc, schemaFile, label) {
  const schema = loadSchema(schemaFile);
  if (!schema) {
    return [];
  }
  return validateSchemaValue(doc, schema, schemaFile).map((error) => `${label}: ${error}`);
}

function validateManifestSemantics(doc, label, today = policyToday()) {
  const errors = [];
  const add = (field, message) => errors.push(`${label}: ${field} ${message}`);

  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    add("$", "must be an object");
    return errors;
  }
  if (doc.schemaVersion !== 1) {
    add("schemaVersion", "must equal 1");
  }
  if (!nonEmptyString(doc.project)) {
    add("project", "must be a non-empty string");
  }
  if (!nonEmptyString(doc.repository) || !doc.repository.includes("/")) {
    add("repository", "must be an owner/name string");
  }
  if (doc.repositoryVisibility !== "private" && doc.repositoryVisibility !== "public") {
    add("repositoryVisibility", "must be private or public");
  }
  if (!["none", "pull-request", "pull-request-target"].includes(doc.forkExposure)) {
    add("forkExposure", "must be none, pull-request, or pull-request-target");
  }
  if (!allowedClassifications.has(doc.classification)) {
    add("classification", `must be one of ${[...allowedClassifications].join(", ")}`);
  }

  if (!doc.doppler || typeof doc.doppler !== "object" || Array.isArray(doc.doppler)) {
    add("doppler", "must be an object");
  } else {
    if (doc.doppler.project !== null && !nonEmptyString(doc.doppler.project)) {
      add("doppler.project", "must be null or a non-empty string");
    }
    if (!Array.isArray(doc.doppler.configs)) {
      add("doppler.configs", "must be an array");
    } else {
      const seen = new Set();
      doc.doppler.configs.forEach((config, index) => {
        if (!canonicalConfigs.has(config)) {
          add(`doppler.configs[${index}]`, "must be dev, stg, or prd");
        }
        if (seen.has(config)) {
          add(`doppler.configs[${index}]`, "must be unique");
        }
        seen.add(config);
      });
      if (doc.classification === "doppler" && doc.doppler.configs.length === 0) {
        add("doppler.configs", "must not be empty for a Doppler project");
      }
      if (doc.classification === "secretless" && doc.doppler.configs.length !== 0) {
        add("doppler.configs", "must be empty for a secretless project");
      }
    }
    if (doc.classification === "doppler" && !nonEmptyString(doc.doppler.project)) {
      add("doppler.project", "must name the project for classification doppler");
    }
    if (doc.classification === "secretless" && doc.doppler.project !== null) {
      add("doppler.project", "must be null for a secretless project");
    }
  }

  if (!doc.ci || typeof doc.ci !== "object" || Array.isArray(doc.ci)) {
    add("ci", "must be an object");
  } else {
    if (!allowedRunners.has(doc.ci.runner)) {
      add("ci.runner", `must be one of ${[...allowedRunners].join(", ")}`);
    }
    if (!allowedIdentities.has(doc.ci.identity)) {
      add("ci.identity", `must be one of ${[...allowedIdentities].join(", ")}`);
    }
    if (!allowedInjections.has(doc.ci.injection)) {
      add("ci.injection", `must be one of ${[...allowedInjections].join(", ")}`);
    }
  }

  if (!Array.isArray(doc.exceptions)) {
    add("exceptions", "must be an array");
  } else {
    doc.exceptions.forEach((exception, index) => {
      if (!exception || typeof exception !== "object" || Array.isArray(exception)) {
        add(`exceptions[${index}]`, "must be an object");
        return;
      }
      if (!allowedExceptions.has(exception.kind)) {
        add(`exceptions[${index}].kind`, `must be one of ${[...allowedExceptions].join(", ")}`);
      }
      if (!nonEmptyString(exception.scope)) {
        add(`exceptions[${index}].scope`, "must be a non-empty string");
      }
      if (!nonEmptyString(exception.reason)) {
        add(`exceptions[${index}].reason`, "must be a non-empty string");
      }
      if (exception.kind === "temporary-migration") {
        const reviewDate = parseIsoDate(exception.reviewBy);
        if (!reviewDate) {
          add(`exceptions[${index}].reviewBy`, "must be a YYYY-MM-DD date");
        } else {
          const latestReview = new Date(today);
          latestReview.setUTCDate(latestReview.getUTCDate() + 90);
          if (reviewDate < today || reviewDate > latestReview) {
            add(
              `exceptions[${index}].reviewBy`,
              "must be today or within the next 90 days",
            );
          }
        }
        if (!nonEmptyString(exception.removalCondition)) {
          add(`exceptions[${index}].removalCondition`, "must be a non-empty string");
        }
      }
      if (exception.kind === "non-owned-runner-doppler" && !nonEmptyString(exception.workflow)) {
        add(`exceptions[${index}].workflow`, "must identify the exceptional workflow");
      }
    });
    if (
      doc.classification === "secretless" &&
      !doc.exceptions.some((exception) => exception?.kind === "secretless")
    ) {
      add("exceptions", "must document the secretless reason");
    }
    if (
      doc.classification === "platform-native" &&
      !doc.exceptions.some((exception) => exception?.kind === "platform-mandated")
    ) {
      add("exceptions", "must document the platform-mandated reason");
    }
  }

  if (!doc.review || typeof doc.review !== "object" || Array.isArray(doc.review)) {
    add("review", "must be an object");
  } else {
    if (!nonEmptyString(doc.review.owner)) {
      add("review.owner", "must be a non-empty string");
    }
    if (
      !Number.isInteger(doc.review.cadenceDays) ||
      doc.review.cadenceDays < 1 ||
      doc.review.cadenceDays > 90
    ) {
      add("review.cadenceDays", "must be an integer from 1 through 90");
    }
  }

  if (doc.ci && typeof doc.ci === "object" && !Array.isArray(doc.ci)) {
    const expectedInjection = new Map([
      ["none", "none"],
      ["doppler-service-token", "per-job-doppler-fetch"],
      ["doppler-oidc", "job-oidc"],
      ["provider-oidc", "job-oidc"],
      ["github-job-token", "github-job-context"],
      ["mixed", "mixed"],
    ]).get(doc.ci.identity);
    if (expectedInjection && doc.ci.injection !== expectedInjection) {
      add("ci.injection", `must be ${expectedInjection} for identity ${doc.ci.identity}`);
    }
    const secretBearingIdentity =
      doc.ci.identity === "doppler-service-token" || doc.ci.identity === "doppler-oidc";
    const ownedRunner = doc.ci.runner === "owned-linux" || doc.ci.runner === "owned-macos";
    const hostedException = Array.isArray(doc.exceptions)
      ? doc.exceptions.some((exception) => exception?.kind === "hosted-runner")
      : false;
    const overrideUnavailable =
      doc.repositoryVisibility !== "private" || doc.forkExposure !== "none" || hostedException;
    const declaredOverride = Array.isArray(doc.exceptions)
      ? doc.exceptions.some((exception) => exception?.kind === "non-owned-runner-doppler")
      : false;
    if (declaredOverride && overrideUnavailable) {
      add(
        "exceptions",
        "non-owned-runner-doppler is unavailable for public or fork-exposed repositories and hosted-runner exceptions",
      );
    }
    if (secretBearingIdentity && !ownedRunner) {
      add("ci.runner", "Doppler secret injection requires an owned runner");
    }
  }

  return errors;
}

function validateManifest(doc, label) {
  return [
    ...validateAgainstSchema(doc, policySchema, label),
    ...validateManifestSemantics(doc, label),
  ];
}

const ownedWorkflowTargets = new Set([
  "[self-hosted, Linux, X64, fleet-ci]",
  "[self-hosted, macOS, ARM64, fleet-ci]",
]);

function dopplerWorkflowPermitted({ runner, triggerTrust, repositoryVisibility, forkExposure }) {
  return (
    ownedWorkflowTargets.has(runner) &&
    triggerTrust === "trusted-only" &&
    repositoryVisibility === "private" &&
    forkExposure === "none"
  );
}

function workflowTriggerTrust(content) {
  const lines = content.split(/\r?\n/);
  const onIndex = lines.findIndex((line) => /^on:\s*/.test(line));
  if (onIndex === -1) {
    return "unknown";
  }
  const inline = lines[onIndex].replace(/^on:\s*/, "").trim();
  const allowed = new Set(["push", "workflow_dispatch"]);
  const forkEvents = new Set(["pull_request", "pull_request_target"]);
  const classify = (events) => {
    if (events.some((event) => forkEvents.has(event))) {
      return "fork-originated";
    }
    return events.length > 0 && events.every((event) => allowed.has(event))
      ? "trusted-only"
      : "unknown";
  };
  if (inline) {
    if (inline.startsWith("[") && inline.endsWith("]")) {
      return classify(
        inline
          .slice(1, -1)
          .split(",")
          .map((event) => event.trim().replace(/^['\"]|['\"]$/g, ""))
          .filter(Boolean),
      );
    }
    return classify([inline.replace(/^['\"]|['\"]$/g, "")]);
  }
  const events = [];
  for (let index = onIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (/^\S/.test(line) && line.trim() !== "") {
      break;
    }
    if (line.trim() === "" || /^\s*#/.test(line)) {
      continue;
    }
    const event = /^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$/.exec(line);
    if (!event) {
      return "unknown";
    }
    events.push(event[1]);
  }
  return classify(events);
}

function workflowJobs(content) {
  const lines = content.split(/\r?\n/);
  const jobs = [];
  const structuralErrors = [];
  let inJobs = false;
  let current = null;
  lines.forEach((line) => {
    if (/^jobs:\s*$/.test(line)) {
      inJobs = true;
      return;
    }
    if (!inJobs) {
      return;
    }
    if (line.trim() === "" || /^\s*#/.test(line)) {
      return;
    }
    const jobMatch = /^  ([A-Za-z0-9_-]+):\s*$/.exec(line);
    if (jobMatch) {
      current = { name: jobMatch[1], lines: [] };
      jobs.push(current);
      return;
    }
    if (/^\S/.test(line)) {
      inJobs = false;
      current = null;
      return;
    }
    if (/^  \S/.test(line)) {
      structuralErrors.push(line.trim());
      current = null;
      return;
    }
    if (current) {
      current.lines.push(line);
    }
  });
  return { jobs, structuralErrors };
}

function validateTrackedWorkflows(workflowFiles, readTracked, manifest, projectLabel) {
  const verdicts = [];
  const verdictNames = new Set();
  const recordVerdict = (workflowFile, verdict) => {
    if (verdict !== "permit-with-proof" && verdict !== "refuse") {
      fail(`${projectLabel}/${workflowFile}: invalid workflow validation verdict`);
    }
    if (verdictNames.has(workflowFile)) {
      fail(`${projectLabel}/${workflowFile}: duplicate workflow validation verdict`);
    }
    verdictNames.add(workflowFile);
    verdicts.push({ workflowFile, verdict });
  };

  workflowFiles.forEach((workflowFile) => {
    const content = readTracked(workflowFile);
    if (content === null) {
      fail(`${projectLabel}/${workflowFile}: tracked workflow is unavailable for validation`);
      recordVerdict(workflowFile, "refuse");
      return;
    }
    const parsed = workflowJobs(content);
    const hasDopplerReference =
      /dopplerhq\/secrets-fetch-action@|doppler-token:\s*|auth-method:\s*oidc\b/.test(content);
    if (parsed.jobs.length === 0 || parsed.structuralErrors.length > 0) {
      fail(
        `${projectLabel}/${workflowFile}: workflow requires an unambiguous parsed jobs structure`,
      );
      recordVerdict(workflowFile, "refuse");
      return;
    }
    let injectingJobs = 0;
    let permitted = true;
    const triggerTrust = workflowTriggerTrust(content);
    parsed.jobs.forEach((job) => {
      const jobText = job.lines.join("\n");
      const usesDoppler = /uses:\s*dopplerhq\/secrets-fetch-action@/.test(jobText);
      const usesServiceToken = /doppler-token:\s*\$\{\{\s*secrets\.[^}]+\}\}/.test(jobText);
      const usesOidc = /auth-method:\s*oidc\b/.test(jobText);
      if (!usesDoppler || (!usesServiceToken && !usesOidc)) {
        return;
      }
      injectingJobs += 1;

      const runnerMatches = job.lines.filter((line) => /^    runs-on:\s*/.test(line));
      const runner = runnerMatches.length === 1 ? runnerMatches[0].replace(/^    runs-on:\s*/, "").trim() : null;
      if (
        !dopplerWorkflowPermitted({
          runner,
          triggerTrust,
          repositoryVisibility: manifest?.repositoryVisibility,
          forkExposure: manifest?.forkExposure,
        })
      ) {
        permitted = false;
        fail(
          `${projectLabel}/${workflowFile} job ${job.name}: Doppler injection requires an owned runner, trusted-only trigger, private repository, and no fork exposure (runner=${runner ?? "unknown"} trigger=${triggerTrust} visibility=${manifest?.repositoryVisibility ?? "unknown"} forkExposure=${manifest?.forkExposure ?? "unknown"})`,
        );
      }
    });
    if (hasDopplerReference && injectingJobs === 0) {
      permitted = false;
      fail(`${projectLabel}/${workflowFile}: Doppler references were not confined to a parsed injecting job`);
    }
    recordVerdict(workflowFile, permitted ? "permit-with-proof" : "refuse");
  });

  const expectedNames = new Set(workflowFiles);
  if (expectedNames.size !== workflowFiles.length) {
    fail(`${projectLabel}: authoritative workflow enumeration contains duplicates`);
  }
  if (verdicts.length !== workflowFiles.length || verdictNames.size !== expectedNames.size) {
    fail(`${projectLabel}: workflow validation verdict set is incomplete`);
  }
  expectedNames.forEach((workflowFile) => {
    if (!verdictNames.has(workflowFile)) {
      fail(`${projectLabel}/${workflowFile}: authoritative workflow has no validation verdict`);
    }
  });
  return verdicts;
}

function validateRollout() {
  const rollout = readJson(rolloutFile);
  if (!rollout) {
    return 0;
  }
  validateAgainstSchema(rollout, rolloutSchema, rolloutFile).forEach(fail);
  if (rollout.schemaVersion !== 1) {
    fail(`${rolloutFile}: schemaVersion must equal 1`);
  }
  if (rollout.standard !== "doppler-default-v1") {
    fail(`${rolloutFile}: standard must equal doppler-default-v1`);
  }
  const assessment = rollout.oidcAssessment;
  if (
    !assessment ||
    assessment.decisionOwner !== "captain" ||
    assessment.status !== "recommendation-only"
  ) {
    fail(`${rolloutFile}: paid OIDC must remain a captain-owned recommendation only`);
  }
  if (
    assessment.recommendation !== "consider-oidc-to-remove-stored-doppler-ci-tokens" ||
    assessment.pricingCheckedOn !== "2026-07-27" ||
    assessment.teamPriceUsdPerUserMonth !== 21 ||
    assessment.enterprisePrice !== "custom" ||
    assessment.pricingUrl !== "https://www.doppler.com/pricing"
  ) {
    fail(`${rolloutFile}: OIDC assessment must record the dated public paid-plan cost`);
  }
  if (!nonEmptyString(assessment.reasoning) || !nonEmptyString(assessment.shippedDefault)) {
    fail(`${rolloutFile}: OIDC assessment must include reasoning and the shipped default`);
  }
  if (
    !assessment.shippedDefault.includes("read-only service token") ||
    !assessment.shippedDefault.includes("no Team-plan")
  ) {
    fail(`${rolloutFile}: shipped default must remain service-token based and paid-plan independent`);
  }
  if (!Array.isArray(rollout.projects)) {
    fail(`${rolloutFile}: projects must be an array`);
    return 0;
  }

  const ids = [];
  const projectNames = new Set();
  rollout.projects.forEach((project, index) => {
    validateManifestSemantics(project, `${rolloutFile}: projects[${index}]`).forEach(fail);
    if (!nonEmptyString(project.backlogId)) {
      fail(`${rolloutFile}: projects[${index}].backlogId must be a non-empty string`);
    } else {
      ids.push(project.backlogId);
    }
    if (projectNames.has(project.project)) {
      fail(`${rolloutFile}: duplicate project ${project.project}`);
    }
    projectNames.add(project.project);
    for (const field of ["currentState", "targetState"]) {
      if (!nonEmptyString(project[field])) {
        fail(`${rolloutFile}: projects[${index}].${field} must be a non-empty string`);
      }
    }
    for (const field of ["rollout", "validation"]) {
      if (
        !Array.isArray(project[field]) ||
        project[field].length === 0 ||
        project[field].some((item) => !nonEmptyString(item))
      ) {
        fail(`${rolloutFile}: projects[${index}].${field} must contain non-empty strings`);
      }
    }
  });

  const actualIds = [...ids].sort();
  const expectedIds = [...expectedBacklogIds].sort();
  if (JSON.stringify(actualIds) !== JSON.stringify(expectedIds)) {
    fail(`${rolloutFile}: backlog IDs must match the eight ci-selfhost migrations exactly`);
  }
  return rollout.projects.length;
}

const leakRules = [
  ["private-key", /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/],
  ["doppler-service-token", /\bdp\.(?:st|sa|ct)\.[A-Za-z0-9._-]{12,}\b/],
  ["github-token", /\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/],
  ["aws-access-key", /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
  ["stripe-live-key", /\b(?:sk|rk)_live_[A-Za-z0-9]{16,}\b/],
  ["slack-token", /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/],
  [
    "credential-assignment",
    /\b(?:DOPPLER_TOKEN|OP_SERVICE_ACCOUNT_TOKEN|GH_TOKEN|AWS_SECRET_ACCESS_KEY|GOOGLE_APPLICATION_CREDENTIALS)\s*=\s*(?!(?:\$\{|["']?\$|<|example|synthetic|redacted|REDACTED))[^"' \t\r\n]{12,}/,
  ],
];

function scanFile(file) {
  let content;
  try {
    content = fs.readFileSync(file, "utf8");
  } catch (error) {
    fail(`${file}: cannot read: ${error.message}`);
    return 0;
  }
  let findings = 0;
  content.split(/\r?\n/).forEach((line, index) => {
    leakRules.forEach(([name, pattern]) => {
      if (pattern.test(line)) {
        process.stderr.write(`${file}:${index + 1}: ${name}\n`);
        findings += 1;
      }
    });
  });
  return findings;
}

function leakScan(files) {
  if (files.length === 0) {
    fail("leak-scan requires at least one path");
    return;
  }
  let findings = 0;
  files.forEach((file) => {
    const resolved = path.resolve(file);
    findings += scanFile(resolved);
  });
  if (findings > 0) {
    process.exitCode = 1;
  } else {
    process.stdout.write(`leak-scan: ok files=${files.length}\n`);
  }
}

function validatePolicyPointers() {
  const skill = fs.readFileSync(policySkill, "utf8");
  const agents = fs.readFileSync(agentsFile, "utf8");
  const requiredPhrases = [
    "single owner of Firstmate's secrets-management policy",
    "Doppler is the default source of truth",
    "The runner host remains credential-free.",
    "Config-scoped read-only service tokens are the shipped CI default.",
    "Whether that benefit justifies the paid plan is the captain's decision.",
    "Team at $21 per user per month",
    "1Password is only the sealed break-glass store",
  ];
  requiredPhrases.forEach((phrase) => {
    if (!skill.includes(phrase)) {
      fail(`${policySkill}: missing required contract phrase ${JSON.stringify(phrase)}`);
    }
  });
  const trigger =
    "- `secrets-management` - load before project intake or initialization and before work that handles credentials or adds secret access to CI or deployment.";
  if ((agents.match(new RegExp(trigger.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g")) || []).length !== 1) {
    fail(`${agentsFile}: secrets-management trigger must appear exactly once`);
  }
}

function validateJobTemplates() {
  const actionPin =
    "dopplerhq/secrets-fetch-action@cd2efbf9a404504316435873eff298b82f7e0562";
  const checkoutPin =
    "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd";
  const service = fs.readFileSync(serviceTokenTemplate, "utf8");
  const oidc = fs.readFileSync(oidcTemplate, "utf8");
  for (const [file, content] of [
    [serviceTokenTemplate, service],
    [oidcTemplate, oidc],
  ]) {
    if (!content.includes("runs-on: [self-hosted, Linux, X64, fleet-ci]")) {
      fail(`${file}: must use the complete owned Linux runner label set`);
    }
    if (!content.includes(actionPin)) {
      fail(`${file}: must pin the audited Doppler fetch action commit`);
    }
    if (!content.includes("inject-env-vars: true")) {
      fail(`${file}: must inject fetched values only into the job environment`);
    }
    if (
      !content.includes(
        "if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'",
      )
    ) {
      fail(`${file}: secret-bearing job must allow only explicit trusted event classes`);
    }
    const checkoutIndex = content.indexOf(`uses: ${checkoutPin}`);
    const dopplerIndex = content.indexOf(actionPin);
    if (checkoutIndex === -1 || checkoutIndex > dopplerIndex) {
      fail(`${file}: trusted code checkout must precede Doppler secret injection`);
    }
  }
  if (!service.includes("doppler-token: ${{ secrets.DOPPLER_TOKEN }}")) {
    fail(`${serviceTokenTemplate}: must read the environment-scoped service token`);
  }
  if (/^env:\s*[\r\n]+\s+DOPPLER_TOKEN:/m.test(service)) {
    fail(`${serviceTokenTemplate}: must not place DOPPLER_TOKEN in workflow or job env`);
  }
  for (const phrase of [
    "Optional paid-plan reference only",
    "not the shipped default",
    "id-token: write",
    "auth-method: oidc",
    "doppler-identity-id: ${{ vars.DOPPLER_SERVICE_IDENTITY_ID }}",
  ]) {
    if (!oidc.includes(phrase)) {
      fail(`${oidcTemplate}: missing ${JSON.stringify(phrase)}`);
    }
  }
}

function validateStandard() {
  validateSchemaDocument(policySchema, "Firstmate Project Secrets Policy");
  validateSchemaDocument(rolloutSchema, "Firstmate Secrets Rollout");
  const example = readJson(exampleFile);
  if (example) {
    validateManifest(example, exampleFile).forEach(fail);
  }
  validatePolicyPointers();
  validateJobTemplates();
  const projects = validateRollout();
  leakScan(standardArtifacts);
  if (!process.exitCode) {
    process.stdout.write(`secrets-standard: ok projects=${projects}\n`);
  }
}

function validateOneManifest(file, today = policyToday()) {
  const resolved = path.resolve(file);
  const doc = readJson(resolved);
  if (doc) {
    validateManifestSemantics(doc, resolved, today).forEach(fail);
    validateAgainstSchema(doc, policySchema, resolved).forEach(fail);
    scanFile(resolved);
  }
  if (!process.exitCode) {
    process.stdout.write(`manifest: ok ${resolved}\n`);
  }
}

function inventoryProject(directory) {
  const resolved = path.resolve(directory);
  let files;
  try {
    files = execFileSync("git", ["-C", resolved, "ls-files", "-z"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })
      .split("\0")
      .filter(Boolean);
  } catch {
    fail(`${resolved}: inventory requires a git worktree`);
    return;
  }
  const workflowFiles = files.filter((file) => /^\.github\/workflows\/.*\.ya?ml$/.test(file));
  let doppler = false;
  let secretContext = false;
  let oidc = false;
  const readTracked = (file) => {
    try {
      return execFileSync("git", ["-C", resolved, "show", `HEAD:${file}`], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        maxBuffer: 4 * 1024 * 1024,
      });
    } catch {
      return null;
    }
  };
  files.forEach((file) => {
    if (doppler && secretContext && oidc) {
      return;
    }
    const content = readTracked(file);
    if (content === null) return;
    doppler ||= /doppler/i.test(content);
    secretContext ||= /\bsecrets\.[A-Za-z_][A-Za-z0-9_]*/.test(content);
    oidc ||= /id-token|workload_identity|oidc/i.test(content);
  });
  let manifestDoc = null;
  if (files.includes("docs/secrets-policy.json")) {
    try {
      manifestDoc = JSON.parse(readTracked("docs/secrets-policy.json"));
      validateManifest(manifestDoc, `${resolved}/docs/secrets-policy.json`).forEach(fail);
    } catch (error) {
      fail(`${resolved}/docs/secrets-policy.json: invalid JSON: ${error.message}`);
    }
  }
  validateTrackedWorkflows(workflowFiles, readTracked, manifestDoc, resolved);
  const manifest = manifestDoc ? "present" : "absent";
  process.stdout.write(
    `secrets-inventory: project=${path.basename(resolved)} workflows=${workflowFiles.length} doppler_refs=${doppler} secret_refs=${secretContext} oidc_refs=${oidc} manifest=${manifest}\n`,
  );
}

const [command = "standard", ...args] = process.argv.slice(2);
switch (command) {
  case "standard":
    if (args.length !== 0) {
      fail("standard accepts no arguments");
    } else {
      validateStandard();
    }
    break;
  case "manifest":
    if (args.length !== 1) {
      fail("manifest requires exactly one path");
    } else {
      validateOneManifest(args[0]);
    }
    break;
  case "test-manifest-fixture":
    if (args.length !== 2) {
      fail("test-manifest-fixture requires a manifest path and fixed YYYY-MM-DD date");
    } else {
      const today = parseIsoDate(args[1]);
      if (!today) {
        fail("test-manifest-fixture requires a valid fixed YYYY-MM-DD date");
      } else {
        validateOneManifest(args[0], today);
      }
    }
    break;
  case "inventory":
    if (args.length !== 1) {
      fail("inventory requires exactly one project directory");
    } else {
      inventoryProject(args[0]);
    }
    break;
  case "leak-scan":
    leakScan(args);
    break;
  default:
    fail(`unknown command ${JSON.stringify(command)}`);
}

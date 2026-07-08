#!/usr/bin/env node

import { readFile, readdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

const config = {
  nodeReleaseIndexPath: process.env.NODE_RELEASE_INDEX_PATH ?? "",
  nodeReleaseIndexUrl:
    process.env.NODE_RELEASE_INDEX_URL ??
    "https://nodejs.org/download/release/index.json",
  dockerHubApiUrl:
    process.env.DOCKER_HUB_API_URL ?? "https://hub.docker.com/v2/repositories",
  pypiApiUrl: process.env.PYPI_API_URL ?? "https://pypi.org/pypi",
  dockerTagPageSize: Number(process.env.DOCKER_TAG_PAGE_SIZE ?? 100),
  maxDockerTagPages: Number(process.env.MAX_DOCKER_TAG_PAGES ?? 5),
  discoveryReportPath: process.env.DISCOVERY_REPORT_PATH ?? "",
};

const images = {
  secrets: {
    dir: "node/secrets",
    variables: ["NODE_VERSION", "INFISICAL_VERSION", "IMAGE_TAGS"],
    tools: ["INFISICAL_VERSION"],
  },
  security: {
    dir: "node/security",
    variables: [
      "NODE_VERSION",
      "GITLEAKS_VERSION",
      "GRYPE_VERSION",
      "SEMGREP_VERSION",
      "SYFT_VERSION",
      "TRIVY_VERSION",
      "IMAGE_TAGS",
    ],
    tools: [
      "GITLEAKS_VERSION",
      "GRYPE_VERSION",
      "SEMGREP_VERSION",
      "SYFT_VERSION",
      "TRIVY_VERSION",
    ],
  },
};

const toolSources = {
  INFISICAL_VERSION: { type: "docker", name: "infisical/cli" },
  GITLEAKS_VERSION: { type: "docker", name: "zricethezav/gitleaks" },
  GRYPE_VERSION: { type: "docker", name: "anchore/grype" },
  SEMGREP_VERSION: { type: "pypi", name: "semgrep" },
  SYFT_VERSION: { type: "docker", name: "anchore/syft" },
  TRIVY_VERSION: { type: "docker", name: "aquasec/trivy" },
};

const toolVersionCache = new Map();

// ---------- HTTP helpers ----------

const fetchJson = async (url) => {
  const res = await fetch(url, { headers: { accept: "application/json" } });

  if (!res.ok) {
    throw new Error(`Request failed (${res.status}) for ${url}`);
  }

  return res.json();
};

const fetchDockerTags = async (repo) => {
  const tags = [];
  const tagUrl = new URL(`${config.dockerHubApiUrl}/${repo}/tags`);
  tagUrl.searchParams.set("page_size", String(config.dockerTagPageSize));
  let url = tagUrl.toString();

  for (let page = 0; url && page < config.maxDockerTagPages; page++) {
    const data = await fetchJson(url);

    tags.push(...(data.results ?? []).map((t) => t.name).filter(Boolean));
    url = data.next ?? "";
  }

  return tags;
};

const fetchPypiVersions = async (pkg) => {
  const data = await fetchJson(`${config.pypiApiUrl}/${pkg}/json`);

  return Object.entries(data.releases ?? {})
    .filter(([, files]) => files.some((file) => !file.yanked))
    .map(([version]) => version);
};

const dockerTagExists = async (repo, tag) => {
  const res = await fetch(`${config.dockerHubApiUrl}/${repo}/tags/${tag}`);

  if (res.status === 404) {
    return false;
  }

  if (!res.ok) {
    throw new Error(
      `Docker tag check failed (${res.status}) for ${repo}:${tag}`,
    );
  }

  return true;
};

const fetchToolVersions = (variable) => {
  if (toolVersionCache.has(variable)) {
    return toolVersionCache.get(variable);
  }

  const source = toolSources[variable];

  if (!source) {
    throw new Error(`Unsupported tool variable '${variable}'.`);
  }

  const versions =
    source.type === "docker"
      ? fetchDockerTags(source.name)
      : source.type === "pypi"
        ? fetchPypiVersions(source.name)
        : null;

  if (!versions) {
    throw new Error(`Unsupported source type '${source.type}'.`);
  }

  toolVersionCache.set(variable, versions);

  return versions;
};

// ---------- Version helpers ----------

const parseVersion = (version) => {
  const m = String(version).match(/^v?(\d+)\.(\d+)\.(\d+)$/);

  return m && { major: +m[1], minor: +m[2], patch: +m[3] };
};

const compareVersions = (a, b) =>
  a.major - b.major || a.minor - b.minor || a.patch - b.patch;

const formatVersion = ({ major, minor, patch }) => `${major}.${minor}.${patch}`;

const versionPrefix = (version) => (String(version).startsWith("v") ? "v" : "");

const classifyUpdate = (currentVersion, latestVersion) => {
  const current = parseVersion(currentVersion);
  const latest = parseVersion(latestVersion);

  if (!current || !latest) {
    return "invalid-version";
  } else if (latest.major !== current.major) {
    return "different-major";
  } else if (latest.minor > current.minor) {
    return "minor";
  } else if (latest.minor === current.minor && latest.patch > current.patch) {
    return "patch";
  } else if (latest.minor === current.minor && latest.patch === current.patch) {
    return "no-op";
  } else {
    return "ahead-of-release-index";
  }
};

const selectSemver = (versions, currentVersion, scope, desiredPrefix) => {
  const current = parseVersion(currentVersion);

  if (!current) {
    return "";
  }

  const best = [...versions, currentVersion]
    .map((raw) => parseVersion(raw))
    .filter(
      (candidate) =>
        candidate &&
        (scope === "new-major" ||
          (candidate.major === current.major &&
            (scope === "minor" || candidate.minor === current.minor))),
    )
    .sort(compareVersions)
    .at(-1);

  return best ? `${desiredPrefix}${formatVersion(best)}` : "";
};

const readNodeReleaseIndex = async () =>
  config.nodeReleaseIndexPath
    ? JSON.parse(await readFile(config.nodeReleaseIndexPath, "utf8"))
    : fetchJson(config.nodeReleaseIndexUrl);

// ---------- Env file discovery ----------

const parseEnvFile = async (image, path) => {
  const variables = {};

  for (const line of (await readFile(path, "utf8")).split("\n")) {
    const match = line.match(/^([A-Z_]+)=(.*)$/);

    if (match) {
      variables[match[1]] = match[2];
    }
  }

  return {
    image,
    path,
    major: Number(basename(path)),
    nodeVersion: variables.NODE_VERSION ?? "",
    variables,
  };
};

const collectEnvFiles = async () => {
  const files = [];

  for (const [image, meta] of Object.entries(images)) {
    let entries = [];

    try {
      entries = await readdir(meta.dir, { withFileTypes: true });
    } catch (error) {
      if (error.code === "ENOENT") {
        continue;
      }

      throw error;
    }

    for (const entry of entries) {
      if (entry.isFile() && /^\d+$/.test(entry.name)) {
        files.push(await parseEnvFile(image, join(meta.dir, entry.name)));
      }
    }
  }

  return files.sort(
    (a, b) => a.major - b.major || a.image.localeCompare(b.image),
  );
};

const latestEnvFile = (envFiles, image) =>
  envFiles
    .filter((f) => f.image === image)
    .sort((a, b) => a.major - b.major)
    .at(-1) ?? null;

const latestEvenNodeReleases = (releaseIndex) => {
  const latestByMajor = new Map();

  for (const release of releaseIndex) {
    const parsed = parseVersion(release.version);

    if (!parsed || parsed.major % 2 !== 0) {
      continue;
    }

    const current = latestByMajor.get(parsed.major);

    if (!current || compareVersions(parsed, current) > 0) {
      latestByMajor.set(parsed.major, {
        ...parsed,
        version: formatVersion(parsed),
      });
    }
  }

  return [...latestByMajor.values()].sort(compareVersions);
};

// ---------- Update preparation ----------

const createUpdate = (
  image,
  release,
  existing,
  template,
  maxSupportedMajor,
) => {
  if (existing) {
    const classification = classifyUpdate(
      existing.nodeVersion,
      release.version,
    );

    if (classification !== "minor" && classification !== "patch") {
      return null;
    }

    return {
      image,
      major: release.major,
      path: existing.path,
      currentNodeVersion: existing.nodeVersion,
      latestNodeVersion: release.version,
      classification,
      variables: existing.variables,
    };
  }

  if (
    !template ||
    maxSupportedMajor === null ||
    release.major < maxSupportedMajor
  ) {
    return null;
  }

  return {
    image,
    major: release.major,
    path: join(images[image].dir, String(release.major)),
    currentNodeVersion: "",
    latestNodeVersion: release.version,
    classification: "new-major",
    variables: template.variables,
  };
};

const resolveToolUpdates = async (image, variables, classification) => {
  const resolved = await Promise.all(
    images[image].tools.map(async (tool) => {
      const current = variables[tool];

      if (!current) {
        throw new Error(`Missing ${tool} in ${image} variables.`);
      }

      let versions;

      try {
        versions = await fetchToolVersions(tool);
      } catch (error) {
        throw new Error(`${tool}: ${error.message}`);
      }

      const selected = selectSemver(
        versions,
        current,
        classification,
        versionPrefix(current),
      );

      if (!selected) {
        throw new Error(`no eligible version for ${tool}`);
      }

      return { variable: tool, current, selected };
    }),
  );
  const selectedByTool = new Map(
    resolved.map(({ variable, selected }) => [variable, selected]),
  );

  return {
    variables: Object.fromEntries(
      Object.entries(variables).map(([key, value]) => [
        key,
        selectedByTool.get(key) ?? value,
      ]),
    ),
    toolChanges: resolved.filter(
      ({ current, selected }) => selected !== current,
    ),
  };
};

const prepareUpdate = async (update) => {
  const { image, major, latestNodeVersion: nodeVersion } = update;
  const variables = {
    ...update.variables,
    NODE_VERSION: nodeVersion,
    IMAGE_TAGS: `(${nodeVersion} ${major})`,
  };

  if (
    image === "secrets" &&
    !(await dockerTagExists("cimg/node", nodeVersion))
  ) {
    return {
      skip: {
        image,
        major,
        nodeVersion,
        reason: `missing cimg/node:${nodeVersion}`,
      },
    };
  }

  const resolved = await resolveToolUpdates(
    image,
    variables,
    update.classification,
  );

  return {
    write: {
      path: update.path,
      image,
      variables: resolved.variables,
    },
    change: {
      path: update.path,
      major,
      currentNodeVersion: update.currentNodeVersion,
      latestNodeVersion: nodeVersion,
      classification: update.classification,
      toolChanges: resolved.toolChanges,
    },
  };
};

const buildUpdates = async (releases, envFiles) => {
  const filesByImageMajor = new Map(
    envFiles.map((file) => [`${file.image}:${file.major}`, file]),
  );
  const maxSupportedMajor = envFiles.length
    ? Math.max(...envFiles.map((file) => file.major))
    : null;
  const templates = Object.fromEntries(
    Object.keys(images).map((image) => [image, latestEnvFile(envFiles, image)]),
  );
  const result = {
    writes: [],
    changes: Object.fromEntries(
      Object.keys(images).map((image) => [image, []]),
    ),
    skipped: [],
  };

  for (const release of releases) {
    const secrets = createUpdate(
      "secrets",
      release,
      filesByImageMajor.get(`secrets:${release.major}`),
      templates.secrets,
      maxSupportedMajor,
    );
    const secretsResult = secrets && (await prepareUpdate(secrets));

    if (secretsResult?.skip) {
      result.skipped.push(secretsResult.skip);
    } else if (secretsResult) {
      result.writes.push(secretsResult.write);
      result.changes.secrets.push(secretsResult.change);
    }

    const security = createUpdate(
      "security",
      release,
      filesByImageMajor.get(`security:${release.major}`),
      templates.security,
      maxSupportedMajor,
    );

    if (!security) {
      continue;
    }

    if (secretsResult?.skip) {
      result.skipped.push({
        image: "security",
        major: release.major,
        nodeVersion: release.version,
        reason: `blocked by skipped node-secrets:${release.version}`,
      });
      continue;
    }

    const securityResult = await prepareUpdate(security);

    result.writes.push(securityResult.write);
    result.changes.security.push(securityResult.change);
  }

  return result;
};

// ---------- Apply & output ----------

const renderEnvFile = ({ image, variables }) =>
  `${images[image].variables.map((variable) => `${variable}=${variables[variable]}`).join("\n")}\n`;

const applyWrites = async (writes) => {
  for (const write of writes) {
    await writeFile(write.path, renderEnvFile(write), "utf8");
  }
};

const planUpdates = async () => {
  const [releaseIndex, envFiles] = await Promise.all([
    readNodeReleaseIndex(),
    collectEnvFiles(),
  ]);

  return buildUpdates(latestEvenNodeReleases(releaseIndex), envFiles);
};

const discover = async ({ mode }) => {
  const result = await planUpdates();

  if (mode === "apply") {
    await applyWrites(result.writes);
  }

  return {
    dryRun: mode === "dry-run",
    generatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    changes: result.changes,
    skipped: result.skipped,
  };
};

// ---------- CLI entry ----------

const parseArgs = (args) => {
  if (args.length !== 1) {
    throw new Error("One argument is required, '--apply' or '--dry-run'");
  }

  const [arg] = args;

  if (arg === "--dry-run" || arg === "--apply") {
    return arg.replace(/^--/, ""); // Get selected mode
  }

  throw new Error(`Unknown argument '${arg}'`);
};

const validateConfig = (mode) => {
  if (mode !== "apply") {
    return;
  }

  if (!config.discoveryReportPath) {
    throw new Error("Env DISCOVERY_REPORT_PATH is required");
  }
};

try {
  const mode = parseArgs(process.argv.slice(2));

  validateConfig(mode);

  const result = await discover({ mode });
  const output = `${JSON.stringify(result, null, 2)}\n`;

  if (mode === "apply") {
    await writeFile(config.discoveryReportPath, output, "utf8");
  }

  process.stdout.write(output);
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
}

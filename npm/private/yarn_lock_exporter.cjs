"use strict";

const classicHttpsProxyIsConfigured = (configuration, effectiveHttpsProxy) =>
  configuration.sources?.has("httpsProxy") ||
  effectiveHttpsProxy !== configuration.get("httpsProxy");

const CLASSIC_RETRY_ERROR_CODES = new Set([
  "EADDRINUSE",
  "EAI_AGAIN",
  "ECONNREFUSED",
  "ECONNRESET",
  "ENETUNREACH",
  "ENOTFOUND",
  "EPIPE",
  "ETIMEDOUT",
]);
const CLASSIC_RETRY_STATUS_CODES = new Set([
  408,
  413,
  429,
  500,
  502,
  503,
  504,
  521,
  522,
  524,
]);
const CLASSIC_RETRY_AFTER_STATUS_CODES = new Set([413, 429, 503]);

const classicHttpStatusError = (message, status, retryAfter) => {
  const error = new Error(message);
  error.classicStatusCode = status;
  error.classicRetryAfter = retryAfter;
  return error;
};

const classicRetryAfterMilliseconds = raw => {
  if (Array.isArray(raw))
    raw = raw[0];
  if (typeof raw !== "string" || raw.length === 0)
    return null;
  if (/^(?:0|[1-9][0-9]*)$/.test(raw)) {
    const milliseconds = Number(raw) * 1000;
    return Number.isFinite(milliseconds) ? milliseconds : null;
  }
  const timestamp = Date.parse(raw);
  if (!Number.isFinite(timestamp))
    return null;
  return Math.max(0, timestamp - Date.now());
};

const classicRetryDelay = (error, attempt, networkTuning) => {
  if (attempt > networkTuning.retries)
    return null;
  const status = error.classicStatusCode;
  if (
    !CLASSIC_RETRY_ERROR_CODES.has(error.code) &&
    !CLASSIC_RETRY_STATUS_CODES.has(status)
  ) {
    return null;
  }
  if (
    CLASSIC_RETRY_AFTER_STATUS_CODES.has(status) &&
    error.classicRetryAfter !== undefined
  ) {
    const retryAfter = classicRetryAfterMilliseconds(error.classicRetryAfter);
    if (retryAfter === null)
      return null;
    if (retryAfter > 0)
      return retryAfter;
  }
  if (status === 413)
    return null;
  return 2 ** (attempt - 1) * 1000 + Math.random() * 100;
};

const retryClassicOperation = async (
  operation,
  networkTuning,
  wait = delay => new Promise(resolve => setTimeout(resolve, delay)),
) => {
  let attempt = 0;
  while (true) {
    try {
      return await operation();
    } catch (error) {
      attempt += 1;
      const delay = classicRetryDelay(error, attempt, networkTuning);
      if (delay === null)
        throw error;
      await wait(delay);
    }
  }
};

const assertClassicSelectorAcceptsLockedVersion = ({
  descriptor,
  lockedVersion,
  parseRange,
  satisfiesWithPrereleases,
  stringifyDescriptor,
}) => {
  const range = parseRange(descriptor.range);
  if (
    typeof range.selector !== "string" ||
    !satisfiesWithPrereleases(lockedVersion, range.selector)
  ) {
    throw new Error(
      `Classic selector ${stringifyDescriptor(descriptor)} does ` +
      `not accept locked version ${lockedVersion}`,
    );
  }
};

const assertNoClassicSelectiveResolutions = workspaces => {
  for (const workspace of workspaces) {
    if ((workspace.manifest.resolutions?.length || 0) > 0) {
      throw new Error(
        `Yarn Classic selective resolutions are not supported until their ` +
        `path-specific override provenance is represented in the native graph`,
      );
    }
  }
};

const rejectPinnedYarnUnsupportedSettings = (parsed, configPath) => {
  if (
    parsed &&
    typeof parsed === "object" &&
    Object.prototype.hasOwnProperty.call(parsed, "pnpmStoreFolder")
  ) {
    throw new Error(
      `pnpmStoreFolder is not supported by pinned Yarn 4.5.0; its pnpm linker ` +
      `uses the fixed project-local node_modules/.store path: ${configPath}`,
    );
  }
};

// Mirrors the exact GitFetcher.supports predicate in pinned Yarn 4.5.0. Its
// fetcher may run a package manager to prepare and pack the checked-out project,
// so these locators must be rejected before makeFetcher().fetch is called.
const YARN_GIT_REFERENCE_PATTERNS = [
  /^ssh:/,
  /^git(?:\+[^:]+)?:/,
  /^(?:git\+)?https?:[^#]+\/[^#]+(?:\.git)(?:#.*)?$/,
  /^git@[^#]+\/[^#]+\.git(?:#.*)?$/,
  /^(?:github:|https:\/\/github\.com\/)?(?!\.{1,2}\/)([a-zA-Z._0-9-]+)\/(?!\.{1,2}(?:#|$))([a-zA-Z._0-9-]+?)(?:\.git)?(?:#.*)?$/,
  /^https:\/\/github\.com\/(?!\.{1,2}\/)([a-zA-Z0-9._-]+)\/(?!\.{1,2}(?:#|$))([a-zA-Z0-9._-]+?)\/tarball\/(.+)?$/,
];

const isExecutableYarnGitReference = reference =>
  typeof reference === "string" &&
  YARN_GIT_REFERENCE_PATTERNS.some(pattern => pattern.test(reference));

const rejectExecutableYarnGitLocator = (reference, display) => {
  if (isExecutableYarnGitReference(reference)) {
    throw new Error(
      `Unsupported executable Yarn Git fetch locator for ${display}`,
    );
  }
};

const isAbsoluteYarnUserPath = path =>
  typeof path === "string" &&
  (
    path.startsWith("/") ||
    path.startsWith("\\") ||
    /^[A-Za-z]:[\\/]/.test(path)
  );

const rejectUnsafeYarnLocatorBeforeFetch = ({
  reference,
  display,
  repositoryRoot,
  projectRoot,
  parseRange,
  parseFileStyleRange,
  parseLocator,
  toPortablePath,
  resolvePath,
  relativePath,
  seen = new Map(),
}) => {
  if (seen.has(reference))
    return seen.get(reference);
  seen.set(reference, null);

  rejectExecutableYarnGitLocator(reference, display);
  const range = parseRange(reference);
  if (range.protocol === "exec:") {
    throw new Error(
      `Unsupported executable Yarn fetch protocol for ${display}: exec:`,
    );
  }
  if (range.protocol === "link:" || range.protocol === "portal:") {
    throw new Error(
      `Unsupported Yarn ${range.protocol} fetch locator in ${display}`,
    );
  }

  const recurse = locator => {
    if (locator === null)
      return null;
    return rejectUnsafeYarnLocatorBeforeFetch({
      reference: locator.reference,
      display,
      repositoryRoot,
      projectRoot,
      parseRange,
      parseFileStyleRange,
      parseLocator,
      toPortablePath,
      resolvePath,
      relativePath,
      seen,
    });
  };

  const containedPath = (base, path, kind) => {
    const resolved = resolvePath(base, path);
    const relative = relativePath(repositoryRoot, resolved);
    if (
      relative !== "." &&
      relative !== "" &&
      (
        relative === ".." ||
        relative.startsWith("../") ||
        isAbsoluteYarnUserPath(relative)
      )
    ) {
      throw new Error(
        `${kind} escapes the generated repository in ${display}`,
      );
    }
    return resolved;
  };

  if (range.protocol === "virtual:") {
    if (typeof range.selector !== "string") {
      throw new Error(`Invalid Yarn virtual locator source in ${display}`);
    }
    const localPath = rejectUnsafeYarnLocatorBeforeFetch({
      reference: range.selector,
      display,
      repositoryRoot,
      projectRoot,
      parseRange,
      parseFileStyleRange,
      parseLocator,
      toPortablePath,
      resolvePath,
      relativePath,
      seen,
    });
    seen.set(reference, localPath);
    return localPath;
  }

  if (range.protocol === "workspace:") {
    if (typeof range.selector !== "string") {
      throw new Error(`Invalid Yarn workspace locator path in ${display}`);
    }
    const localPath = containedPath(
      projectRoot,
      toPortablePath(range.selector),
      "Yarn workspace locator path",
    );
    seen.set(reference, localPath);
    return localPath;
  }

  if (range.protocol === "file:") {
    const {parentLocator, path} = parseFileStyleRange(reference, {
      protocol: "file:",
    });
    const portablePath = toPortablePath(path);
    if (isAbsoluteYarnUserPath(portablePath)) {
      throw new Error(
        `Unsupported absolute Yarn file fetch path in ${display}`,
      );
    }
    if (parentLocator === null) {
      throw new Error(
        `Relative Yarn file locator has no parent in ${display}`,
      );
    }
    const parentLocalPath = recurse(parentLocator);
    if (parentLocalPath === null)
      return null;
    const localPath = containedPath(
      parentLocalPath,
      portablePath,
      "Yarn file fetch path",
    );
    seen.set(reference, localPath);
    return localPath;
  }

  if (range.protocol !== "patch:")
    return null;

  if (range.source === null) {
    throw new Error(`Invalid Yarn patch locator source in ${display}`);
  }
  recurse(parseLocator(range.source));
  const parentLocator = typeof range.params?.locator === "string"
    ? parseLocator(range.params.locator)
    : null;
  const parentLocalPath = recurse(parentLocator);

  for (const rawPath of range.selector ? range.selector.split(/&/) : []) {
    const path = toPortablePath(
      rawPath.slice(rawPath.lastIndexOf("!") + 1),
    );
    if (/^builtin<[^>]+>$/.test(path))
      continue;
    if (isAbsoluteYarnUserPath(path)) {
      throw new Error(
        `Unsupported absolute Yarn user patch path in ${display}`,
      );
    }
    if (path.startsWith("~/")) {
      containedPath(
        projectRoot,
        path.slice(2),
        "Yarn project patch path",
      );
      continue;
    }
    if (parentLocator === null) {
      throw new Error(
        `Relative Yarn user patch path has no parent in ${display}`,
      );
    }
    if (parentLocalPath !== null) {
      containedPath(
        parentLocalPath,
        path,
        "Yarn user patch path",
      );
    }
  }
  return null;
};

// Runtime Yarn plugin injected through YARN_PLUGINS. The exact pinned yarn.js
// process provides these modules, so the exporter and resolver cannot drift.
module.exports = {
  __internal: {
    classicHttpStatusError,
    classicHttpsProxyIsConfigured,
    classicRetryAfterMilliseconds,
    classicRetryDelay,
    assertClassicSelectorAcceptsLockedVersion,
    assertNoClassicSelectiveResolutions,
    isAbsoluteYarnUserPath,
    isExecutableYarnGitReference,
    rejectExecutableYarnGitLocator,
    rejectPinnedYarnUnsupportedSettings,
    rejectUnsafeYarnLocatorBeforeFetch,
    retryClassicOperation,
  },
  name: "@aspect-build/plugin-rules-js-lock-export",
  factory: require => {
    const {BaseCommand} = require("@yarnpkg/cli");
    const {
      Cache,
      Configuration,
      httpUtils,
      InstallMode,
      LinkType,
      Manifest,
      Project,
      semverUtils,
      StreamReport,
      WorkspaceResolver,
      structUtils,
    } = require("@yarnpkg/core");
    const {npath, ppath, xfs} = require("@yarnpkg/fslib");
    const {parseSyml} = require("@yarnpkg/parsers");
    const {Option} = require("clipanion");
    const {createHash} = require("node:crypto");
    const {copyFile, mkdir, readFile, writeFile} = require("node:fs/promises");
    const {request: httpRequest} = require("node:http");
    const {Agent: HttpsAgent, request: httpsRequest} = require("node:https");
    const {isIP} = require("node:net");
    const {dirname, resolve} = require("node:path");
    const {connect: tlsConnect} = require("node:tls");
    const {gunzipSync} = require("node:zlib");

    const GRAPH_SCHEMA_VERSION = 1;
    const CLASSIC_MAX_ARCHIVE_BYTES = 256 * 1024 * 1024;
    const CLASSIC_MAX_UNCOMPRESSED_BYTES = 512 * 1024 * 1024;
    const CLASSIC_MAX_REDIRECTS = 5;
    const CLASSIC_SRI_ALGORITHMS = new Map([
      ["sha1", 20],
      ["sha256", 32],
      ["sha384", 48],
      ["sha512", 64],
    ]);
    const CLASSIC_SRI_PRIORITY = new Map([
      ["sha1", 1],
      ["sha256", 2],
      ["sha384", 3],
      ["sha512", 4],
    ]);
    const LOCAL_PROTOCOLS = new Set(["link:", "portal:"]);
    const UNSUPPORTED_FETCH_PROTOCOLS = new Set(["exec:"]);
    const SENSITIVE_KEYS = new Set(["npmAuthIdent", "npmAuthToken"]);

    const compareCodeUnits = (left, right) =>
      left < right ? -1 : left > right ? 1 : 0;
    const sortEntries = entries => [...entries].sort(
      ([left], [right]) => compareCodeUnits(left, right),
    );
    const sortedObject = entries => Object.fromEntries(sortEntries(entries));
    const jsonValue = value => {
      if (value instanceof Map)
        return sortedObject([...value].map(([key, item]) => [String(key), jsonValue(item)]));
      if (value instanceof Set)
        return [...value].map(jsonValue).sort();
      if (Array.isArray(value))
        return value.map(jsonValue);
      if (value && typeof value === "object") {
        return sortedObject(Object.entries(value)
          .filter(([key]) => !SENSITIVE_KEYS.has(key))
          .map(([key, item]) => [key, jsonValue(item)]));
      }
      return value ?? null;
    };
    const canonicalGeneratedLock = content => {
      const normalized = content.replace(/\r\n/g, "\n");
      return normalized.endsWith("\n") ? normalized : `${normalized}\n`;
    };
    const rejectConfigurationAuth = (value, path = "configuration") => {
      if (value instanceof Map) {
        for (const [key, item] of value) {
          if (SENSITIVE_KEYS.has(String(key)))
            throw new Error(`${path} contains unsupported Yarn authentication key ${String(key)}`);
          rejectConfigurationAuth(item, `${path}.${String(key)}`);
        }
      } else if (Array.isArray(value)) {
        value.forEach((item, index) =>
          rejectConfigurationAuth(item, `${path}[${index}]`));
      } else if (value && typeof value === "object") {
        for (const [key, item] of Object.entries(value)) {
          if (SENSITIVE_KEYS.has(key))
            throw new Error(`${path} contains unsupported Yarn authentication key ${key}`);
          rejectConfigurationAuth(item, `${path}.${key}`);
        }
      }
    };

    const expectClassicObject = (value, path) => {
      if (
        value === null ||
        typeof value !== "object" ||
        Array.isArray(value) ||
        value instanceof Map
      ) {
        throw new Error(`${path} must be an object`);
      }
      return value;
    };

    const expectClassicString = (value, path) => {
      if (typeof value !== "string" || value.length === 0)
        throw new Error(`${path} must be a non-empty string`);
      return value;
    };

    const classicStringMap = (value, path) => {
      if (value === undefined)
        return {};
      const source = expectClassicObject(value, path);
      return sortedObject(Object.entries(source).map(([name, range]) => [
        expectClassicString(name, `${path} key`),
        expectClassicString(range, `${path}[${JSON.stringify(name)}]`),
      ]));
    };

    const sameStringMap = (left, right) =>
      JSON.stringify(left) === JSON.stringify(right);

    const validateClassicResolvedUrl = (value, path, requireLegacyHash) => {
      const raw = expectClassicString(value, path);
      if (raw.trim() !== raw || raw.includes("\\"))
        throw new Error(`${path} is not a canonical HTTPS tarball URL`);
      let parsed;
      try {
        parsed = new URL(raw);
      } catch {
        throw new Error(`${path} is not a valid URL`);
      }
      if (parsed.protocol !== "https:")
        throw new Error(`${path} must use HTTPS`);
      if (parsed.username || parsed.password || parsed.search)
        throw new Error(`${path} cannot contain credentials or query parameters`);
      if (!parsed.hostname || !parsed.pathname.endsWith(".tgz"))
        throw new Error(`${path} must name an HTTPS .tgz archive`);
      if (requireLegacyHash) {
        if (!/^#[0-9a-f]{40}$/.test(parsed.hash)) {
          throw new Error(
            `${path} must end in exactly one 40-character lowercase SHA-1 fragment`,
          );
        }
      } else if (parsed.hash) {
        throw new Error(`${path} redirect targets cannot contain fragments`);
      }
      const legacySha1 = parsed.hash.slice(1);
      parsed.hash = "";
      return {
        fetchUrl: parsed.href,
        legacySha1,
        resolvedUrl: raw,
      };
    };

    const parseClassicIntegrity = (value, path) => {
      const raw = expectClassicString(value, path);
      if (raw.trim() !== raw)
        throw new Error(`${path} cannot contain leading or trailing whitespace`);
      const parsed = raw.split(/\s+/).map(token => {
        const match = /^(sha1|sha256|sha384|sha512)-([A-Za-z0-9+/]+={0,2})$/.exec(token);
        if (!match)
          throw new Error(`${path} contains a malformed or unsupported SRI token`);
        const [, algorithm, encoded] = match;
        const digest = Buffer.from(encoded, "base64");
        if (
          digest.length !== CLASSIC_SRI_ALGORITHMS.get(algorithm) ||
          digest.toString("base64") !== encoded
        ) {
          throw new Error(`${path} contains a noncanonical ${algorithm} digest`);
        }
        return {algorithm, encoded, token};
      });
      const strongestPriority = Math.max(
        ...parsed.map(item => CLASSIC_SRI_PRIORITY.get(item.algorithm)),
      );
      return parsed.filter(
        item => CLASSIC_SRI_PRIORITY.get(item.algorithm) === strongestPriority,
      );
    };

    const verifyClassicArchive = (bytes, record) => {
      const actualLegacySha1 = createHash("sha1").update(bytes).digest("hex");
      if (actualLegacySha1 !== record.legacySha1) {
        throw new Error(
          `Classic resolved URL SHA-1 mismatch for ${record.display}: expected ` +
          `${record.legacySha1}, got ${actualLegacySha1}`,
        );
      }
      const matchingIntegrity = record.strongestIntegrity
        .filter(item =>
          createHash(item.algorithm).update(bytes).digest("base64") === item.encoded)
        .sort((left, right) => compareCodeUnits(left.token, right.token))[0];
      if (!matchingIntegrity) {
        throw new Error(
          `Classic strongest SRI digest does not match fetched bytes for ${record.display}`,
        );
      }
      return {
        archiveSha256: createHash("sha256").update(bytes).digest("hex"),
        integrity: matchingIntegrity.token,
      };
    };

    const hostnameWithoutIpv6Brackets = hostname =>
      hostname.startsWith("[") && hostname.endsWith("]")
        ? hostname.slice(1, -1)
        : hostname;

    const noProxyMatches = target => {
      const raw = process.env.NO_PROXY ?? process.env.no_proxy;
      if (!raw)
        return false;
      const hostname = hostnameWithoutIpv6Brackets(target.hostname).toLowerCase();
      const port = target.port || "443";
      return raw.split(",").some(rawToken => {
        let token = rawToken.trim().toLowerCase();
        if (!token)
          return false;
        if (token === "*")
          return true;
        let tokenPort = null;
        if (token.startsWith("[")) {
          const close = token.indexOf("]");
          if (close === -1)
            return false;
          tokenPort = token.slice(close + 1).replace(/^:/, "") || null;
          token = token.slice(1, close);
        } else if (token.indexOf(":") === token.lastIndexOf(":")) {
          const colon = token.lastIndexOf(":");
          if (colon > 0) {
            tokenPort = token.slice(colon + 1);
            token = token.slice(0, colon);
          }
        }
        if (tokenPort !== null && tokenPort !== port)
          return false;
        token = token.replace(/^\*\./, "").replace(/^\./, "");
        return hostname === token || hostname.endsWith(`.${token}`);
      });
    };

    const classicNetworkFileCache = new Map();
    const readClassicNetworkFile = async (configuration, path, setting) => {
      if (!path)
        return undefined;
      if (!configuration.projectCwd)
        throw new Error(`${setting} requires a project directory`);
      const relativePath = ppath.relative(configuration.projectCwd, path);
      if (relativePath === ".." || relativePath.startsWith("../")) {
        throw new Error(
          `${setting} must refer to a declared file inside the generated project`,
        );
      }
      let pending = classicNetworkFileCache.get(path);
      if (!pending) {
        pending = readFile(npath.fromPortablePath(path));
        classicNetworkFileCache.set(path, pending);
      }
      return pending;
    };

    const classicNetworkOptions = async (configuration, url) => {
      const settings = httpUtils.getNetworkSettings(url, {configuration});
      if (settings.enableNetwork === false) {
        throw new Error(`Yarn network policy disables Classic archive fetch for ${url}`);
      }
      const proxyConfigured =
        classicHttpsProxyIsConfigured(configuration, settings.httpsProxy);
      return {
        proxyUrl: settings.httpsProxy || null,
        proxyConfigured,
        tls: {
          ca: await readClassicNetworkFile(
            configuration,
            settings.httpsCaFilePath,
            "httpsCaFilePath",
          ),
          cert: await readClassicNetworkFile(
            configuration,
            settings.httpsCertFilePath,
            "httpsCertFilePath",
          ),
          key: await readClassicNetworkFile(
            configuration,
            settings.httpsKeyFilePath,
            "httpsKeyFilePath",
          ),
          rejectUnauthorized: configuration.get("enableStrictSsl"),
        },
      };
    };

    const classicNetworkInteger = (configuration, setting, minimum) => {
      const value = configuration.get(setting);
      if (!Number.isSafeInteger(value) || value < minimum) {
        throw new Error(
          `${setting} must be a safe integer greater than or equal to ${minimum} ` +
          `for Classic native graph export; got ${value}`,
        );
      }
      return value;
    };

    const classicNetworkTuning = configuration => ({
      concurrency: classicNetworkInteger(
        configuration,
        "networkConcurrency",
        1,
      ),
      retries: classicNetworkInteger(
        configuration,
        "httpRetry",
        0,
      ),
      timeout: classicNetworkInteger(
        configuration,
        "httpTimeout",
        1,
      ),
    });

    const classicTimeoutError = message => {
      const error = new Error(message);
      error.code = "ETIMEDOUT";
      return error;
    };

    const proxyForClassicTarget = (target, networkOptions) => {
      let raw = networkOptions.proxyUrl;
      if (!raw) {
        if (networkOptions.proxyConfigured)
          return null;
        if (noProxyMatches(target))
          return null;
        raw =
          process.env.HTTPS_PROXY ??
          process.env.https_proxy ??
          process.env.HTTP_PROXY ??
          process.env.http_proxy;
      }
      if (!raw)
        return null;
      let proxy;
      try {
        proxy = new URL(String(raw));
      } catch {
        throw new Error("HTTPS_PROXY/HTTP_PROXY is not a valid URL");
      }
      if (
        (proxy.protocol !== "http:" && proxy.protocol !== "https:") ||
        !proxy.hostname ||
        proxy.search ||
        proxy.hash ||
        (proxy.pathname !== "" && proxy.pathname !== "/")
      ) {
        throw new Error(
          "HTTPS_PROXY/HTTP_PROXY must be an HTTP(S) proxy origin without query or fragment",
        );
      }
      return proxy;
    };

    const connectClassicProxyTunnel = (
      target,
      proxy,
      display,
      tlsOptions,
      networkTuning,
    ) =>
      new Promise((accept, reject) => {
        const targetHostname = hostnameWithoutIpv6Brackets(target.hostname);
        const targetAuthority =
          `${isIP(targetHostname) === 6 ? `[${targetHostname}]` : targetHostname}:` +
          `${target.port || "443"}`;
        const headers = {host: targetAuthority};
        if (proxy.username || proxy.password) {
          let username;
          let password;
          try {
            username = decodeURIComponent(proxy.username);
            password = decodeURIComponent(proxy.password);
          } catch {
            return reject(new Error("Proxy credentials are not valid percent-encoding"));
          }
          headers["proxy-authorization"] =
            `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
        }
        const requestFactory =
          proxy.protocol === "https:" ? httpsRequest : httpRequest;
        const request = requestFactory({
          headers,
          hostname: hostnameWithoutIpv6Brackets(proxy.hostname),
          method: "CONNECT",
          path: targetAuthority,
          port: proxy.port || (proxy.protocol === "https:" ? 443 : 80),
        });
        request.setTimeout(networkTuning.timeout, () =>
          request.destroy(classicTimeoutError(`Proxy CONNECT timed out for ${display}`)));
        request.once("connect", (response, socket, head) => {
          const status = response.statusCode || 0;
          if (status !== 200) {
            socket.destroy();
            return reject(
              classicHttpStatusError(
                `Proxy CONNECT for ${display} returned status ${status}`,
                status,
                response.headers["retry-after"],
              ),
            );
          }
          if (head.length !== 0) {
            socket.destroy();
            return reject(
              new Error(`Proxy CONNECT for ${display} returned unexpected bytes`),
            );
          }
          const tlsSocket = tlsConnect({
            ...tlsOptions,
            servername: isIP(targetHostname) ? undefined : targetHostname,
            socket,
          });
          tlsSocket.setTimeout(networkTuning.timeout, () =>
            tlsSocket.destroy(
              classicTimeoutError(`Proxy TLS handshake timed out for ${display}`),
            ));
          tlsSocket.once("secureConnect", () => {
            tlsSocket.setTimeout(0);
            accept(tlsSocket);
          });
          tlsSocket.once("error", reject);
        });
        request.once("error", reject);
        request.end();
      });

    const requestClassicTarget = async (
      url,
      display,
      configuration,
      networkTuning,
      onResponse,
    ) => {
      const target = new URL(url);
      const targetHostname = hostnameWithoutIpv6Brackets(target.hostname);
      const networkOptions = await classicNetworkOptions(configuration, url);
      const proxy = proxyForClassicTarget(target, networkOptions);
      let agent;
      if (proxy) {
        const socket = await connectClassicProxyTunnel(
          target,
          proxy,
          display,
          networkOptions.tls,
          networkTuning,
        );
        agent = new HttpsAgent({keepAlive: false});
        agent.createConnection = () => socket;
      }
      const request = httpsRequest({
        ...networkOptions.tls,
        agent,
        headers: {
          "accept": "application/octet-stream",
          "user-agent": "rules_js-native-yarn-classic-export",
        },
        hostname: targetHostname,
        path: `${target.pathname}${target.search}`,
        port: target.port || 443,
        protocol: "https:",
      }, onResponse);
      return request;
    };

    const fetchClassicArchive = async (
      initialUrl,
      display,
      configuration,
      networkTuning,
    ) => {
      const fetchOnce = (url, redirectCount) => new Promise((accept, reject) => {
        let request;
        const receive = response => {
          const finish = async () => {
            const status = response.statusCode || 0;
            if (status >= 300 && status < 400) {
              const location = response.headers.location;
              response.resume();
              if (!location)
                throw new Error(`Redirect for ${display} has no Location header`);
              if (redirectCount >= CLASSIC_MAX_REDIRECTS) {
                throw new Error(`Too many redirects while fetching ${display}`);
              }
              let redirected;
              try {
                redirected = new URL(location, url).href;
              } catch {
                throw new Error(`Invalid redirect URL while fetching ${display}`);
              }
              const safe = validateClassicResolvedUrl(
                redirected,
                `redirect for ${display}`,
                false,
              );
              return fetchOnce(safe.fetchUrl, redirectCount + 1);
            }
            if (status !== 200) {
              response.resume();
              throw classicHttpStatusError(
                `HTTPS fetch for ${display} returned status ${status}`,
                status,
                response.headers["retry-after"],
              );
            }
            const contentLength = response.headers["content-length"];
            if (
              contentLength !== undefined &&
              (
                !/^(?:0|[1-9][0-9]*)$/.test(contentLength) ||
                Number(contentLength) > CLASSIC_MAX_ARCHIVE_BYTES
              )
            ) {
              response.destroy();
              throw new Error(`Classic archive for ${display} exceeds the size limit`);
            }
            return new Promise((acceptBody, rejectBody) => {
              const chunks = [];
              let byteLength = 0;
              response.on("data", chunk => {
                byteLength += chunk.length;
                if (byteLength > CLASSIC_MAX_ARCHIVE_BYTES) {
                  response.destroy(
                    new Error(`Classic archive for ${display} exceeds the size limit`),
                  );
                  return;
                }
                chunks.push(chunk);
              });
              response.on(
                "end",
                () => acceptBody(Buffer.concat(chunks, byteLength)),
              );
              response.on("error", rejectBody);
            });
          };
          finish().then(accept, reject);
        };
        requestClassicTarget(
          url,
          display,
          configuration,
          networkTuning,
          receive,
        ).then(createdRequest => {
          request = createdRequest;
          request.setTimeout(networkTuning.timeout, () =>
            request.destroy(classicTimeoutError(`HTTPS fetch timed out for ${display}`)));
          request.on("error", reject);
          request.end();
        }, reject);
      });
      return retryClassicOperation(
        () => fetchOnce(initialUrl, 0),
        networkTuning,
      );
    };

    const tarString = (buffer, start, length, path) => {
      const field = buffer.subarray(start, start + length);
      const nul = field.indexOf(0);
      const bytes = nul === -1 ? field : field.subarray(0, nul);
      if (nul !== -1 && field.subarray(nul).some(byte => byte !== 0))
        throw new Error(`${path} contains bytes after its NUL terminator`);
      try {
        return new TextDecoder("utf-8", {fatal: true}).decode(bytes);
      } catch {
        throw new Error(`${path} is not valid UTF-8`);
      }
    };

    const tarPrefix = header => {
      const field = header.subarray(345, 500);
      // Some older npm tar writers use the old-GNU timestamp slots that overlap
      // the ustar prefix field. An empty first byte still unambiguously means
      // there is no path prefix; the remaining extension bytes cannot affect
      // extraction paths.
      if (field[0] === 0)
        return "";
      return tarString(header, 345, 155, "tar entry prefix");
    };

    const tarOctal = (buffer, start, length, path) => {
      const field = buffer.subarray(start, start + length);
      if (field[0] & 0x80)
        throw new Error(`${path} uses unsupported base-256 encoding`);
      const value = field.toString("ascii").replace(/\0.*$/, "").trim();
      if (!/^[0-7]+$/.test(value))
        throw new Error(`${path} is not canonical octal`);
      const parsed = Number.parseInt(value, 8);
      if (!Number.isSafeInteger(parsed) || parsed < 0)
        throw new Error(`${path} is outside the supported integer range`);
      return parsed;
    };

    const safeTarPath = (value, path) => {
      if (
        !value ||
        value.includes("\\") ||
        value.startsWith("/") ||
        /^[A-Za-z]:/.test(value) ||
        value.split("/").some(segment => segment === "" || segment === "." || segment === "..")
      ) {
        throw new Error(`${path} is not a safe canonical relative tar path`);
      }
      return value;
    };

    const parsePaxPath = (bytes, path) => {
      let offset = 0;
      let paxPath = null;
      while (offset < bytes.length) {
        const space = bytes.indexOf(0x20, offset);
        if (space === -1)
          throw new Error(`${path} has a malformed PAX record length`);
        const lengthText = bytes.subarray(offset, space).toString("ascii");
        if (!/^[1-9][0-9]*$/.test(lengthText))
          throw new Error(`${path} has a malformed PAX record length`);
        const recordLength = Number(lengthText);
        const end = offset + recordLength;
        if (!Number.isSafeInteger(recordLength) || end > bytes.length || bytes[end - 1] !== 0x0a)
          throw new Error(`${path} has a truncated PAX record`);
        const record = bytes.subarray(space + 1, end - 1);
        const equals = record.indexOf(0x3d);
        if (equals <= 0)
          throw new Error(`${path} has a malformed PAX key/value record`);
        const key = record.subarray(0, equals).toString("ascii");
        if (key !== "path")
          throw new Error(`${path} contains unsupported PAX key ${JSON.stringify(key)}`);
        if (paxPath !== null)
          throw new Error(`${path} contains duplicate PAX path records`);
        paxPath = new TextDecoder("utf-8", {fatal: true}).decode(
          record.subarray(equals + 1),
        );
        offset = end;
      }
      if (paxPath === null)
        throw new Error(`${path} does not contain a path record`);
      return safeTarPath(paxPath, `${path} path`);
    };

    const inspectClassicTarball = (archiveBytes, record) => {
      if (archiveBytes[0] !== 0x1f || archiveBytes[1] !== 0x8b)
        throw new Error(`Classic archive for ${record.display} is not gzip`);
      let tar;
      try {
        tar = gunzipSync(archiveBytes, {
          maxOutputLength: CLASSIC_MAX_UNCOMPRESSED_BYTES,
        });
      } catch (error) {
        throw new Error(
          `Classic archive for ${record.display} is not a bounded valid gzip stream: ` +
          `${error.message}`,
        );
      }
      if (tar.length === 0 || tar.length % 512 !== 0)
        throw new Error(`Classic tar for ${record.display} has an invalid length`);

      const paths = new Set();
      let packageJsonBytes = null;
      let hasBindingGyp = false;
      let pendingPath = null;
      let sawEnd = false;
      for (let offset = 0; offset < tar.length;) {
        const header = tar.subarray(offset, offset + 512);
        if (header.every(byte => byte === 0)) {
          if (
            offset + 1024 > tar.length ||
            !tar.subarray(offset).every(byte => byte === 0)
          ) {
            throw new Error(`Classic tar for ${record.display} has a malformed terminator`);
          }
          sawEnd = true;
          break;
        }

        const expectedChecksum = tarOctal(header, 148, 8, "tar header checksum");
        let actualChecksum = 0;
        for (let index = 0; index < header.length; index++) {
          actualChecksum += index >= 148 && index < 156 ? 0x20 : header[index];
        }
        if (actualChecksum !== expectedChecksum)
          throw new Error(`Classic tar for ${record.display} has a bad header checksum`);

        const size = tarOctal(header, 124, 12, "tar entry size");
        const dataStart = offset + 512;
        const dataEnd = dataStart + size;
        const nextOffset = dataStart + Math.ceil(size / 512) * 512;
        if (dataEnd > tar.length || nextOffset > tar.length)
          throw new Error(`Classic tar for ${record.display} has a truncated entry`);

        const name = tarString(header, 0, 100, "tar entry name");
        const prefix = tarPrefix(header);
        const headerPath = safeTarPath(
          prefix ? `${prefix}/${name}` : name,
          "tar entry path",
        );
        const type = String.fromCharCode(header[156] || 0);
        const data = tar.subarray(dataStart, dataEnd);
        if (type === "x") {
          if (pendingPath !== null)
            throw new Error(`Classic tar for ${record.display} stacks path extensions`);
          pendingPath = parsePaxPath(data, `PAX header ${headerPath}`);
          offset = nextOffset;
          continue;
        }
        if (type === "L") {
          if (pendingPath !== null)
            throw new Error(`Classic tar for ${record.display} stacks path extensions`);
          const nul = data.indexOf(0);
          const pathBytes = nul === -1 ? data : data.subarray(0, nul);
          pendingPath = safeTarPath(
            new TextDecoder("utf-8", {fatal: true}).decode(pathBytes),
            `GNU long path ${headerPath}`,
          );
          offset = nextOffset;
          continue;
        }

        const entryPath = pendingPath || headerPath;
        pendingPath = null;
        if (paths.has(entryPath))
          throw new Error(`Classic tar contains duplicate path ${entryPath}`);
        paths.add(entryPath);
        if (type !== "\0" && type !== "0" && type !== "5") {
          throw new Error(
            `Classic tar contains unsupported entry type ${JSON.stringify(type)} ` +
            `at ${entryPath}`,
          );
        }
        if (type === "5" && size !== 0)
          throw new Error(`Classic tar directory ${entryPath} has nonzero content`);
        if ((type === "\0" || type === "0") && entryPath === "package/package.json") {
          if (size > 5 * 1024 * 1024)
            throw new Error(`package/package.json for ${record.display} is too large`);
          packageJsonBytes = Buffer.from(data);
        }
        if ((type === "\0" || type === "0") && entryPath === "package/binding.gyp")
          hasBindingGyp = true;
        offset = nextOffset;
      }
      if (!sawEnd)
        throw new Error(`Classic tar for ${record.display} has no end marker`);
      if (pendingPath !== null)
        throw new Error(`Classic tar for ${record.display} ends after a path extension`);
      if (packageJsonBytes === null)
        throw new Error(`Classic tar for ${record.display} has no package/package.json`);
      return {hasBindingGyp, packageJsonBytes};
    };

    const classicManifestMap = (value, path) => {
      if (value === undefined)
        return {};
      return classicStringMap(value, path);
    };

    const classicManifestBins = (value, packageName) => {
      if (value === undefined)
        return {};
      const raw = typeof value === "string"
        ? {[packageName.split("/").pop()]: value}
        : expectClassicObject(value, "package.json bin");
      return sortedObject(Object.entries(raw).map(([name, target]) => {
        expectClassicString(name, "package.json bin key");
        const path = expectClassicString(
          target,
          `package.json bin[${JSON.stringify(name)}]`,
        );
        if (
          path.includes("\\") ||
          path.startsWith("/") ||
          /^[A-Za-z]:/.test(path) ||
          path.split("/").some(segment =>
            segment === "" || segment === "." || segment === "..")
        ) {
          throw new Error(`package.json bin target is not a safe relative path: ${path}`);
        }
        return [name, path];
      }));
    };

    const classicManifestConditions = manifest => {
      const clauses = [];
      for (const [field, key] of [["os", "os"], ["cpu", "cpu"]]) {
        if (manifest[field] === undefined)
          continue;
        const values = typeof manifest[field] === "string"
          ? [manifest[field]]
          : manifest[field];
        if (!Array.isArray(values) || values.length === 0)
          throw new Error(`package.json ${field} must be a non-empty string or list`);
        const atoms = [...new Set(values.map((raw, index) => {
          const value = expectClassicString(raw, `package.json ${field}[${index}]`);
          const negative = value.startsWith("!");
          const bare = negative ? value.slice(1) : value;
          if (!/^[a-z0-9_-]+$/.test(bare))
            throw new Error(`package.json ${field} contains unsupported value ${value}`);
          return `${negative ? "!" : ""}${key}=${bare}`;
        }))].sort(compareCodeUnits);
        clauses.push(atoms.length === 1 ? atoms[0] : `(${atoms.join(" | ")})`);
      }
      return clauses.length === 0 ? null : clauses.join(" & ");
    };

    const inspectClassicManifest = (packageJsonBytes, hasBindingGyp, record) => {
      let manifest;
      try {
        manifest = JSON.parse(
          new TextDecoder("utf-8", {fatal: true}).decode(packageJsonBytes),
        );
      } catch (error) {
        throw new Error(
          `package/package.json for ${record.display} is invalid JSON: ${error.message}`,
        );
      }
      manifest = expectClassicObject(manifest, "package/package.json");
      const name = expectClassicString(manifest.name, "package.json name");
      const version = expectClassicString(manifest.version, "package.json version");
      if (version !== record.version) {
        throw new Error(
          `Classic lock version ${record.version} differs from archive manifest ` +
          `${version} for ${record.display}`,
        );
      }
      for (const selector of record.descriptors) {
        const requestedName = structUtils.stringifyIdent(selector);
        const parsedRange = structUtils.parseRange(selector.range);
        const targetName = parsedRange.source == null
          ? requestedName
          : structUtils.stringifyIdent(structUtils.parseIdent(parsedRange.source));
        if (targetName !== name) {
          throw new Error(
            `Classic selector ${structUtils.stringifyDescriptor(selector)} cannot ` +
            `resolve archive manifest ${name}@${version}`,
          );
        }
      }

      const manifestOptional = classicManifestMap(
        manifest.optionalDependencies,
        "package.json optionalDependencies",
      );
      const manifestDependenciesWithOptional = classicManifestMap(
        manifest.dependencies,
        "package.json dependencies",
      );
      const manifestDependencies = sortedObject(
        Object.entries(manifestDependenciesWithOptional)
          .filter(([dependencyName]) =>
            !Object.prototype.hasOwnProperty.call(manifestOptional, dependencyName)),
      );
      const lockDependencies = sortedObject(
        Object.entries(record.dependencies)
          .filter(([dependencyName]) =>
            !Object.prototype.hasOwnProperty.call(record.optionalDependencies, dependencyName)),
      );
      if (!sameStringMap(manifestDependencies, lockDependencies)) {
        throw new Error(
          `Classic lock dependencies differ from archive manifest for ${record.display}`,
        );
      }
      if (!sameStringMap(manifestOptional, record.optionalDependencies)) {
        throw new Error(
          `Classic lock optionalDependencies differ from archive manifest for ` +
          `${record.display}`,
        );
      }

      const scripts = manifest.scripts === undefined
        ? {}
        : expectClassicObject(manifest.scripts, "package.json scripts");
      const lifecycleNames = ["preinstall", "install", "postinstall"];
      for (const lifecycleName of lifecycleNames) {
        if (
          scripts[lifecycleName] !== undefined &&
          typeof scripts[lifecycleName] !== "string"
        ) {
          throw new Error(`package.json scripts.${lifecycleName} must be a string`);
        }
      }
      const requiresBuild = hasBindingGyp ||
        lifecycleNames.some(name => typeof scripts[name] === "string");

      const peerDependencies = classicManifestMap(
        manifest.peerDependencies,
        "package.json peerDependencies",
      );
      const peerDependenciesMeta = {};
      if (manifest.peerDependenciesMeta !== undefined) {
        const rawMeta = expectClassicObject(
          manifest.peerDependenciesMeta,
          "package.json peerDependenciesMeta",
        );
        for (const [peerName, metadata] of Object.entries(rawMeta)) {
          const peerMeta = expectClassicObject(
            metadata,
            `package.json peerDependenciesMeta[${JSON.stringify(peerName)}]`,
          );
          const unknown = Object.keys(peerMeta).filter(key => key !== "optional");
          if (unknown.length > 0) {
            throw new Error(
              `package.json peerDependenciesMeta contains unsupported fields: ` +
              `${unknown.sort(compareCodeUnits).join(", ")}`,
            );
          }
          if (peerMeta.optional !== undefined && typeof peerMeta.optional !== "boolean") {
            throw new Error(
              `package.json peerDependenciesMeta[${JSON.stringify(peerName)}].optional ` +
              `must be a boolean`,
            );
          }
          if (peerMeta.optional !== undefined)
            peerDependenciesMeta[peerName] = {optional: peerMeta.optional};
        }
      }

      return {
        bins: classicManifestBins(manifest.bin, name),
        conditions: classicManifestConditions(manifest),
        name,
        peerDependencies,
        peerDependenciesMeta: sortedObject(Object.entries(peerDependenciesMeta)),
        requiresBuild,
        version,
      };
    };

    const classicDescriptor = (configuration, name, range, path) => {
      let descriptor;
      try {
        descriptor = structUtils.makeDescriptor(
          structUtils.parseIdent(expectClassicString(name, `${path} name`)),
          expectClassicString(range, `${path} range`),
        );
        descriptor = configuration.normalizeDependency(descriptor);
      } catch (error) {
        throw new Error(`${path} is not a valid Yarn descriptor: ${error.message}`);
      }
      const parsedRange = structUtils.parseRange(descriptor.range);
      if (parsedRange.protocol !== "npm:") {
        throw new Error(
          `${path} uses unsupported Classic dependency protocol ` +
          `${parsedRange.protocol || "<none>"}`,
        );
      }
      return descriptor;
    };

    const parseClassicLock = (content, configuration) => {
      if (!content.replace(/\r\n/g, "\n").includes("# yarn lockfile v1\n"))
        throw new Error("Classic yarn.lock is missing the v1 marker");
      let parsed;
      try {
        parsed = parseSyml(content);
      } catch (error) {
        throw new Error(`Classic yarn.lock is malformed: ${error.message}`);
      }
      parsed = expectClassicObject(parsed, "Classic yarn.lock");
      const selectorToRecord = new Map();
      const records = [];
      for (const selectorList of Object.keys(parsed).sort(compareCodeUnits)) {
        const entry = expectClassicObject(
          parsed[selectorList],
          `Classic lock entry ${JSON.stringify(selectorList)}`,
        );
        const allowed = new Set([
          "dependencies",
          "integrity",
          "optionalDependencies",
          "resolved",
          "version",
        ]);
        const unknown = Object.keys(entry).filter(key => !allowed.has(key));
        if (unknown.length > 0) {
          throw new Error(
            `Classic lock entry ${JSON.stringify(selectorList)} contains unsupported ` +
            `fields: ${unknown.sort(compareCodeUnits).join(", ")}`,
          );
        }
        const selectors = selectorList.split(/ *, */);
        if (
          selectors.length === 0 ||
          selectors.some(selector => !selector || selector.trim() !== selector)
        ) {
          throw new Error(`Classic lock entry has malformed selector list ${selectorList}`);
        }
        const descriptors = selectors.map(selector => {
          let parsedDescriptor;
          try {
            parsedDescriptor = configuration.normalizeDependency(
              structUtils.parseDescriptor(selector, true),
            );
          } catch (error) {
            throw new Error(
              `Classic selector ${JSON.stringify(selector)} is invalid: ${error.message}`,
            );
          }
          const range = structUtils.parseRange(parsedDescriptor.range);
          if (range.protocol !== "npm:") {
            throw new Error(
              `Classic selector ${JSON.stringify(selector)} uses unsupported protocol ` +
              `${range.protocol || "<none>"}`,
            );
          }
          return parsedDescriptor;
        });
        const version = expectClassicString(
          entry.version,
          `Classic lock entry ${JSON.stringify(selectorList)} version`,
        );
        for (const descriptor of descriptors) {
          assertClassicSelectorAcceptsLockedVersion({
            descriptor,
            lockedVersion: version,
            parseRange: structUtils.parseRange,
            satisfiesWithPrereleases: semverUtils.satisfiesWithPrereleases,
            stringifyDescriptor: structUtils.stringifyDescriptor,
          });
        }
        const resolved = validateClassicResolvedUrl(
          entry.resolved,
          `Classic lock entry ${JSON.stringify(selectorList)} resolved`,
          true,
        );
        const strongestIntegrity = parseClassicIntegrity(
          entry.integrity,
          `Classic lock entry ${JSON.stringify(selectorList)} integrity`,
        );
        const dependencies = classicStringMap(
          entry.dependencies,
          `Classic lock entry ${JSON.stringify(selectorList)} dependencies`,
        );
        const optionalDependencies = classicStringMap(
          entry.optionalDependencies,
          `Classic lock entry ${JSON.stringify(selectorList)} optionalDependencies`,
        );
        for (const dependencyName of Object.keys(optionalDependencies)) {
          if (
            Object.prototype.hasOwnProperty.call(dependencies, dependencyName) &&
            dependencies[dependencyName] !== optionalDependencies[dependencyName]
          ) {
            throw new Error(
              `Classic lock entry ${JSON.stringify(selectorList)} disagrees on optional ` +
              `dependency ${dependencyName}`,
            );
          }
        }
        const locatorHash = createHash("sha512")
          .update(JSON.stringify({
            dependencies,
            integrity: entry.integrity,
            optionalDependencies,
            resolved: entry.resolved,
            selectors: [...selectors].sort(compareCodeUnits),
            version,
          }))
          .digest("hex");
        const record = {
          dependencies,
          descriptors,
          display: selectors.join(", "),
          fetchUrl: resolved.fetchUrl,
          legacySha1: resolved.legacySha1,
          locatorHash,
          optionalDependencies,
          resolvedUrl: resolved.resolvedUrl,
          selectors,
          strongestIntegrity,
          version,
        };
        for (const descriptor of descriptors) {
          const previous = selectorToRecord.get(descriptor.descriptorHash);
          if (previous && previous !== record) {
            throw new Error(
              `Classic descriptor ${structUtils.stringifyDescriptor(descriptor)} ` +
              `maps to multiple raw lock entries`,
            );
          }
          selectorToRecord.set(descriptor.descriptorHash, record);
        }
        records.push(record);
      }
      return {records, selectorToRecord};
    };

    const resolveClassicDescriptor = (project, index, descriptor, path) => {
      const workspace =
        project.tryWorkspaceByDescriptor(descriptor) ||
        project.tryWorkspaceByDescriptor(
          project.configuration.normalizeDependency(descriptor),
        );
      if (workspace)
        return {workspace};
      const normalized = project.configuration.normalizeDependency(descriptor);
      const record = index.selectorToRecord.get(normalized.descriptorHash);
      if (!record) {
        throw new Error(
          `${path} is absent from the raw Classic selector map: ` +
          `${structUtils.stringifyDescriptor(normalized)}`,
        );
      }
      return {descriptor: normalized, record};
    };

    const classicReference = (project, target, requestedDescriptor) => {
      if (target.workspace) {
        return `link:${ppath.relative(project.cwd, target.workspace.cwd) || "."}`;
      }
      const requestedName = structUtils.stringifyIdent(requestedDescriptor);
      const identity = target.record.identity;
      return requestedName === identity.name
        ? identity.version
        : `npm:${identity.name}@${identity.version}`;
    };

    const exportClassicGraph = async ({
      archiveDirectory,
      configurationMetadataValue,
      declaredPackageManagers,
      originalLock,
      project,
      source,
      sourcePackage,
      exporterYarnVersion,
    }) => {
      assertNoClassicSelectiveResolutions(project.workspaces);
      const index = parseClassicLock(originalLock, project.configuration);
      const reached = new Map();
      const queue = [];
      const enqueue = (target, category) => {
        if (target.record)
          queue.push([target.record, category]);
      };

      for (const workspace of project.workspaces) {
        const manifest = workspace.manifest;
        for (const descriptor of manifest.dependencies.values()) {
          enqueue(
            resolveClassicDescriptor(
              project,
              index,
              descriptor,
              `workspace ${workspace.cwd} dependency`,
            ),
            isOptional(manifest.dependenciesMeta, descriptor)
              ? "optional"
              : "prod",
          );
        }
        for (const descriptor of manifest.devDependencies.values()) {
          if (manifest.dependencies.has(descriptor.identHash)) {
            throw new Error(
              `Workspace ${workspace.cwd} declares ` +
              `${structUtils.stringifyIdent(descriptor)} in dependencies and ` +
              `devDependencies`,
            );
          }
          enqueue(
            resolveClassicDescriptor(
              project,
              index,
              descriptor,
              `workspace ${workspace.cwd} devDependency`,
            ),
            "dev",
          );
        }
      }

      for (let queueIndex = 0; queueIndex < queue.length; queueIndex++) {
        const [record, category] = queue[queueIndex];
        const categories = reached.get(record) || new Set();
        if (categories.has(category))
          continue;
        categories.add(category);
        reached.set(record, categories);

        record.dependencyTargets ||= [];
        record.optionalDependencyTargets ||= [];
        if (record.dependencyTargets.length === 0) {
          for (const [name, range] of Object.entries(record.dependencies)) {
            if (Object.prototype.hasOwnProperty.call(record.optionalDependencies, name))
              continue;
            const descriptor = classicDescriptor(
              project.configuration,
              name,
              range,
              `Classic dependency from ${record.display}`,
            );
            record.dependencyTargets.push([
              descriptor,
              resolveClassicDescriptor(
                project,
                index,
                descriptor,
                `Classic dependency from ${record.display}`,
              ),
            ]);
          }
          for (const [name, range] of Object.entries(record.optionalDependencies)) {
            const descriptor = classicDescriptor(
              project.configuration,
              name,
              range,
              `Classic optional dependency from ${record.display}`,
            );
            record.optionalDependencyTargets.push([
              descriptor,
              resolveClassicDescriptor(
                project,
                index,
                descriptor,
                `Classic optional dependency from ${record.display}`,
              ),
            ]);
          }
        }
        for (const [, target] of record.dependencyTargets)
          enqueue(target, category);
        for (const [, target] of record.optionalDependencyTargets) {
          enqueue(target, category === "dev" ? "dev" : "optional");
        }
      }

      const networkTuning = classicNetworkTuning(project.configuration);
      await mkdir(archiveDirectory, {recursive: true});
      const orderedRecords = [...reached.keys()].sort((left, right) =>
        compareCodeUnits(left.locatorHash, right.locatorHash));
      let nextRecord = 0;
      const fetchNextRecord = async () => {
        while (nextRecord < orderedRecords.length) {
          const record = orderedRecords[nextRecord++];
          const bytes = await fetchClassicArchive(
            record.fetchUrl,
            record.display,
            project.configuration,
            networkTuning,
          );
          const verified = verifyClassicArchive(bytes, record);
          const inspectedTar = inspectClassicTarball(bytes, record);
          record.manifest = inspectClassicManifest(
            inspectedTar.packageJsonBytes,
            inspectedTar.hasBindingGyp,
            record,
          );
          record.archiveRelative =
            `archives/classic-${record.locatorHash.slice(0, 32)}.tgz`;
          record.archiveSha256 = verified.archiveSha256;
          record.integrity = verified.integrity;
          await writeFile(
            resolve(archiveDirectory, record.archiveRelative.slice("archives/".length)),
            bytes,
          );
        }
      };
      await Promise.all(
        Array.from(
          {length: Math.min(networkTuning.concurrency, orderedRecords.length)},
          () => fetchNextRecord(),
        ),
      );

      const identitiesByKey = new Map();
      for (const record of orderedRecords) {
        const manifest = record.manifest;
        const normalizedVersion =
          `${manifest.version}_yarn_${record.locatorHash.slice(0, 32)}`;
        const identity = {
          friendlyVersion: manifest.version,
          key: `${manifest.name}@${normalizedVersion}`,
          name: manifest.name,
          version: normalizedVersion,
        };
        const previous = identitiesByKey.get(identity.key);
        if (previous && previous !== record) {
          throw new Error(
            `Normalized Classic package-key collision ${identity.key}: ` +
            `${previous.display} and ${record.display}`,
          );
        }
        identitiesByKey.set(identity.key, record);
        record.identity = identity;
      }

      const importers = sortedObject(project.workspaces.map(workspace => {
        const manifest = workspace.manifest;
        const dependencies = [];
        const devDependencies = [];
        const optionalDependencies = [];
        for (const descriptor of manifest.dependencies.values()) {
          const target = resolveClassicDescriptor(
            project,
            index,
            descriptor,
            `workspace ${workspace.cwd} dependency`,
          );
          const entry = [
            structUtils.stringifyIdent(descriptor),
            classicReference(project, target, descriptor),
          ];
          if (isOptional(manifest.dependenciesMeta, descriptor))
            optionalDependencies.push(entry);
          else
            dependencies.push(entry);
        }
        for (const descriptor of manifest.devDependencies.values()) {
          const target = resolveClassicDescriptor(
            project,
            index,
            descriptor,
            `workspace ${workspace.cwd} devDependency`,
          );
          devDependencies.push([
            structUtils.stringifyIdent(descriptor),
            classicReference(project, target, descriptor),
          ]);
        }
        return [
          ppath.relative(project.cwd, workspace.cwd) || ".",
          {
            dependencies: sortedObject(dependencies),
            dev_dependencies: sortedObject(devDependencies),
            optional_dependencies: sortedObject(optionalDependencies),
            install_config: {
              hoistingLimits: manifest.installConfig?.hoistingLimits ?? null,
              selfReferences: manifest.installConfig?.selfReferences ?? null,
            },
          },
        ];
      }));

      const packages = orderedRecords.map(record => {
        const categories = reached.get(record);
        const dependencyEntries = record.dependencyTargets.map(
          ([descriptor, target]) => [
            structUtils.stringifyIdent(descriptor),
            classicReference(project, target, descriptor),
          ],
        );
        const optionalDependencyEntries = record.optionalDependencyTargets.map(
          ([descriptor, target]) => [
            structUtils.stringifyIdent(descriptor),
            classicReference(project, target, descriptor),
          ],
        );
        return [record.identity.key, {
          bins: record.manifest.bins,
          conditions: record.manifest.conditions,
          dependencies: sortedObject(dependencyEntries),
          dependency_meta: {},
          dev_only:
            categories.has("dev") &&
            !categories.has("prod") &&
            !categories.has("optional"),
          friendly_version: record.identity.friendlyVersion,
          has_bin: Object.keys(record.manifest.bins).length > 0,
          link_type: "HARD",
          name: record.identity.name,
          optional:
            categories.has("optional") &&
            !categories.has("prod") &&
            !categories.has("dev"),
          optional_dependencies: sortedObject(optionalDependencyEntries),
          peer_dependencies: record.manifest.peerDependencies,
          peer_dependencies_meta: record.manifest.peerDependenciesMeta,
          requires_build: record.manifest.requiresBuild,
          resolution: {
            archive: record.archiveRelative,
            archive_sha256: record.archiveSha256,
            integrity: record.integrity,
            legacy_sha1: record.legacySha1,
            locator: `${record.identity.name}@npm:${record.identity.friendlyVersion}`,
            locator_hash: record.locatorHash,
            resolved_url: record.resolvedUrl,
            type: "yarn-classic-tarball",
          },
          version: record.identity.version,
          yarn_build_metadata: {
            requires_build: record.manifest.requiresBuild,
          },
        }];
      });

      return {
        importers,
        metadata: {
          configuration: configurationMetadataValue,
          declared_package_managers: declaredPackageManagers,
          exporter_yarn_version: exporterYarnVersion,
          lifecycle: {
            package_manifests_inspected: true,
            scripts_executed: false,
          },
          pinned_yarn_compatibility_adjustments: [],
          source_lock_version: source.version,
          source_package: sourcePackage,
          workspace_package_extension_adjustments: [],
        },
        packages: sortedObject(packages),
        patched_dependencies: {},
        schema_version: GRAPH_SCHEMA_VERSION,
        source_format: source.format,
      };
    };

    const writeVerifiedGraph = async (graph, outputPath, expectedGraphSha256) => {
      await mkdir(dirname(outputPath), {recursive: true});
      const graphBytes = `${JSON.stringify(graph, null, 2)}\n`;
      const graphSha256 = createHash("sha256").update(graphBytes).digest("hex");
      await writeFile(outputPath, graphBytes);
      if (expectedGraphSha256 !== graphSha256) {
        throw new Error(
          `Generated Yarn graph SHA-256 mismatch: expected ` +
          `${expectedGraphSha256 || "<unset>"}, got ${graphSha256}. ` +
          `The canonical graph was written for review, but the failed export cannot be consumed. ` +
          `Review the graph, then pin expected_graph_sha256 to this value.`,
        );
      }
      return graphSha256;
    };

    const configurationValue = (configuration, key) => {
      if (!configuration.settings.has(key))
        return null;
      return jsonValue(configuration.get(key));
    };

    const portableConfigurationPath = (configuration, key) => {
      const value = configurationValue(configuration, key);
      if (typeof value !== "string")
        return value;
      if (!configuration.projectCwd)
        return null;
      const portable = npath.toPortablePath(value);
      const relativePath = ppath.relative(configuration.projectCwd, portable);
      if (relativePath === ".." || relativePath.startsWith("../")) {
        throw new Error(
          `${key} must remain inside the Yarn project for deterministic export`,
        );
      }
      return relativePath || ".";
    };

    const configurationMetadata = configuration => {
      const keys = [
        "cacheMigrationMode",
        "checksumBehavior",
        "compressionLevel",
        "defaultLanguageName",
        "defaultProtocol",
        "enableStrictSettings",
        "enableTransparentWorkspaces",
        "httpRetry",
        "httpTimeout",
        "networkConcurrency",
        "nodeLinker",
        "nmHoistingLimits",
        "nmMode",
        "nmSelfReferences",
        "pnpEnableEsmLoader",
        "pnpEnableInlining",
        "pnpFallbackMode",
        "pnpMode",
        "pnpShebang",
        "supportedArchitectures",
        "winLinkType",
      ];
      const metadata = sortedObject(keys.map(key => [
        key,
        configurationValue(configuration, key),
      ]));
      if (metadata.enableStrictSettings !== true) {
        throw new Error(
          `Native Yarn graph export requires enableStrictSettings: true`,
        );
      }

      const safeRegistryUrl = key => {
        const value = configurationValue(configuration, key);
        return safeRegistryValueUrl(value, key);
      };
      const safeRegistryValueUrl = (value, key) => {
        if (typeof value !== "string")
          return null;
        const parsed = new URL(value.startsWith("//") ? `https:${value}` : value);
        if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
          throw new Error(`${key} must use an HTTP(S) registry URL`);
        }
        if (parsed.username || parsed.password || parsed.search || parsed.hash) {
          throw new Error(
            `${key} cannot contain credentials, query parameters, or fragments`,
          );
        }
        return parsed.pathname === "/"
          ? parsed.origin
          : `${parsed.origin}${parsed.pathname}`;
      };
      const containerValue = (container, key) => {
        if (container instanceof Map)
          return container.get(key) ?? null;
        if (container && typeof container === "object")
          return container[key] ?? null;
        return null;
      };
      const safeRegistrySettings = (settings, path) => ({
        npmAlwaysAuth: containerValue(settings, "npmAlwaysAuth"),
        npmAuditRegistryUrl: safeRegistryValueUrl(
          containerValue(settings, "npmAuditRegistry"),
          `${path}.npmAuditRegistry`,
        ),
        npmPublishRegistryUrl: safeRegistryValueUrl(
          containerValue(settings, "npmPublishRegistry"),
          `${path}.npmPublishRegistry`,
        ),
        npmRegistryServerUrl: safeRegistryValueUrl(
          containerValue(settings, "npmRegistryServer"),
          `${path}.npmRegistryServer`,
        ),
      });
      const scopes = configuration.settings.has("npmScopes")
        ? configuration.get("npmScopes")
        : new Map();
      const registries = configuration.settings.has("npmRegistries")
        ? configuration.get("npmRegistries")
        : new Map();
      metadata.registryPolicy = {
        npmAlwaysAuth: configurationValue(configuration, "npmAlwaysAuth"),
        npmAuditRegistryUrl: safeRegistryUrl("npmAuditRegistry"),
        npmPublishRegistryUrl: safeRegistryUrl("npmPublishRegistry"),
        npmRegistryServerUrl: safeRegistryUrl("npmRegistryServer"),
        registries: [...registries].map(([registry, settings]) => ({
          url: safeRegistryValueUrl(registry, "npmRegistries key"),
          settings: safeRegistrySettings(
            settings,
            `npmRegistries[${JSON.stringify(registry)}]`,
          ),
        })).sort((left, right) =>
          compareCodeUnits(JSON.stringify(left), JSON.stringify(right))),
        scopes: sortedObject([...scopes].map(([scope, settings]) => [
          scope,
          safeRegistrySettings(settings, `npmScopes[${JSON.stringify(scope)}]`),
        ])),
      };
      const pnpIgnorePatterns = configurationValue(
        configuration,
        "pnpIgnorePatterns",
      );
      if (!Array.isArray(pnpIgnorePatterns)) {
        throw new Error("pnpIgnorePatterns must be a list");
      }
      const projectNativePath = configuration.projectCwd
        ? npath.fromPortablePath(configuration.projectCwd)
        : null;
      for (const pattern of pnpIgnorePatterns) {
        if (typeof pattern !== "string")
          throw new Error("pnpIgnorePatterns entries must be strings");
        const portablePattern = npath.toPortablePath(pattern);
        if (
          ppath.isAbsolute(portablePattern) ||
          /^[A-Za-z]:[\\/]/.test(pattern) ||
          /^file:/i.test(pattern) ||
          pattern.includes("\\") ||
          portablePattern.split("/").includes("..") ||
          (configuration.projectCwd && pattern.includes(configuration.projectCwd)) ||
          (projectNativePath && pattern.includes(projectNativePath))
        ) {
          throw new Error(
            `pnpIgnorePatterns cannot contain absolute or host-specific paths`,
          );
        }
      }
      metadata.pnpIgnorePatterns = pnpIgnorePatterns;
      metadata.pnpEnableEsmLoaderExplicit =
        configuration.sources?.has("pnpEnableEsmLoader") || false;
      metadata.enableScripts = configurationValue(configuration, "enableScripts");
      metadata.pnpUnpluggedFolder = portableConfigurationPath(
        configuration,
        "pnpUnpluggedFolder",
      );
      return metadata;
    };

    const dependencyMetaFor = (metaMap, descriptor) => {
      const byRange = metaMap.get(structUtils.stringifyIdent(descriptor));
      if (!byRange)
        return null;
      if (!(byRange instanceof Map))
        return byRange;
      return byRange.get(descriptor.range) ||
        byRange.get(null);
    };

    const isOptional = (metaMap, descriptor) => {
      return dependencyMetaFor(metaMap, descriptor)?.optional === true;
    };

    const boolMetadata = (value, allowedFields, path) => {
      if (!value || typeof value !== "object" || Array.isArray(value))
        throw new Error(`${path} must be a metadata object`);
      const allowed = new Set(allowedFields);
      const entries = [];
      for (const [field, fieldValue] of Object.entries(value)) {
        if (!allowed.has(field))
          throw new Error(`${path} contains unsupported field ${field}`);
        if (fieldValue === null || fieldValue === undefined)
          continue;
        if (typeof fieldValue !== "boolean")
          throw new Error(`${path}.${field} must be a boolean`);
        entries.push([field, fieldValue]);
      }
      return sortedObject(entries);
    };

    const dependencyMetadata = metaMap => {
      if (!(metaMap instanceof Map))
        throw new Error("dependenciesMeta must be a map");
      return sortedObject([...metaMap].map(([ident, ranges]) => {
        if (!(ranges instanceof Map))
          throw new Error(`dependenciesMeta[${String(ident)}] must be a range map`);
        return [String(ident), sortedObject([...ranges].map(([range, metadata]) => [
          String(range),
          boolMetadata(
            metadata,
            ["built", "optional", "unplugged"],
            `dependenciesMeta[${String(ident)}][${String(range)}]`,
          ),
        ]))];
      }));
    };

    const peerDependencyMetadata = metaMap => {
      if (!(metaMap instanceof Map))
        throw new Error("peerDependenciesMeta must be a map");
      return sortedObject([...metaMap].map(([ident, metadata]) => [
        String(ident),
        boolMetadata(
          metadata,
          ["optional"],
          `peerDependenciesMeta[${String(ident)}]`,
        ),
      ]));
    };

    const parsePackageManager = raw => {
      if (typeof raw === "string") {
        const match = /^([^@\s]+)@([^+\s]+)(?:\+.*)?$/.exec(raw);
        return match ? {name: match[1], version: match[2]} : null;
      }
      if (raw && typeof raw === "object") {
        return {
          name: raw.name || null,
          version: raw.version || null,
        };
      }
      return null;
    };

    const validatePackageManager = project => {
      const rawManifest = project.topLevelWorkspace.manifest.raw;
      const declarations = [
        ["packageManager", rawManifest.packageManager],
        ["devEngines.packageManager", rawManifest.devEngines?.packageManager],
      ];
      for (const [field, raw] of declarations) {
        if (raw === undefined)
          continue;
        const parsed = parsePackageManager(raw);
        if (!parsed || parsed.name !== "yarn") {
          throw new Error(
            `${field} must select Yarn when using a yarn.lock; found ${JSON.stringify(raw)}`,
          );
        }
        if (
          !/^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/.test(
            parsed.version,
          )
        ) {
          throw new Error(
            `${field} must declare an exact Yarn semantic version; found ` +
            `${JSON.stringify(parsed.version)}`,
          );
        }
      }
      return declarations
        .filter(([, raw]) => raw !== undefined)
        .map(([field, raw]) => ({field, ...parsePackageManager(raw)}));
    };

    const normalizedPackageIdentity = pkg => {
      const locator = structUtils.convertPackageToLocator(pkg);
      const name = structUtils.stringifyIdent(pkg);
      const friendlyVersion = pkg.version || "0.0.0";
      const suffix = locator.locatorHash.slice(0, 32);
      const version = `${friendlyVersion}_yarn_${suffix}`;
      return {
        friendlyVersion,
        key: `${name}@${version}`,
        locator,
        name,
        version,
      };
    };

    const resolvedReference = (project, descriptor, identities) => {
      const locatorHash = project.storedResolutions.get(descriptor.descriptorHash);
      if (!locatorHash) {
        throw new Error(
          `No stored Yarn resolution for ${structUtils.stringifyDescriptor(descriptor)}`,
        );
      }
      const pkg = project.storedPackages.get(locatorHash);
      if (!pkg)
        throw new Error(`No stored Yarn package for locator hash ${locatorHash}`);

      const resolvedLocator = structUtils.convertPackageToLocator(pkg);
      const workspaceLocator = structUtils.isVirtualLocator(resolvedLocator)
        ? structUtils.devirtualizeLocator(resolvedLocator)
        : resolvedLocator;
      const workspace = project.tryWorkspaceByLocator(workspaceLocator);
      if (workspace) {
        if (structUtils.isVirtualLocator(resolvedLocator)) {
          const identity = identities.get(locatorHash);
          if (!identity) {
            throw new Error(
              `No normalized identity for virtual workspace locator hash ${locatorHash}`,
            );
          }
          const requestedName = structUtils.stringifyIdent(descriptor);
          return requestedName === identity.name
            ? identity.version
            : `npm:${identity.name}@${identity.version}`;
        }
        return `link:${ppath.relative(project.cwd, workspace.cwd) || "."}`;
      }

      const identity = identities.get(locatorHash);
      if (!identity)
        throw new Error(`No normalized identity for locator hash ${locatorHash}`);
      const requestedName = structUtils.stringifyIdent(descriptor);
      return requestedName === identity.name
        ? identity.version
        : `npm:${identity.name}@${identity.version}`;
    };

    const classifySourceFormat = project => {
      const version = Number(project.lockfileLastVersion);
      if (version === -1)
        return {format: "classic-v1", version: 1};
      if (version === 4 || version === 6 || version === 8)
        return {format: `berry-v${version}`, version};
      throw new Error(
        `Unsupported Yarn lock metadata version ${String(version)}; ` +
        `supported inputs are Classic v1 and Berry v4, v6, and v8`,
      );
    };

    const workspaceForLocator = (project, locator) => {
      const physical = structUtils.isVirtualLocator(locator)
        ? structUtils.devirtualizeLocator(locator)
        : locator;
      return project.tryWorkspaceByLocator(physical);
    };

    const validateWorkspaceManifestsAgainstLock = project => {
      const discoveredWorkspaceHashes = new Set(
        project.workspaces.map(workspace => workspace.anchoredLocator.locatorHash),
      );
      for (const lockedPackage of project.originalPackages.values()) {
        if (
          !structUtils.isVirtualLocator(lockedPackage) &&
          structUtils.parseRange(lockedPackage.reference).protocol === "workspace:" &&
          !discoveredWorkspaceHashes.has(lockedPackage.locatorHash)
        ) {
          throw new Error(
            `Yarn lockfile workspace is missing its declared package.json input: ` +
            `${safeLocatorDisplay(lockedPackage)}`,
          );
        }
      }

      for (const workspace of project.workspaces) {
        const workspacePath = ppath.relative(project.cwd, workspace.cwd) || ".";
        const lockedPackage = project.originalPackages.get(
          workspace.anchoredLocator.locatorHash,
        );
        if (!lockedPackage)
          throw new Error(`Yarn lockfile is missing workspace ${workspacePath}`);

        for (const descriptor of workspace.manifest.dependencies.values()) {
          if (workspace.manifest.devDependencies.has(descriptor.identHash)) {
            throw new Error(
              `Workspace ${workspacePath} declares ` +
              `${structUtils.stringifyIdent(descriptor)} in both dependencies and ` +
              `devDependencies`,
            );
          }
        }
        const declared = new Map([
          ...workspace.manifest.dependencies,
          ...workspace.manifest.devDependencies,
        ]);
        for (const [identHash, descriptor] of declared) {
          const normalized = project.configuration.normalizeDependency(descriptor);
          const lockedDescriptor = lockedPackage.dependencies.get(identHash);
          if (!lockedDescriptor) {
            throw new Error(
              `Workspace ${workspacePath} dependency ` +
              `${structUtils.stringifyDescriptor(descriptor)} is missing from yarn.lock`,
            );
          }
          if (normalized.descriptorHash !== lockedDescriptor.descriptorHash) {
            throw new Error(
              `Workspace ${workspacePath} dependency range differs from yarn.lock: ` +
              `${structUtils.stringifyDescriptor(normalized)} != ` +
              `${structUtils.stringifyDescriptor(lockedDescriptor)}`,
            );
          }
          const manifestOptional = isOptional(
            workspace.manifest.dependenciesMeta,
            descriptor,
          );
          const lockOptional = isOptional(
            lockedPackage.dependenciesMeta,
            lockedDescriptor,
          );
          if (manifestOptional !== lockOptional) {
            throw new Error(
              `Workspace ${workspacePath} optionality differs from yarn.lock for ` +
              `${structUtils.stringifyIdent(descriptor)}`,
            );
          }
        }
      }
    };

    class FrozenPackageResolver {
      constructor(packages, resolutions) {
        this.packages = packages;
        this.resolutions = resolutions;
      }

      supportsDescriptor(descriptor) {
        const locatorHash = this.resolutions.get(descriptor.descriptorHash);
        return locatorHash !== undefined && this.packages.has(locatorHash);
      }

      supportsLocator(locator) {
        return this.packages.has(locator.locatorHash);
      }

      shouldPersistResolution() {
        return true;
      }

      bindDescriptor(descriptor) {
        return descriptor;
      }

      getResolutionDependencies() {
        return {};
      }

      async getCandidates(descriptor) {
        const locatorHash = this.resolutions.get(descriptor.descriptorHash);
        const pkg = locatorHash === undefined ? null : this.packages.get(locatorHash);
        if (!pkg) {
          throw new Error(
            `Descriptor is not frozen in yarn.lock: ` +
            `${structUtils.stringifyDescriptor(descriptor)}`,
          );
        }
        return [structUtils.convertPackageToLocator(pkg)];
      }

      async getSatisfying(descriptor, dependencies, locators) {
        const [expected] = await this.getCandidates(descriptor, dependencies);
        return {
          locators: locators.filter(locator => locator.locatorHash === expected.locatorHash),
          sorted: false,
        };
      }

      async resolve(locator) {
        const pkg = this.packages.get(locator.locatorHash);
        if (!pkg) {
          throw new Error(
            `Locator is not frozen in yarn.lock: ${safeLocatorDisplay(locator)}`,
          );
        }
        return pkg;
      }
    }

    class ClosedResolver {
      constructor(resolvers) {
        this.resolvers = resolvers;
      }

      descriptorResolver(descriptor, opts) {
        const resolver = this.resolvers.find(candidate =>
          candidate.supportsDescriptor(descriptor, opts));
        if (!resolver) {
          throw new Error(
            `Dependency is absent from yarn.lock; closed resolution refused ` +
            `${structUtils.stringifyDescriptor(descriptor)}`,
          );
        }
        return resolver;
      }

      locatorResolver(locator, opts) {
        const resolver = this.resolvers.find(candidate =>
          candidate.supportsLocator(locator, opts));
        if (!resolver) {
          throw new Error(
            `Locator is absent from yarn.lock; closed resolution refused ` +
            `${safeLocatorDisplay(locator)}`,
          );
        }
        return resolver;
      }

      supportsDescriptor(descriptor, opts) {
        return this.resolvers.some(candidate => candidate.supportsDescriptor(descriptor, opts));
      }

      supportsLocator(locator, opts) {
        return this.resolvers.some(candidate => candidate.supportsLocator(locator, opts));
      }

      shouldPersistResolution(locator, opts) {
        return this.locatorResolver(locator, opts).shouldPersistResolution(locator, opts);
      }

      bindDescriptor(descriptor, fromLocator, opts) {
        return this.descriptorResolver(descriptor, opts)
          .bindDescriptor(descriptor, fromLocator, opts);
      }

      getResolutionDependencies(descriptor, opts) {
        return this.descriptorResolver(descriptor, opts)
          .getResolutionDependencies(descriptor, opts);
      }

      getCandidates(descriptor, dependencies, opts) {
        return this.descriptorResolver(descriptor, opts)
          .getCandidates(descriptor, dependencies, opts);
      }

      getSatisfying(descriptor, dependencies, locators, opts) {
        return this.descriptorResolver(descriptor, opts)
          .getSatisfying(descriptor, dependencies, locators, opts);
      }

      resolve(locator, opts) {
        return this.locatorResolver(locator, opts).resolve(locator, opts);
      }
    }

    const closeBerryResolution = project => {
      const frozenDescriptors = new Map(project.storedDescriptors);
      const frozenPackages = new Map(project.originalPackages);
      const frozenResolutions = new Map(project.storedResolutions);
      const workspaceHashes = new Set(
        project.workspaces.map(workspace => workspace.anchoredLocator.locatorHash),
      );
      for (const locatorHash of workspaceHashes)
        project.originalPackages.delete(locatorHash);
      for (const [descriptorHash, locatorHash] of [...project.storedResolutions]) {
        if (!workspaceHashes.has(locatorHash))
          continue;
        project.storedResolutions.delete(descriptorHash);
        project.storedDescriptors.delete(descriptorHash);
      }
      return {
        frozenDescriptors,
        frozenPackages,
        frozenResolutions,
        resolver: new ClosedResolver([
          new WorkspaceResolver(),
          new FrozenPackageResolver(frozenPackages, frozenResolutions),
        ]),
      };
    };

    const packageSignature = (
      pkg,
      {devirtualize = false, resolutions = null} = {},
    ) => {
      const locator = devirtualize && structUtils.isVirtualLocator(pkg)
        ? structUtils.devirtualizeLocator(pkg)
        : pkg;
      const descriptorHash = descriptor => {
        const normalized = devirtualize && structUtils.isVirtualDescriptor(descriptor)
          ? structUtils.devirtualizeDescriptor(descriptor)
          : descriptor;
        return resolutions?.get(normalized.descriptorHash) || normalized.descriptorHash;
      };
      return {
        bin: jsonValue(pkg.bin),
        conditions: pkg.conditions || null,
        dependencies: sortedObject([...pkg.dependencies].map(([identHash, descriptor]) => [
          identHash,
          descriptorHash(descriptor),
        ])),
        dependenciesMeta: dependencyMetadata(pkg.dependenciesMeta),
        languageName: pkg.languageName,
        linkType: pkg.linkType,
        locator: {
          ident_hash: locator.identHash,
          locator_hash: locator.locatorHash,
          reference: locator.reference,
        },
        peerDependencies: sortedObject([...pkg.peerDependencies].map(([identHash, descriptor]) => [
          identHash,
          descriptorHash(descriptor),
        ])),
        peerDependenciesMeta: peerDependencyMetadata(pkg.peerDependenciesMeta),
        preferUnplugged:
          typeof pkg.preferUnplugged === "boolean" ? pkg.preferUnplugged : null,
        version: pkg.version,
      };
    };

    const builtinPackageExtensions = async configuration => {
      const allExtensions = await configuration.getPackageExtensions();
      const builtinExtensions = new Map();
      for (const [identHash, extensionsPerIdent] of allExtensions) {
        const builtinPerIdent = [];
        for (const [range, extensionsPerRange] of extensionsPerIdent) {
          const builtinPerRange = extensionsPerRange.filter(
            extension => extension.userProvided === false,
          );
          if (builtinPerRange.length > 0)
            builtinPerIdent.push([range, builtinPerRange]);
        }
        if (builtinPerIdent.length > 0)
          builtinExtensions.set(identHash, builtinPerIdent);
      }
      return builtinExtensions;
    };

    const prepareWithPinnedCompatibility = async (
      project,
      originalPkg,
      resolver,
      report,
      packageExtensions,
    ) => {
      const pkg = project.configuration.normalizePackage(originalPkg, {
        packageExtensions,
      });
      const resolveOptions = {project, report, resolver};
      for (const [identHash, descriptor] of pkg.dependencies) {
        const dependency = await project.configuration.reduceHook(
          hooks => hooks.reduceDependency,
          descriptor,
          project,
          pkg,
          descriptor,
          {resolver, resolveOptions},
        );
        if (!structUtils.areIdentsEqual(descriptor, dependency)) {
          throw new Error(
            "Pinned Yarn compatibility hook changed a dependency identity",
          );
        }
        pkg.dependencies.set(
          identHash,
          resolver.bindDescriptor(dependency, pkg, resolveOptions),
        );
      }
      return pkg;
    };

    const patchSourceLocatorHashes = packages => {
      const hashes = new Set();
      for (const pkg of packages.values()) {
        const locator = structUtils.convertPackageToLocator(pkg);
        const range = structUtils.parseRange(locator.reference);
        if (range.protocol !== "patch:" || range.source === null)
          continue;
        hashes.add(structUtils.parseLocator(range.source).locatorHash);
      }
      return hashes;
    };

    const lockWithoutPatchSourceRecords = (content, sourceHashes) => {
      const parsed = parseSyml(content);
      for (const [selector, record] of Object.entries(parsed)) {
        if (
          selector === "__metadata" ||
          !record ||
          typeof record.resolution !== "string"
        ) {
          continue;
        }
        let locator;
        try {
          locator = structUtils.parseLocator(record.resolution);
        } catch {
          continue;
        }
        if (sourceHashes.has(locator.locatorHash))
          delete parsed[selector];
      }
      return JSON.stringify(jsonValue(parsed));
    };

    const validateResolvedPackagesAgainstLock = async (
      project,
      frozenPackages,
      frozenResolutions,
      frozenDescriptors,
      resolver,
      report,
    ) => {
      const builtinExtensions = await builtinPackageExtensions(
        project.configuration,
      );
      const allExtensions = await project.configuration.getPackageExtensions();
      const resolvedPatchSources = patchSourceLocatorHashes(project.storedPackages);
      const expectedPackages = new Map();
      const expectedBuiltinPackages = new Map();
      const pinnedCompatibilityIdents = new Set();
      for (const [locatorHash, frozen] of frozenPackages) {
        const expected = await prepareWithPinnedCompatibility(
          project,
          frozen,
          resolver,
          report,
          allExtensions,
        );
        expectedPackages.set(locatorHash, expected);
        if (!workspaceForLocator(project, frozen)) {
          const expectedBuiltin = await prepareWithPinnedCompatibility(
            project,
            frozen,
            resolver,
            report,
            builtinExtensions,
          );
          expectedBuiltinPackages.set(locatorHash, expectedBuiltin);
          const rawSignature = packageSignature(frozen);
          const expectedBuiltinSignature = packageSignature(expectedBuiltin);
          if (Object.keys(expectedBuiltinSignature).some(
            field => JSON.stringify(rawSignature[field]) !==
              JSON.stringify(expectedBuiltinSignature[field]),
          )) {
            pinnedCompatibilityIdents.add(frozen.identHash);
          }
        }
      }

      const frozenNonWorkspaceResolutions = new Map(
        [...frozenResolutions].filter(([, locatorHash]) => {
          const pkg = frozenPackages.get(locatorHash);
          return pkg && !workspaceForLocator(project, pkg);
        }),
      );
      const resolvedNonWorkspaceResolutions = new Map(
        [...project.storedResolutions].filter(([, locatorHash]) => {
          const pkg = project.storedPackages.get(locatorHash);
          return pkg && !workspaceForLocator(project, pkg);
        }),
      );
      const resolutionHashes = new Set([
        ...frozenNonWorkspaceResolutions.keys(),
        ...resolvedNonWorkspaceResolutions.keys(),
      ]);
      for (const descriptorHash of [...resolutionHashes].sort()) {
        const frozenLocatorHash = frozenNonWorkspaceResolutions.get(descriptorHash);
        const resolvedLocatorHash = resolvedNonWorkspaceResolutions.get(descriptorHash);
        if (frozenLocatorHash !== resolvedLocatorHash) {
          if (
            resolvedLocatorHash === undefined &&
            resolvedPatchSources.has(frozenLocatorHash)
          ) {
            continue;
          }
          const descriptor =
            frozenDescriptors.get(descriptorHash) ||
            project.storedDescriptors.get(descriptorHash);
          let generatedVirtualResolution = false;
          if (
            !frozenLocatorHash &&
            resolvedLocatorHash &&
            descriptor &&
            structUtils.isVirtualDescriptor(descriptor)
          ) {
            const devirtualizedDescriptor = structUtils.devirtualizeDescriptor(
              descriptor,
            );
            const frozenPhysicalLocatorHash = frozenResolutions.get(
              devirtualizedDescriptor.descriptorHash,
            );
            const resolvedLocator = project.storedPackages.get(
              resolvedLocatorHash,
            );
            const resolvedPhysicalLocator = resolvedLocator &&
              structUtils.isVirtualLocator(resolvedLocator)
              ? structUtils.devirtualizeLocator(resolvedLocator)
              : resolvedLocator;
            generatedVirtualResolution =
              frozenPhysicalLocatorHash !== undefined &&
              resolvedPhysicalLocator?.locatorHash === frozenPhysicalLocatorHash;
          }
          if (generatedVirtualResolution)
            continue;
          throw new Error(
            `Resolved descriptor-to-locator mapping differs from yarn.lock: ` +
            `${descriptor ? structUtils.stringifyDescriptor(descriptor) : descriptorHash} ` +
            `(frozen ${frozenLocatorHash || "<missing>"}, ` +
            `resolved ${resolvedLocatorHash || "<missing>"})`,
          );
        }
      }

      const frozenNonWorkspacePackages = new Map(
        [...frozenPackages].filter(([, pkg]) => !workspaceForLocator(project, pkg)),
      );
      const resolvedNonWorkspacePackages = new Map(
        [...project.storedPackages].filter(([, pkg]) => !workspaceForLocator(project, pkg)),
      );
      const locatorHashes = new Set([
        ...frozenNonWorkspacePackages.keys(),
        ...resolvedNonWorkspacePackages.keys(),
      ]);
      const generatedCompatibilityVirtuals = [];
      for (const locatorHash of [...locatorHashes].sort()) {
        const frozen = frozenNonWorkspacePackages.get(locatorHash);
        const resolved = resolvedNonWorkspacePackages.get(locatorHash);
        if (!frozen || !resolved) {
          if (frozen && resolvedPatchSources.has(locatorHash))
            continue;
          if (
            !frozen &&
            resolved &&
            structUtils.isVirtualLocator(resolved)
          ) {
            const physical = structUtils.devirtualizeLocator(resolved);
            const frozenPhysical = frozenNonWorkspacePackages.get(
              physical.locatorHash,
            );
            if (frozenPhysical) {
              generatedCompatibilityVirtuals.push(resolved);
              continue;
            }
          }
          const locator = frozen || resolved;
          throw new Error(
            `Resolved package locator set differs from yarn.lock: ` +
            `${safeLocatorDisplay(locator)} is ` +
            `${frozen ? "missing after resolution" : "absent from the lockfile"}`,
          );
        }
      }

      const compatibilityAdjustments = [];
      const workspaceAdjustments = [];
      const effectiveResolutions = new Map([
        ...frozenResolutions,
        ...project.storedResolutions,
      ]);
      for (const [locatorHash, frozen] of frozenPackages) {
        const pkg = project.storedPackages.get(locatorHash);
        if (!pkg)
          continue;
        const workspace = workspaceForLocator(project, frozen);
        const expected = expectedPackages.get(locatorHash);
        const signatureOptions = {
          devirtualize: true,
          resolutions: effectiveResolutions,
        };
        const rawSignature = packageSignature(frozen, signatureOptions);
        const expectedSignature = packageSignature(expected, signatureOptions);
        const builtinSignature = workspace
          ? rawSignature
          : packageSignature(
            expectedBuiltinPackages.get(locatorHash),
            signatureOptions,
          );
        const actualSignature = packageSignature(pkg, signatureOptions);
        const signatureFields = Object.keys(expectedSignature).filter(
          field => field !== "version" || !workspace,
        );
        const compatibilityFields = signatureFields.filter(
          field => JSON.stringify(rawSignature[field]) !==
            JSON.stringify(builtinSignature[field]),
        );
        if (compatibilityFields.length > 0) {
          compatibilityAdjustments.push({
            fields: compatibilityFields.sort(),
            locator: safeLocatorDisplay(frozen),
            locator_hash: locatorHash,
          });
        }
        const workspaceExtensionFields = signatureFields.filter(
          field => JSON.stringify(builtinSignature[field]) !==
            JSON.stringify(expectedSignature[field]),
        );
        if (workspaceExtensionFields.length > 0) {
          workspaceAdjustments.push({
            fields: workspaceExtensionFields.sort(),
            locator: safeLocatorDisplay(frozen),
            locator_hash: locatorHash,
          });
        }
        const differingFields = signatureFields.filter(
          field => JSON.stringify(actualSignature[field]) !==
            JSON.stringify(expectedSignature[field]),
        );
        if (differingFields.length > 0) {
          throw new Error(
            `Resolved package metadata differs from yarn.lock after applying only ` +
            `pinned Yarn built-in compatibility: ${safeLocatorDisplay(pkg)} ` +
            `(${differingFields.join(", ")})`,
          );
        }
      }
      for (const locator of generatedCompatibilityVirtuals) {
        compatibilityAdjustments.push({
          fields: ["virtual_locator"],
          locator: safeLocatorDisplay(locator),
          locator_hash: locator.locatorHash,
        });
      }

      const byLocatorHash = (left, right) =>
        compareCodeUnits(left.locator_hash, right.locator_hash);
      return {
        builtin: compatibilityAdjustments.sort(byLocatorHash),
        workspaces: workspaceAdjustments.sort(byLocatorHash),
      };
    };

    const dependencyMap = (
      project,
      dependencies,
      identities,
      predicate = () => true,
      transform = descriptor => descriptor,
    ) => {
      return sortedObject(
        [...dependencies.values()]
          .filter(predicate)
          .map(descriptor => [
            structUtils.stringifyIdent(descriptor),
            resolvedReference(project, transform(descriptor), identities),
          ]),
      );
    };

    const boundWorkspaceDescriptor = (project, workspace, descriptor) => {
      const bound = workspace.anchoredPackage.dependencies.get(descriptor.identHash);
      if (!bound) {
        throw new Error(
          `Resolved workspace ${ppath.relative(project.cwd, workspace.cwd) || "."} ` +
          `does not contain ${structUtils.stringifyDescriptor(descriptor)}`,
        );
      }
      return bound;
    };

    const computeReachability = project => {
      const categories = new Map();
      const queue = [];
      const enqueue = (descriptor, category) => queue.push([descriptor, category]);

      for (const workspace of project.workspaces) {
        for (const descriptor of workspace.manifest.dependencies.values()) {
          enqueue(
            boundWorkspaceDescriptor(project, workspace, descriptor),
            isOptional(workspace.manifest.dependenciesMeta, descriptor)
              ? "optional"
              : "prod",
          );
        }
        for (const descriptor of workspace.manifest.devDependencies.values()) {
          enqueue(
            boundWorkspaceDescriptor(project, workspace, descriptor),
            "dev",
          );
        }
      }

      for (let index = 0; index < queue.length; index++) {
        const [descriptor, category] = queue[index];
        const locatorHash = project.storedResolutions.get(descriptor.descriptorHash);
        if (!locatorHash) {
          throw new Error(
            `No stored Yarn resolution for ${structUtils.stringifyDescriptor(descriptor)}`,
          );
        }
        const seen = categories.get(locatorHash) || new Set();
        if (seen.has(category))
          continue;
        seen.add(category);
        categories.set(locatorHash, seen);

        const pkg = project.storedPackages.get(locatorHash);
        if (!pkg)
          throw new Error(`No stored Yarn package for locator hash ${locatorHash}`);
        for (const child of pkg.dependencies.values()) {
          const childCategory = category === "dev"
            ? "dev"
            : category === "optional" || isOptional(pkg.dependenciesMeta, child)
              ? "optional"
              : "prod";
          enqueue(child, childCategory);
        }
      }
      return categories;
    };

    const stableArchiveName = locator => {
      const slug = structUtils.slugifyLocator(locator)
        .replace(/[^A-Za-z0-9._-]+/g, "_");
      return `${slug}-${locator.locatorHash.slice(0, 32)}.zip`;
    };

    const safeLocatorDisplay = locator => {
      const parsedRange = structUtils.parseRange(locator.reference);
      if (parsedRange.protocol === "npm:")
        return structUtils.stringifyLocator(locator);
      return (
        `${structUtils.stringifyIdent(locator)}@` +
        `${parsedRange.protocol || "unknown:"}<redacted>#${locator.locatorHash.slice(0, 12)}`
      );
    };

    const rejectLocatorBeforeFetch = (locator, project, repositoryRoot) =>
      rejectUnsafeYarnLocatorBeforeFetch({
        reference: locator.reference,
        display: safeLocatorDisplay(locator),
        repositoryRoot,
        projectRoot: project.cwd,
        parseRange: structUtils.parseRange,
        parseFileStyleRange: structUtils.parseFileStyleRange,
        parseLocator: structUtils.parseLocator,
        toPortablePath: npath.toPortablePath,
        resolvePath: ppath.resolve,
        relativePath: ppath.relative,
      });

    const fetchAllAccessible = async (
      project,
      cache,
      report,
      repositoryRoot,
    ) => {
      const buildEvidence = new Map();
      const accessible = project.accessibleLocators instanceof Set
        ? project.accessibleLocators
        : new Set(project.storedPackages.keys());
      const physicalPackages = new Map();
      for (const locatorHash of [...accessible].sort()) {
        const pkg = project.storedPackages.get(locatorHash);
        if (!pkg)
          throw new Error(`Accessible Yarn locator ${locatorHash} has no stored package`);
        const locator = structUtils.convertPackageToLocator(pkg);
        const physical = structUtils.isVirtualLocator(locator)
          ? structUtils.devirtualizeLocator(locator)
          : locator;
        if (workspaceForLocator(project, physical) || physicalPackages.has(physical.locatorHash))
          continue;

        rejectLocatorBeforeFetch(physical, project, repositoryRoot);
        const parsedRange = structUtils.parseRange(physical.reference);
        if (pkg.linkType === LinkType.SOFT || LOCAL_PROTOCOLS.has(parsedRange.protocol)) {
          throw new Error(
            `Non-workspace local package ${structUtils.stringifyLocator(locator)} ` +
            `uses ${parsedRange.protocol || "a soft link"}; declare it as a workspace input`,
          );
        }
        if (UNSUPPORTED_FETCH_PROTOCOLS.has(parsedRange.protocol)) {
          throw new Error(
            `Unsupported executable Yarn fetch protocol for ` +
            `${structUtils.stringifyLocator(locator)}: ${parsedRange.protocol}`,
          );
        }
        physicalPackages.set(physical.locatorHash, {
          physical,
          pkg: project.storedPackages.get(physical.locatorHash) || pkg,
        });
      }

      const packages = [...physicalPackages.values()].sort((left, right) =>
        compareCodeUnits(
          structUtils.stringifyLocator(left.physical),
          structUtils.stringifyLocator(right.physical),
        ));
      const fetcher = project.configuration.makeFetcher();
      let nextPackage = 0;
      const fetchNext = async () => {
        while (nextPackage < packages.length) {
          const packageIndex = nextPackage++;
          const {physical, pkg} = packages[packageIndex];
          const expectedChecksum = project.storedChecksums.get(
            physical.locatorHash,
          );
          if (!expectedChecksum && !pkg.conditions) {
            throw new Error(
              `yarn.lock has no native checksum for ` +
              `${safeLocatorDisplay(physical)}; refusing to bless fetched bytes`,
            );
          }
          const result = await fetcher.fetch(physical, {
            cache,
            cacheOptions: {
              mockedPackages: new Set(),
              unstablePackages: new Set(),
            },
            checksums: project.storedChecksums,
            fetcher,
            project,
            report,
          });
          try {
            if (expectedChecksum && result.checksum !== expectedChecksum) {
              throw new Error(
                `Fetched Yarn checksum differs from yarn.lock for ` +
                `${safeLocatorDisplay(physical)} (expected ${expectedChecksum}, ` +
                `got ${result.checksum || "<missing>"})`,
              );
            }
            if (!expectedChecksum) {
              if (!result.checksum) {
                throw new Error(
                  `Yarn did not calculate a cache checksum for conditional package ` +
                  `${safeLocatorDisplay(physical)}`,
                );
              }
              project.storedChecksums.set(physical.locatorHash, result.checksum);
            }
            const manifest = await Manifest.tryFind(result.prefixPath, {
              baseFs: result.packageFs,
            });
            const hasLifecycleScript = manifest !== null && [
              "preinstall",
              "install",
              "postinstall",
            ].some(name => manifest.scripts.has(name));
            const hasBindingGyp = await result.packageFs.existsPromise(
              ppath.join(result.prefixPath, "binding.gyp"),
            );
            const dependencyMeta = project.getDependencyMeta(physical, pkg.version);
            let requiresBuild = hasLifecycleScript || hasBindingGyp;
            if (dependencyMeta.built === false)
              requiresBuild = false;
            else if (dependencyMeta.built === true)
              requiresBuild = true;
            const evidence = {requires_build: requiresBuild};
            if (typeof dependencyMeta.built === "boolean")
              evidence.dependency_meta_built = dependencyMeta.built;
            if (typeof dependencyMeta.unplugged === "boolean")
              evidence.dependency_meta_unplugged = dependencyMeta.unplugged;
            if (typeof manifest?.preferUnplugged === "boolean")
              evidence.prefer_unplugged = manifest.preferUnplugged;
            buildEvidence.set(physical.locatorHash, evidence);
          } finally {
            result.releaseFs?.();
          }
        }
      };
      await Promise.all(
        Array.from(
          {length: Math.min(32, packages.length)},
          () => fetchNext(),
        ),
      );
      return buildEvidence;
    };

    class RulesJsInspectConfigCommand extends BaseCommand {
      static paths = [["rules-js", "inspect-config"]];

      path = Option.String("--path", {required: true});

      async execute() {
        const configPath = resolve(this.path);
        const parsed = parseSyml(await readFile(configPath, "utf8"));
        rejectConfigurationAuth(parsed);
        rejectPinnedYarnUnsupportedSettings(parsed, configPath);
        if (
          parsed &&
          typeof parsed === "object" &&
          Object.prototype.hasOwnProperty.call(parsed, "plugins")
        ) {
          throw new Error(
            `Project Yarn plugins are not allowed during native graph export: ` +
            `${configPath}`,
          );
        }
        if (
          parsed &&
          typeof parsed === "object" &&
          Object.prototype.hasOwnProperty.call(parsed, "injectEnvironmentFiles")
        ) {
          throw new Error(
            `injectEnvironmentFiles is not allowed during native graph export: ` +
            `${configPath}`,
          );
        }
        if (
          parsed &&
          typeof parsed === "object" &&
          Object.prototype.hasOwnProperty.call(parsed, "yarnPath")
        ) {
          throw new Error(
            `yarnPath is not allowed during native graph export; ` +
            `the exact checksum-pinned Yarn bundle is always used: ${configPath}`,
          );
        }
        if (
          parsed &&
          typeof parsed === "object" &&
          Object.prototype.hasOwnProperty.call(parsed, "checksumBehavior") &&
          parsed.checksumBehavior !== "throw"
        ) {
          throw new Error(
            `Native Yarn graph export requires checksumBehavior: throw; ` +
            `${configPath} selects ${JSON.stringify(parsed.checksumBehavior)}`,
          );
        }
        return 0;
      }
    }

    class RulesJsExportCommand extends BaseCommand {
      static paths = [["rules-js", "export-lock"]];

      output = Option.String("--output", {required: true});
      archives = Option.String("--archives", {required: true});
      expectedGraphSha256 = Option.String("--expected-graph-sha256", {required: true});
      repositoryRoot = Option.String("--repository-root", {required: true});
      sourceFormat = Option.String("--source-format", {required: true});
      sourcePackage = Option.String("--source-package", {required: true});
      exporterYarnVersion = Option.String("--exporter-yarn-version", {required: true});

      async execute() {
        if (this.sourceFormat !== "auto")
          throw new Error(`source format must be auto, got ${this.sourceFormat}`);

        const configuration = await Configuration.find(
          this.context.cwd,
          this.context.plugins,
        );
        const safeConfigurationMetadata = configurationMetadata(configuration);
        const {project} = await Project.find(configuration, this.context.cwd);
        const repositoryRoot = npath.toPortablePath(resolve(this.repositoryRoot));
        const projectRelative = ppath.relative(repositoryRoot, project.cwd);
        if (
          projectRelative === ".." ||
          projectRelative.startsWith("../") ||
          isAbsoluteYarnUserPath(projectRelative)
        ) {
          throw new Error(
            `Yarn project root escapes the generated repository`,
          );
        }
        const source = classifySourceFormat(project);
        if (source.format.startsWith("berry-"))
          validateWorkspaceManifestsAgainstLock(project);
        const declaredPackageManagers = validatePackageManager(project);

        const lockPath = ppath.join(project.cwd, "yarn.lock");
        const originalLock = await readFile(npath.fromPortablePath(lockPath), "utf8");
        const outputPath = resolve(this.output);
        const archiveDirectory = resolve(this.archives);
        if (source.format === "classic-v1") {
          const graph = await exportClassicGraph({
            archiveDirectory,
            configurationMetadataValue: safeConfigurationMetadata,
            declaredPackageManagers,
            exporterYarnVersion: this.exporterYarnVersion,
            originalLock,
            project,
            source,
            sourcePackage: this.sourcePackage,
          });
          const currentLock = await readFile(npath.fromPortablePath(lockPath), "utf8");
          if (currentLock !== originalLock)
            throw new Error("native Yarn graph export modified the copied source lockfile");
          await writeVerifiedGraph(graph, outputPath, this.expectedGraphSha256);
          return 0;
        }

        const cache = await Cache.find(configuration);
        const closedResolution = closeBerryResolution(project);
        let buildEvidence = new Map();
        let resolutionAdjustments = {
          builtin: [],
          workspaces: [],
        };
        const resolutionReport = await StreamReport.start(
          {
            configuration,
            includeFooter: false,
            stdout: this.context.stdout,
          },
          async report => {
            await project.resolveEverything({
              cache,
              lockfileOnly: false,
              checkResolutions: true,
              mode: InstallMode.SkipBuild,
              report,
              resolver: closedResolution.resolver,
            });
            resolutionAdjustments = await validateResolvedPackagesAgainstLock(
              project,
              closedResolution.frozenPackages,
              closedResolution.frozenResolutions,
              closedResolution.frozenDescriptors,
              closedResolution.resolver,
              report,
            );
            if (source.version === 8) {
              const regeneratedLock = canonicalGeneratedLock(
                project.generateLockfile(),
              );
              const originalCanonicalLock = canonicalGeneratedLock(originalLock);
              const resolvedPatchSources = patchSourceLocatorHashes(
                project.storedPackages,
              );
              const lockMatches = resolvedPatchSources.size === 0
                ? regeneratedLock === originalCanonicalLock
                : lockWithoutPatchSourceRecords(
                  regeneratedLock,
                  resolvedPatchSources,
                ) === lockWithoutPatchSourceRecords(
                  originalCanonicalLock,
                  resolvedPatchSources,
                );
              if (!lockMatches) {
                throw new Error(
                  "Resolved Yarn v8 graph would regenerate yarn.lock with " +
                    "differences beyond normalized patch-source records",
                );
              }
            }
            buildEvidence = await fetchAllAccessible(
              project,
              cache,
              report,
              repositoryRoot,
            );
          },
        );
        if (resolutionReport.hasErrors())
          return resolutionReport.exitCode();
        const currentLock = await readFile(npath.fromPortablePath(lockPath), "utf8");
        if (currentLock !== originalLock)
          throw new Error("native Yarn graph export modified the copied source lockfile");

        const reachability = computeReachability(project);
        const accessible = project.accessibleLocators instanceof Set
          ? project.accessibleLocators
          : new Set(reachability.keys());

        const identities = new Map();
        const identitiesByKey = new Map();
        for (const locatorHash of accessible) {
          const pkg = project.storedPackages.get(locatorHash);
          if (!pkg)
            throw new Error(`Accessible Yarn locator ${locatorHash} has no stored package`);
          const locator = structUtils.convertPackageToLocator(pkg);
          if (
            !workspaceForLocator(project, locator) ||
            structUtils.isVirtualLocator(locator)
          ) {
            const identity = normalizedPackageIdentity(pkg);
            const previous = identitiesByKey.get(identity.key);
            if (previous) {
              throw new Error(
                `Normalized package-key collision ${identity.key}: ` +
                `${structUtils.stringifyLocator(previous.locator)} and ` +
                `${structUtils.stringifyLocator(identity.locator)}`,
              );
            }
            identities.set(locator.locatorHash, identity);
            identitiesByKey.set(identity.key, identity);
          }
        }

        const importers = sortedObject(project.workspaces.map(workspace => {
          const manifest = workspace.manifest;
          const effectivePackage = workspace.anchoredPackage;
          const optional = descriptor =>
            isOptional(effectivePackage.dependenciesMeta, descriptor);
          const dev = descriptor =>
            manifest.devDependencies.has(descriptor.identHash);
          return [
            ppath.relative(project.cwd, workspace.cwd) || ".",
            {
              dependencies: dependencyMap(
                project,
                effectivePackage.dependencies,
                identities,
                descriptor => !dev(descriptor) && !optional(descriptor),
              ),
              dev_dependencies: dependencyMap(
                project,
                effectivePackage.dependencies,
                identities,
                dev,
              ),
              optional_dependencies: dependencyMap(
                project,
                effectivePackage.dependencies,
                identities,
                descriptor => !dev(descriptor) && optional(descriptor),
              ),
              install_config: {
                hoistingLimits: manifest.installConfig?.hoistingLimits ?? null,
                selfReferences: manifest.installConfig?.selfReferences ?? null,
              },
            },
          ];
        }));

        await mkdir(dirname(outputPath), {recursive: true});
        await mkdir(archiveDirectory, {recursive: true});

        const copiedArchives = new Map();
        const archiveLocators = new Map();
        const packages = [];
        const orderedPackages = [...accessible]
          .map(locatorHash => project.storedPackages.get(locatorHash))
          .filter(pkg => pkg !== undefined)
          .sort((left, right) => compareCodeUnits(
            structUtils.stringifyLocator(left),
            structUtils.stringifyLocator(right),
          ));
        for (const pkg of orderedPackages) {
          const locator = structUtils.convertPackageToLocator(pkg);
          const workspace = workspaceForLocator(project, locator);
          if (workspace && !structUtils.isVirtualLocator(locator))
            continue;

          const identity = identities.get(locator.locatorHash);
          const optional = descriptor => isOptional(pkg.dependenciesMeta, descriptor);
          const reachedAs = reachability.get(locator.locatorHash) || new Set();
          if (workspace) {
            packages.push([identity.key, {
              bins: sortedObject(pkg.bin),
              conditions: pkg.conditions || null,
              dependencies: dependencyMap(
                project,
                pkg.dependencies,
                identities,
                descriptor => !optional(descriptor),
              ),
              dependency_meta: dependencyMetadata(pkg.dependenciesMeta),
              dev_only: reachedAs.has("dev") &&
                !reachedAs.has("prod") &&
                !reachedAs.has("optional"),
              friendly_version: identity.friendlyVersion,
              has_bin: pkg.bin.size > 0,
              link_type: pkg.linkType,
              name: identity.name,
              optional: reachedAs.has("optional") &&
                !reachedAs.has("prod") &&
                !reachedAs.has("dev"),
              optional_dependencies: dependencyMap(
                project,
                pkg.dependencies,
                identities,
                optional,
              ),
              peer_dependencies: sortedObject(
                [...pkg.peerDependencies.values()].map(descriptor => [
                  structUtils.stringifyIdent(descriptor),
                  descriptor.range,
                ]),
              ),
              peer_dependencies_meta: peerDependencyMetadata(pkg.peerDependenciesMeta),
              requires_build: false,
              resolution: {
                directory: ppath.relative(project.cwd, workspace.cwd) || ".",
                type: "virtual-directory",
              },
              version: identity.version,
              yarn_build_metadata: {
                requires_build: false,
              },
            }]);
            continue;
          }

          rejectLocatorBeforeFetch(locator, project, repositoryRoot);
          const parsedRange = structUtils.parseRange(locator.reference);
          if (pkg.linkType === LinkType.SOFT || LOCAL_PROTOCOLS.has(parsedRange.protocol)) {
            throw new Error(
              `Non-workspace local package ${structUtils.stringifyLocator(locator)} ` +
              `uses ${parsedRange.protocol || "a soft link"}; declare it as a workspace ` +
              `input so rules_js can represent it as link:<path>`,
            );
          }
          if (UNSUPPORTED_FETCH_PROTOCOLS.has(parsedRange.protocol)) {
            throw new Error(
              `Unsupported executable Yarn fetch protocol for ` +
              `${structUtils.stringifyLocator(locator)}: ${parsedRange.protocol}`,
            );
          }

          const archiveLocator = structUtils.isVirtualLocator(locator)
            ? structUtils.devirtualizeLocator(locator)
            : locator;
          const yarnChecksum =
            project.storedChecksums.get(archiveLocator.locatorHash) ||
            project.storedChecksums.get(locator.locatorHash) ||
            null;
          if (!yarnChecksum) {
            throw new Error(
              `Yarn did not provide a native cache checksum for ` +
              `${structUtils.stringifyLocator(archiveLocator)}`,
            );
          }
          const archiveName = stableArchiveName(archiveLocator);
          const archiveRelative = `archives/${archiveName}`;
          const previousArchiveLocator = archiveLocators.get(archiveRelative);
          if (
            previousArchiveLocator !== undefined &&
            previousArchiveLocator !== archiveLocator.locatorHash
          ) {
            throw new Error(
              `Yarn cache archive-name collision ${archiveRelative}: ` +
              `${previousArchiveLocator} and ${archiveLocator.locatorHash}`,
            );
          }
          archiveLocators.set(archiveRelative, archiveLocator.locatorHash);
          let archiveSha256 = copiedArchives.get(archiveRelative);
          if (!archiveSha256) {
            const sourcePath = cache.getLocatorPath(archiveLocator, yarnChecksum);
            if (!sourcePath || !xfs.existsSync(sourcePath)) {
              throw new Error(
                `Yarn cache archive missing for ${structUtils.stringifyLocator(archiveLocator)}`,
              );
            }
            const archivePath = resolve(archiveDirectory, archiveName);
            await copyFile(npath.fromPortablePath(sourcePath), archivePath);
            const bytes = await readFile(archivePath);
            archiveSha256 = createHash("sha256").update(bytes).digest("hex");
            copiedArchives.set(archiveRelative, archiveSha256);
          }

          packages.push([identity.key, {
            bins: sortedObject(pkg.bin),
            conditions: pkg.conditions || null,
            dependencies: dependencyMap(
              project,
              pkg.dependencies,
              identities,
              descriptor => !optional(descriptor),
            ),
            dependency_meta: dependencyMetadata(pkg.dependenciesMeta),
            dev_only: reachedAs.has("dev") &&
              !reachedAs.has("prod") &&
              !reachedAs.has("optional"),
            friendly_version: identity.friendlyVersion,
            has_bin: pkg.bin.size > 0,
            link_type: pkg.linkType,
            name: identity.name,
            optional: reachedAs.has("optional") &&
              !reachedAs.has("prod") &&
              !reachedAs.has("dev"),
            optional_dependencies: dependencyMap(
              project,
              pkg.dependencies,
              identities,
              optional,
            ),
            peer_dependencies: sortedObject(
              [...pkg.peerDependencies.values()].map(descriptor => [
                structUtils.stringifyIdent(descriptor),
                descriptor.range,
              ]),
            ),
            peer_dependencies_meta: peerDependencyMetadata(pkg.peerDependenciesMeta),
            requires_build:
              buildEvidence.get(archiveLocator.locatorHash)?.requires_build ?? null,
            resolution: {
              archive: archiveRelative,
              archive_sha256: archiveSha256,
              locator: safeLocatorDisplay(locator),
              locator_hash: locator.locatorHash,
              type: "yarn-cache",
              yarn_checksum: yarnChecksum,
            },
            version: identity.version,
            yarn_build_metadata:
              buildEvidence.get(archiveLocator.locatorHash) || null,
          }]);
        }

        const graph = {
          importers,
          metadata: {
            configuration: safeConfigurationMetadata,
            pinned_yarn_compatibility_adjustments:
              resolutionAdjustments.builtin,
            lifecycle: {
              package_manifests_inspected: true,
              scripts_executed: false,
            },
            workspace_package_extension_adjustments:
              resolutionAdjustments.workspaces,
            declared_package_managers: declaredPackageManagers,
            source_lock_version: source.version,
            source_package: this.sourcePackage,
            exporter_yarn_version: this.exporterYarnVersion,
          },
          packages: sortedObject(packages),
          patched_dependencies: {},
          schema_version: GRAPH_SCHEMA_VERSION,
          source_format: source.format,
        };
        await writeVerifiedGraph(graph, outputPath, this.expectedGraphSha256);
        return 0;
      }
    }

    return {
      commands: [
        RulesJsInspectConfigCommand,
        RulesJsExportCommand,
      ],
    };
  },
};

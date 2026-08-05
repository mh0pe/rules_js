"use strict";
/**
 * pnp_preload.cjs - Bazel sandbox path remapping for Yarn PnP.
 * 
 * This script is automatically required by pnp_js_binary/pnp_js_test targets.
 * It reads PNP_WORKSPACE_ROOT (set by pnp_repository.bzl) and remaps Bazel
 * sandbox paths to workspace paths so PnP can resolve modules correctly.
 * 
 * Without this, PnP's .pnp.cjs sees paths like:
 *   /sandbox/darwin-sandbox/123/execroot/_main/apps/web/src/foo.ts
 * but the package map was built for:
 *   apps/web/src/foo.ts
 * 
 * This preload intercepts PnP's resolution methods and remaps issuer paths.
 */

const { existsSync } = require("node:fs");
const { register } = require("node:module");
const nodeModule = require("node:module");
const { resolve } = require("node:path");
const { pathToFileURL, fileURLToPath } = require("node:url");

// PNP_WORKSPACE_ROOT is set by pnp_repository.bzl's _pnp_wrap function
const workspaceRoot = process.env.PNP_WORKSPACE_ROOT;
if (!workspaceRoot) {
  // Not running under Bazel PnP wrapper - exit silently
  return;
}

const pnpCjs = resolve(workspaceRoot, ".pnp.cjs");
const pnpLoader = resolve(workspaceRoot, ".pnp.loader.mjs");

if (!existsSync(pnpCjs)) {
  console.error(`[pnp_preload] PnP runtime not found at ${pnpCjs}`);
  process.exit(1);
}

// Bazel sandbox path patterns - covers all sandbox types and remote execution
const SANDBOX_PATTERNS = [
  // darwin-sandbox (macOS)
  /\/sandbox\/darwin-sandbox\/\d+\/execroot\/_main\/bazel-out\/[^/]+\/bin\/(.+)$/,
  /\/sandbox\/darwin-sandbox\/\d+\/execroot\/_main\/(.+)$/,
  // linux-sandbox
  /\/sandbox\/linux-sandbox\/\d+\/execroot\/_main\/bazel-out\/[^/]+\/bin\/(.+)$/,
  /\/sandbox\/linux-sandbox\/\d+\/execroot\/_main\/(.+)$/,
  // processwrapper-sandbox (Windows and fallback)
  /\/sandbox\/processwrapper-sandbox\/\d+\/execroot\/_main\/bazel-out\/[^/]+\/bin\/(.+)$/,
  /\/sandbox\/processwrapper-sandbox\/\d+\/execroot\/_main\/(.+)$/,
  // Generic execroot patterns (remote execution, no sandbox)
  /\/execroot\/_main\/bazel-out\/[^/]+\/bin\/(.+)$/,
  /\/execroot\/_main\/(.+)$/,
  // bazel-out relative to cwd
  /^bazel-out\/[^/]+\/bin\/(.+)$/,
  /\/bazel-out\/[^/]+\/bin\/(.+)$/,
];

/**
 * Remap a Bazel sandbox path to the workspace-relative path PnP expects.
 */
function remapPath(path) {
  if (!path || typeof path !== "string") return path;
  
  // Handle file:// URLs
  if (path.startsWith("file://")) {
    try {
      path = fileURLToPath(path);
    } catch {
      return path;
    }
  }
  
  for (const pattern of SANDBOX_PATTERNS) {
    const match = path.match(pattern);
    if (match) {
      return resolve(workspaceRoot, match[1]);
    }
  }
  return path;
}

// Load and setup PnP if not already loaded
let pnpApi;
if (!process.versions.pnp) {
  pnpApi = require(pnpCjs);
  pnpApi.setup();
} else {
  pnpApi = require.resolve.pnpApi || require("pnpapi");
}

// Wrap PnP API methods to remap sandbox paths before resolution
const originalResolveToUnqualified = pnpApi.resolveToUnqualified.bind(pnpApi);
pnpApi.resolveToUnqualified = function(request, issuer, opts) {
  return originalResolveToUnqualified(request, remapPath(issuer), opts);
};

const originalResolveRequest = pnpApi.resolveRequest.bind(pnpApi);
pnpApi.resolveRequest = function(request, issuer, opts) {
  return originalResolveRequest(request, remapPath(issuer), opts);
};

// Patch module.findPnpApi to remap issuer paths
const originalFindPnpApi = nodeModule.findPnpApi;
if (originalFindPnpApi) {
  nodeModule.findPnpApi = function(issuer) {
    const remapped = remapPath(issuer);
    const api = originalFindPnpApi.call(this, remapped);
    return api ? pnpApi : null;
  };
}

// Register ESM loader if available
if (typeof register === "function" && existsSync(pnpLoader)) {
  register(pathToFileURL(pnpLoader), {
    parentURL: pathToFileURL(workspaceRoot + "/"),
  });
}

// Make preload inheritable by child processes spawned from Node
const inherited = process.env.NODE_OPTIONS?.trim() ?? "";
const preloads = [pnpCjs, __filename]
  .filter((p) => !inherited.includes(p))
  .map((p) => `--require=${p}`);

process.env.NODE_OPTIONS = [inherited, ...preloads].filter(Boolean).join(" ");

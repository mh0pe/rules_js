"""Generate a pnpm lockfile from a Yarn lockfile in an external repository."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load("@bazel_skylib//lib:paths.bzl", "paths")

_BUILD_FILENAME = "BUILD.bazel"
_ENV_RUNNER_FILENAME = ".aspect_rules_js_env_runner.mjs"
_EMPTY_NPMRC_FILENAME = ".aspect_rules_js_empty_npmrc"
_LOCK_VERIFY_FILENAME = ".aspect_rules_js_verify_lock.mjs"
_PNPM_LOCK_FILENAME = "pnpm-lock.yaml"
_YARN_LOCK_FILENAME = "yarn.lock"
_RESERVED_FILENAMES = [
    _ENV_RUNNER_FILENAME,
    _EMPTY_NPMRC_FILENAME,
    _LOCK_VERIFY_FILENAME,
]

def _label_path(label):
    path = paths.normalize(paths.join(label.package, label.name))
    if path == ".." or path.startswith("../") or "/../" in path:
        fail("input label resolves outside its repository: {}".format(label))
    return path

def _copy_inputs(rctx):
    source_repo = rctx.attr.yarn_lock.repo_name
    copied = {}

    for input_label in [rctx.attr.yarn_lock] + rctx.attr.data + rctx.attr.preupdate:
        if input_label.repo_name != source_repo:
            fail(
                "all yarn_lock, data, and preupdate labels must come from the same repository; " +
                "{} is not in @@{}".format(input_label, source_repo),
            )

        destination = _label_path(input_label)
        previous = copied.get(destination)
        if previous:
            if previous != str(input_label):
                fail(
                    "multiple input labels map to generated repository path '{}': {} and {}".format(
                        destination,
                        previous,
                        input_label,
                    ),
                )
            continue

        if paths.basename(destination) == _BUILD_FILENAME or destination in _RESERVED_FILENAMES:
            fail("{} is reserved for the generated lockfile package".format(destination))

        rctx.file(
            destination,
            rctx.read(input_label),
            executable = False,
        )
        copied[destination] = str(input_label)

    return copied

def _write_execution_helpers(rctx):
    rctx.file(_EMPTY_NPMRC_FILENAME, "")
    rctx.file(
        _ENV_RUNNER_FILENAME,
        """\
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const [repositoryRoot, command, ...args] = process.argv.slice(2);
if (!repositoryRoot || !command) {
  throw new Error("sanitized environment runner requires a repository root and command");
}
const inherited = process.env;
const allowed = [
  "COMSPEC",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "NODE_EXTRA_CA_CERTS",
  "NO_PROXY",
  "PATH",
  "PATHEXT",
  "SSL_CERT_FILE",
  "SYSTEMROOT",
  "TEMP",
  "TMP",
  "TMPDIR",
  "WINDIR",
  "http_proxy",
  "https_proxy",
  "no_proxy",
];
const env = Object.fromEntries(
  allowed.flatMap((name) => inherited[name] === undefined ? [] : [[name, inherited[name]]]),
);
const home = join(repositoryRoot, ".aspect_rules_js_home");
const emptyNpmrc = join(repositoryRoot, ".aspect_rules_js_empty_npmrc");
Object.assign(env, {
  CI: "true",
  COREPACK_HOME: join(repositoryRoot, ".aspect_rules_js_corepack"),
  HOME: home,
  NPM_CONFIG_GLOBALCONFIG: emptyNpmrc,
  NPM_CONFIG_IGNORE_SCRIPTS: "true",
  NPM_CONFIG_LOCKFILE: "true",
  NPM_CONFIG_LOCKFILE_ONLY: "true",
  NPM_CONFIG_USERCONFIG: emptyNpmrc,
  PNPM_HOME: join(repositoryRoot, ".aspect_rules_js_pnpm"),
  USERPROFILE: home,
  XDG_CACHE_HOME: join(repositoryRoot, ".aspect_rules_js_cache"),
  XDG_CONFIG_HOME: join(repositoryRoot, ".aspect_rules_js_config"),
  npm_config_globalconfig: emptyNpmrc,
  npm_config_ignore_scripts: "true",
  npm_config_lockfile: "true",
  npm_config_lockfile_only: "true",
  npm_config_userconfig: emptyNpmrc,
});

const result = spawnSync(command, args, {
  cwd: process.cwd(),
  encoding: "utf8",
  env,
});
if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
if (result.error) throw result.error;
process.exit(result.status ?? 1);
""",
    )
    rctx.file(
        _LOCK_VERIFY_FILENAME,
        """\
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const [lockfile, expected] = process.argv.slice(2);
const actual = createHash("sha256").update(readFileSync(lockfile)).digest("hex");
if (!expected) {
  console.error(
    `generated pnpm lock requires a pinned checksum; set ` +
    `expected_pnpm_lock_sha256 = "${actual}"`,
  );
  process.exit(1);
}
if (actual !== expected) {
  console.error(`generated pnpm lock SHA-256 mismatch: expected ${expected}, got ${actual}`);
  process.exit(1);
}
""",
    )

def _execute(rctx, host_node, arguments, description, working_directory):
    result = rctx.execute(
        [
            host_node,
            rctx.path(_ENV_RUNNER_FILENAME),
            rctx.path("."),
        ] + arguments,
        quiet = rctx.attr.quiet,
        working_directory = str(working_directory),
    )
    if result.return_code:
        fail("""\
ERROR: {description} exited with status {status}.

STDOUT:
{stdout}

STDERR:
{stderr}
""".format(
            description = description,
            status = result.return_code,
            stdout = result.stdout,
            stderr = result.stderr,
        ))

def _yarn_lock_repository_impl(rctx):
    expected_sha256 = rctx.attr.expected_pnpm_lock_sha256
    if expected_sha256 and (len(expected_sha256) != 64 or any([
        character not in "0123456789abcdef"
        for character in expected_sha256.elems()
    ])):
        fail("expected_pnpm_lock_sha256 must be exactly 64 lowercase hexadecimal characters")

    yarn_lock_path = _label_path(rctx.attr.yarn_lock)
    if paths.basename(yarn_lock_path) != _YARN_LOCK_FILENAME:
        fail("yarn_lock must name a file called '{}', got {}".format(
            _YARN_LOCK_FILENAME,
            rctx.attr.yarn_lock,
        ))

    copied = _copy_inputs(rctx)
    lock_directory = paths.dirname(yarn_lock_path)
    package_json_path = paths.join(lock_directory, "package.json")
    if package_json_path not in copied:
        fail(
            "data must include the package.json beside {} (expected '{}')".format(
                rctx.attr.yarn_lock,
                package_json_path,
            ),
        )

    host_node = rctx.path(Label("@{}_{}//:bin/node".format(
        rctx.attr.node_toolchain_prefix,
        repo_utils.platform(rctx),
    )))
    repository_root = rctx.path(".")
    _write_execution_helpers(rctx)

    for script in rctx.attr.preupdate:
        script_path = _label_path(script)
        rctx.report_progress("Running Yarn lock preprocessing script {}".format(script))
        _execute(
            rctx,
            host_node,
            [host_node, rctx.path(script_path)],
            "node {}".format(script),
            repository_root,
        )

    import_directory = rctx.path(lock_directory if lock_directory else ".")
    rctx.report_progress("Generating {} from {}".format(
        _PNPM_LOCK_FILENAME,
        rctx.attr.yarn_lock,
    ))
    _execute(
        rctx,
        host_node,
        [
            host_node,
            rctx.path(rctx.attr.use_pnpm),
            "import",
        ],
        "pnpm import",
        import_directory,
    )

    pnpm_lock_path = paths.join(lock_directory, _PNPM_LOCK_FILENAME)
    if not rctx.path(pnpm_lock_path).exists:
        fail(
            "pnpm import did not generate '{}' from {}".format(
                pnpm_lock_path,
                rctx.attr.yarn_lock,
            ),
        )

    pnpm_lock_contents = rctx.read(pnpm_lock_path)
    if not pnpm_lock_contents.strip() or "lockfileVersion:" not in pnpm_lock_contents:
        fail("generated '{}' is not a valid non-empty pnpm lockfile".format(pnpm_lock_path))

    _execute(
        rctx,
        host_node,
        [
            host_node,
            rctx.path(_LOCK_VERIFY_FILENAME),
            rctx.path(pnpm_lock_path),
            expected_sha256,
        ],
        "generated pnpm lock checksum verification",
        repository_root,
    )

    build_path = paths.join(lock_directory, _BUILD_FILENAME)
    rctx.file(
        build_path,
        """\
package(default_visibility = ["//visibility:public"])

exports_files(["{lockfile}"])
""".format(lockfile = _PNPM_LOCK_FILENAME),
    )

yarn_lock_repository = repository_rule(
    implementation = _yarn_lock_repository_impl,
    attrs = {
        "data": attr.label_list(
            allow_files = True,
            doc = "Text inputs copied into the generated repository before pnpm import.",
        ),
        "expected_pnpm_lock_sha256": attr.string(
            doc = "Expected lowercase SHA-256 of the generated pnpm-lock.yaml. Empty values fail after reporting the digest to pin.",
        ),
        "node_toolchain_prefix": attr.string(
            default = "nodejs",
            doc = "Prefix of the registered rules_nodejs host toolchain repositories.",
        ),
        "preupdate": attr.label_list(
            allow_files = True,
            doc = "Node.js scripts run from the generated repository root before pnpm import.",
        ),
        "quiet": attr.bool(
            default = True,
            doc = "Suppress successful preprocessing and pnpm import output.",
        ),
        "use_pnpm": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Pinned pnpm.cjs entry point used to import the Yarn lockfile.",
        ),
        "yarn_lock": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Source yarn.lock file.",
        ),
    },
    doc = """\
Generates pnpm-lock.yaml from yarn.lock entirely inside Bazel's external repository cache.

All files read by pnpm import must be declared through data or preupdate. The rule copies
those inputs instead of symlinking them, so their ordinary relative writes stay in the
generated repository. Preprocessing scripts are trusted repository code and must not write
to absolute source paths. The generated lockfile is exported from the Bazel package
containing yarn.lock.
""",
)

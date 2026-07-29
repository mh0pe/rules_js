"""Generate a normalized Yarn graph and verified Yarn cache archives."""

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":yarn_tool_repository.bzl", "YARN_LICENSE_FILENAMES", "download_yarn_release")

_BUILD_FILENAME = "BUILD.bazel"
_ENV_RUNNER_FILENAME = ".aspect_rules_js_env_runner.mjs"
_EXPORTER_FILENAME = ".aspect_rules_js_yarn_exporter.cjs"
_GRAPH_FILENAME = "yarn_graph.json"
_ISOLATED_RC_FILENAME = ".aspect_rules_js_project_yarnrc.yml"
_PINNED_YARN_FILENAME = ".aspect_rules_js_yarn.js"
_YARN_LOCK_FILENAME = "yarn.lock"
_OPERATIONAL_ENVIRON = [
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NODE_EXTRA_CA_CERTS",
    "NO_PROXY",
    "PATH",
    "SSL_CERT_FILE",
    "http_proxy",
    "https_proxy",
    "no_proxy",
]
_RESERVED_FILENAMES = [
    _ENV_RUNNER_FILENAME,
    _EXPORTER_FILENAME,
    _GRAPH_FILENAME,
    _ISOLATED_RC_FILENAME,
    _PINNED_YARN_FILENAME,
] + YARN_LICENSE_FILENAMES

_SUPPORTED_ARCHITECTURE_VALUES = {
    "cpu": [
        "arm",
        "arm64",
        "current",
        "ia32",
        "ppc64",
        "riscv64",
        "s390x",
        "x64",
    ],
    "libc": [
        "current",
        "glibc",
        "musl",
    ],
    "os": [
        "aix",
        "android",
        "current",
        "darwin",
        "freebsd",
        "linux",
        "openbsd",
        "sunos",
        "win32",
    ],
}

def _label_path(label):
    path = paths.normalize(paths.join(label.package, label.name))
    if path == ".." or path.startswith("../") or "/../" in path:
        fail("input label resolves outside its repository: {}".format(label))
    return path

def _yaml_root_indent(source_configuration):
    root_indent = None
    for line in source_configuration.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped in ["---", "..."] or stripped.startswith("%"):
            continue

        indent = 0
        for index in range(len(line)):
            character = line[index]
            if character == " ":
                indent += 1
            elif character == "\t":
                return None, "tabs are not supported in YAML indentation"
            else:
                break
        if root_indent == None or indent < root_indent:
            root_indent = indent

    return root_indent if root_indent != None else 0, None

def _yaml_root_key(line, root_indent):
    if len(line) < root_indent or line[:root_indent] != " " * root_indent:
        return None, None

    body = line[root_indent:]
    stripped = body.strip()
    if not stripped or stripped.startswith("#") or stripped in ["---", "..."] or stripped.startswith("%"):
        return None, None
    if body.startswith(" "):
        return None, None
    if stripped.startswith("---") or stripped.startswith("..."):
        if stripped in ["---", "..."] or stripped.startswith("--- #") or stripped.startswith("... #"):
            return None, None
        return None, "document-prefixed root content cannot be merged safely"
    if stripped.startswith("{"):
        return None, "flow-style root mappings cannot be merged safely"
    if stripped.startswith("?"):
        return None, "complex root mapping keys cannot be merged safely"
    if stripped[0] in ["!", "&", "*"]:
        return None, "tagged, anchored, or aliased root mapping keys cannot be merged safely"

    if body[0] in ["'", "\""]:
        quote = body[0]
        closing_quote = None
        escaped = False
        skip_single_quote = False
        for index in range(1, len(body)):
            character = body[index]
            if skip_single_quote:
                skip_single_quote = False
                continue
            if quote == "\"" and character == "\\":
                escaped = True
                continue
            if character != quote:
                continue
            if quote == "'" and index + 1 < len(body) and body[index + 1] == "'":
                skip_single_quote = True
                continue
            closing_quote = index
            break

        if closing_quote == None:
            return None, "unterminated quoted root mapping key"
        if escaped:
            return None, "escaped quoted root mapping keys cannot be merged safely"
        if not body[closing_quote + 1:].lstrip().startswith(":"):
            return None, None
        return body[1:closing_quote], None

    separator = body.find(":")
    comment = body.find("#")
    if separator == -1 or (comment != -1 and comment < separator):
        return None, None
    return body[:separator].strip(), None

def _yaml_root_keys(source_configuration):
    root_indent, error = _yaml_root_indent(source_configuration)
    if error:
        return {}, error

    keys = {}
    for line in source_configuration.splitlines():
        key, error = _yaml_root_key(line, root_indent)
        if error:
            return {}, error
        if key == "<<":
            return {}, "YAML root merge keys cannot be merged safely"
        if key:
            keys[key] = True
    return keys, None

def _isolated_architecture_configuration(rctx, source_configuration):
    values = {
        "cpu": rctx.attr.supported_cpu,
        "libc": rctx.attr.supported_libc,
        "os": rctx.attr.supported_os,
    }
    if not any(values.values()):
        return source_configuration

    source_keys, source_error = _yaml_root_keys(source_configuration)
    if source_error:
        fail(
            "supported_os/supported_cpu/supported_libc cannot safely extend the " +
            "source .yarnrc.yml: {}".format(source_error),
        )
    if "supportedArchitectures" in source_keys:
        fail(
            "supported_os/supported_cpu/supported_libc cannot be combined with " +
            "supportedArchitectures in the source .yarnrc.yml",
        )

    lines = ["", "# rules_js isolated graph-export target matrix", "supportedArchitectures:"]
    for name in ["os", "cpu", "libc"]:
        configured = values[name] if values[name] else ["current"]
        for value in configured:
            if value not in _SUPPORTED_ARCHITECTURE_VALUES[name]:
                fail(
                    "unsupported Yarn {} architecture '{}'; expected one of {}".format(
                        name,
                        value,
                        _SUPPORTED_ARCHITECTURE_VALUES[name],
                    ),
                )
        lines.append("  {}: [{}]".format(name, ", ".join(configured)))
    return source_configuration.rstrip() + "\n" + "\n".join(lines) + "\n"

def _plan_inputs(rctx, lock_directory, package_json_path):
    source_repo = rctx.attr.yarn_lock.repo_name
    copied = {}
    cleanup_paths = []
    archive_directory = paths.join(lock_directory, "archives")
    text_inputs = []
    binary_inputs = []
    isolated_configuration_written = False

    for input_label in [rctx.attr.yarn_lock] + rctx.attr.data:
        if input_label.repo_name != source_repo:
            fail(
                "all yarn_lock and data labels must come from the same repository; " +
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

        if paths.basename(destination) == _BUILD_FILENAME or paths.basename(destination) in _RESERVED_FILENAMES:
            fail("{} is reserved for the generated graph repository".format(destination))
        if destination == archive_directory or destination.startswith(archive_directory + "/"):
            fail("{} is reserved for verified Yarn cache archives".format(destination))

        content = rctx.read(input_label)
        text_inputs.append((destination, content))
        copied[destination] = str(input_label)
        cleanup_paths.append(destination)
        if paths.basename(destination) == ".yarnrc.yml":
            isolated_configuration = paths.join(paths.dirname(destination), _ISOLATED_RC_FILENAME)
            text_inputs.append((
                isolated_configuration,
                _isolated_architecture_configuration(rctx, content),
            ))
            cleanup_paths.append(isolated_configuration)
            isolated_configuration_written = True

    if not isolated_configuration_written and any([
        rctx.attr.supported_cpu,
        rctx.attr.supported_libc,
        rctx.attr.supported_os,
    ]):
        isolated_configuration = paths.join(lock_directory, _ISOLATED_RC_FILENAME)
        text_inputs.append((
            isolated_configuration,
            _isolated_architecture_configuration(rctx, ""),
        ))
        cleanup_paths.append(isolated_configuration)

    for input_label in rctx.attr.binary_data:
        if input_label.repo_name != source_repo:
            fail(
                "all yarn_lock, data, and binary_data labels must come from the same repository; " +
                "{} is not in @@{}".format(input_label, source_repo),
            )
        destination = _label_path(input_label)
        if destination in copied:
            fail("text and binary inputs both map to '{}'".format(destination))
        if paths.basename(destination) == _BUILD_FILENAME or paths.basename(destination) in _RESERVED_FILENAMES:
            fail("{} is reserved for the generated graph repository".format(destination))
        if destination == archive_directory or destination.startswith(archive_directory + "/"):
            fail("{} is reserved for verified Yarn cache archives".format(destination))
        binary_inputs.append((destination, rctx.path(input_label)))
        copied[destination] = str(input_label)
        cleanup_paths.append(destination)

    if package_json_path not in copied:
        fail(
            "data must include the package.json beside {} (expected '{}')".format(
                rctx.attr.yarn_lock,
                package_json_path,
            ),
        )

    return copied, cleanup_paths, text_inputs, binary_inputs

def _materialize_inputs(rctx, host_node, text_inputs, binary_inputs):
    for destination, content in text_inputs:
        rctx.file(destination, content, executable = False)
    for destination, source_path in binary_inputs:
        copy_result = rctx.execute(
            [
                host_node,
                rctx.path(rctx.attr._input_copy_helper),
                source_path,
                rctx.path(destination),
            ],
            quiet = rctx.attr.quiet,
            timeout = 600,
        )
        if copy_result.return_code:
            _cleanup_repository_outputs(rctx, [destination])
            _fail_execution(copy_result, "verified binary_data copy")

def _relocate_yarn_licenses(rctx, lock_directory):
    if not lock_directory:
        return
    for filename in YARN_LICENSE_FILENAMES:
        rctx.file(
            paths.join(lock_directory, filename),
            rctx.read(filename),
            executable = False,
        )
        rctx.delete(filename)

def _cleanup_repository_outputs(rctx, cleanup_paths):
    for cleanup_path in cleanup_paths + [
        _ENV_RUNNER_FILENAME,
        _EXPORTER_FILENAME,
        ".aspect_rules_js_home",
        ".aspect_rules_js_xdg_cache",
        ".aspect_rules_js_xdg_config",
        ".aspect_rules_js_yarn_cache",
        ".aspect_rules_js_yarn_global",
        _PINNED_YARN_FILENAME,
    ]:
        rctx.delete(cleanup_path)

def _write_execution_helper(rctx):
    rctx.file(
        _ENV_RUNNER_FILENAME,
        """\
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const [repositoryRoot, sourceFormat, command, ...args] = process.argv.slice(2);
if (!repositoryRoot || !sourceFormat || !command) {
  throw new Error("Yarn environment runner requires repository root, source format, and command");
}
const repositoryRootPath = resolve(repositoryRoot);
let configurationDirectory = resolve(process.cwd());
while (true) {
  const environmentFile = join(configurationDirectory, ".env.yarn");
  if (existsSync(environmentFile)) {
    throw new Error(
      `Yarn environment injection is not allowed during native graph export: ${environmentFile}`,
    );
  }
  const executableConfig = join(configurationDirectory, "yarn.config.cjs");
  if (existsSync(executableConfig)) {
    throw new Error(
      `Executable Yarn project configuration is not allowed during native graph export: ${executableConfig}`,
    );
  }
  if (configurationDirectory === repositoryRootPath)
    break;
  const parent = dirname(configurationDirectory);
  if (parent === configurationDirectory || !configurationDirectory.startsWith(repositoryRootPath)) {
    throw new Error("Yarn project directory escapes the generated repository");
  }
  configurationDirectory = parent;
}
configurationDirectory = dirname(repositoryRootPath);
while (true) {
  for (const filename of [
    ".aspect_rules_js_project_yarnrc.yml",
    ".env.yarn",
    "yarn.config.cjs",
  ]) {
    const ambientPath = join(configurationDirectory, filename);
    if (existsSync(ambientPath)) {
      throw new Error(
        `Ambient parent Yarn configuration is not allowed during native graph export: ` +
        `${ambientPath}`,
      );
    }
  }
  const parent = dirname(configurationDirectory);
  if (parent === configurationDirectory)
    break;
  configurationDirectory = parent;
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
  allowed.flatMap(name => inherited[name] === undefined ? [] : [[name, inherited[name]]]),
);
const home = join(repositoryRoot, ".aspect_rules_js_home");
Object.assign(env, {
  CI: "true",
  HOME: home,
  USERPROFILE: home,
  XDG_CACHE_HOME: join(repositoryRoot, ".aspect_rules_js_xdg_cache"),
  XDG_CONFIG_HOME: join(repositoryRoot, ".aspect_rules_js_xdg_config"),
  YARN_CACHE_FOLDER: join(repositoryRoot, ".aspect_rules_js_yarn_cache"),
  YARN_ENABLE_GLOBAL_CACHE: "false",
  YARN_ENABLE_IMMUTABLE_INSTALLS: "true",
  YARN_ENABLE_MIRROR: "false",
  YARN_ENABLE_TELEMETRY: "false",
  YARN_GLOBAL_FOLDER: join(repositoryRoot, ".aspect_rules_js_yarn_global"),
  YARN_IGNORE_PATH: "1",
  YARN_PLUGINS: join(repositoryRoot, ".aspect_rules_js_yarn_exporter.cjs"),
});
if (sourceFormat === "safe-config-inspection") {
  env.YARN_RC_FILENAME = ".aspect_rules_js_no_project_yarnrc.yml";
} else {
  env.YARN_RC_FILENAME = ".aspect_rules_js_project_yarnrc.yml";
}
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

def _execute(rctx, host_node, source_format, arguments, working_directory):
    return rctx.execute(
        [
            host_node,
            rctx.path(_ENV_RUNNER_FILENAME),
            rctx.path("."),
            source_format,
        ] + arguments,
        quiet = rctx.attr.quiet,
        timeout = 3600,
        working_directory = str(working_directory),
    )

def _fail_execution(result, description):
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
    source_format = "auto"

    yarn_lock_path = _label_path(rctx.attr.yarn_lock)
    if paths.basename(yarn_lock_path) != _YARN_LOCK_FILENAME:
        fail("yarn_lock must name a file called '{}', got {}".format(
            _YARN_LOCK_FILENAME,
            rctx.attr.yarn_lock,
        ))

    lock_directory = paths.dirname(yarn_lock_path)
    package_json_path = paths.join(lock_directory, "package.json")
    _, cleanup_paths, text_inputs, binary_inputs = _plan_inputs(
        rctx,
        lock_directory,
        package_json_path,
    )

    host_node = rctx.path(Label("@{}_{}//:bin/node".format(
        rctx.attr.node_toolchain_prefix,
        repo_utils.platform(rctx),
    )))
    project_root = rctx.path(lock_directory if lock_directory else ".")
    download_yarn_release(
        rctx,
        rctx.attr.yarn_version,
        rctx.attr.yarn_sha256,
        bundle_output = _PINNED_YARN_FILENAME,
    )
    _relocate_yarn_licenses(rctx, lock_directory)
    _materialize_inputs(rctx, host_node, text_inputs, binary_inputs)
    yarn_path = rctx.path(_PINNED_YARN_FILENAME)
    rctx.file(_EXPORTER_FILENAME, rctx.read(rctx.attr.exporter), executable = False)
    _write_execution_helper(rctx)

    configuration_directory = lock_directory
    ancestor_count = len(lock_directory.split("/")) if lock_directory else 0
    for _ in range(ancestor_count + 1):
        configuration_path = paths.join(configuration_directory, ".yarnrc.yml")
        if rctx.path(configuration_path).exists:
            inspection_result = _execute(
                rctx,
                host_node,
                "safe-config-inspection",
                [
                    host_node,
                    yarn_path,
                    "rules-js",
                    "inspect-config",
                    "--path",
                    rctx.path(configuration_path),
                ],
                project_root,
            )
            if inspection_result.return_code:
                _cleanup_repository_outputs(rctx, cleanup_paths)
                _fail_execution(inspection_result, "safe Yarn configuration inspection")
        configuration_directory = paths.dirname(configuration_directory)

    version_result = _execute(
        rctx,
        host_node,
        source_format,
        [host_node, yarn_path, "--version"],
        project_root,
    )
    if version_result.return_code:
        _cleanup_repository_outputs(rctx, cleanup_paths)
        _fail_execution(version_result, "pinned yarn.js version check")
    yarn_version = version_result.stdout.strip()
    if not yarn_version or "\n" in yarn_version:
        _cleanup_repository_outputs(rctx, cleanup_paths)
        fail("pinned yarn.js returned an invalid version: {!r}".format(yarn_version))

    rctx.report_progress("Resolving Yarn graph and fetching verified cache archives")
    export_result = _execute(
        rctx,
        host_node,
        source_format,
        [
            host_node,
            yarn_path,
            "rules-js",
            "export-lock",
            "--output",
            rctx.path(paths.join(lock_directory, _GRAPH_FILENAME)),
            "--archives",
            rctx.path(paths.join(lock_directory, "archives")),
            "--expected-graph-sha256",
            rctx.attr.expected_graph_sha256,
            "--repository-root",
            rctx.path("."),
            "--source-format",
            source_format,
            "--source-package",
            lock_directory if lock_directory else ".",
            "--exporter-yarn-version",
            yarn_version,
        ],
        project_root,
    )
    if export_result.return_code:
        _cleanup_repository_outputs(rctx, cleanup_paths)
        _fail_execution(export_result, "native Yarn graph export")

    graph_path = paths.join(lock_directory, _GRAPH_FILENAME)
    if not rctx.path(graph_path).exists:
        _cleanup_repository_outputs(rctx, cleanup_paths)
        fail("native Yarn graph exporter did not generate '{}'".format(graph_path))
    graph_contents = rctx.read(graph_path)
    if not graph_contents.strip() or '"schema_version": 1' not in graph_contents:
        _cleanup_repository_outputs(rctx, cleanup_paths)
        fail("generated '{}' is not a valid non-empty schema-v1 graph".format(_GRAPH_FILENAME))

    _cleanup_repository_outputs(rctx, cleanup_paths)

    rctx.file(
        paths.join(lock_directory, _BUILD_FILENAME),
        """\
package(default_visibility = ["//visibility:public"])

exports_files(
    ["{graph}"] +
    glob(["archives/*.tgz"], allow_empty = True) +
    glob(["archives/*.zip"], allow_empty = True) +
    {licenses},
)

filegroup(
    name = "archives",
    srcs =
        glob(["archives/*.tgz"], allow_empty = True) +
        glob(["archives/*.zip"], allow_empty = True),
)

filegroup(
    name = "licenses",
    srcs = {licenses},
)

filegroup(
    name = "unexpected_files",
    srcs = glob(
        ["**"],
        allow_empty = True,
        exclude = [
            "BUILD.bazel",
            "REPO.bazel",
            "WORKSPACE",
            "{graph}",
            "archives/*.tgz",
            "archives/*.zip",
        ] + {licenses},
    ),
)
""".format(
            graph = _GRAPH_FILENAME,
            licenses = repr(YARN_LICENSE_FILENAMES),
        ),
    )

yarn_lock_repository = repository_rule(
    implementation = _yarn_lock_repository_impl,
    environ = _OPERATIONAL_ENVIRON,
    attrs = {
        "_input_copy_helper": attr.label(
            allow_single_file = True,
            default = Label("//npm/private:yarn_lock_input_copy.mjs"),
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "All manifests, Yarn configuration, patches, and local files read by Yarn.",
        ),
        "expected_graph_sha256": attr.string(
            doc = "Independently reviewed SHA-256 of canonical yarn_graph.json bytes.",
        ),
        "binary_data": attr.label_list(
            allow_files = True,
            doc = "Binary local archives copied byte-for-byte into the generated repository.",
        ),
        "exporter": attr.label(
            allow_single_file = True,
            default = Label("//npm/private:yarn_lock_exporter.cjs"),
            doc = "Local runtime Yarn plugin that emits the normalized graph.",
        ),
        "node_toolchain_prefix": attr.string(
            default = "nodejs",
            doc = "Prefix of the registered rules_nodejs host toolchain repositories.",
        ),
        "quiet": attr.bool(
            default = True,
            doc = "Suppress successful Yarn output.",
        ),
        "supported_cpu": attr.string_list(
            doc = "Bazel-only Yarn target CPUs; defaults to the source configuration.",
        ),
        "supported_libc": attr.string_list(
            doc = "Bazel-only Yarn target libc variants; defaults to the source configuration.",
        ),
        "supported_os": attr.string_list(
            doc = "Bazel-only Yarn target operating systems; defaults to the source configuration.",
        ),
        "yarn_lock": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Source yarn.lock file.",
        ),
        "yarn_sha256": attr.string(
            doc = "Optional assertion that must equal the reviewed official yarn.js SHA-256.",
        ),
        "yarn_version": attr.string(
            default = "4.5.0",
            doc = "Exact reviewed official Yarn runtime version.",
        ),
    },
    doc = """\
Uses an exact pinned official yarn.js and a local runtime plugin to resolve a Yarn lockfile
without pnpm, linking, lifecycle scripts, Corepack, or writes to the source workspace.

The generated repository exports yarn_graph.json and the checksum-verified Yarn cache zip
for every reachable third-party locator. All project inputs must be declared through data
or binary_data.
""",
)

# Exported for focused unit testing of the fail-closed YAML merge boundary.
yarn_lock_repository_testonly = struct(
    yaml_root_keys = _yaml_root_keys,
)

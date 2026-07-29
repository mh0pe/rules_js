"""Unit and analysis-failure tests for the normalized Yarn graph parser."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//npm/private:yarn_graph.bzl", "yarn_graph")

_GRAPH_LABEL = Label("//npm/private/test:yarn_graph_fixture.json")
_PACKAGE_NAME = "left-pad"
_PACKAGE_VERSION = "1.3.0_yarn_0123456789abcdef0123456789abcdef"
_PACKAGE_KEY = "{}@{}".format(_PACKAGE_NAME, _PACKAGE_VERSION)
_SOURCE_LOCK_VERSIONS = {
    "berry-v4": 4,
    "berry-v6": 6,
    "berry-v8": 8,
    "classic-v1": 1,
}

def _configuration(
        node_linker,
        pnp_mode = "strict",
        pnp_fallback_mode = "dependencies-only"):
    return {
        "cacheMigrationMode": "always",
        "checksumBehavior": "throw",
        "compressionLevel": 0,
        "defaultLanguageName": "node",
        "defaultProtocol": "npm:",
        "enableScripts": False,
        "enableStrictSettings": True,
        "enableTransparentWorkspaces": True,
        "httpRetry": 3,
        "httpTimeout": 60000,
        "networkConcurrency": 65,
        "nmHoistingLimits": "none",
        "nmMode": "classic",
        "nmSelfReferences": True,
        "nodeLinker": node_linker,
        "pnpEnableEsmLoader": False,
        "pnpEnableEsmLoaderExplicit": False,
        "pnpEnableInlining": True,
        "pnpFallbackMode": pnp_fallback_mode,
        "pnpIgnorePatterns": [],
        "pnpMode": pnp_mode,
        "pnpShebang": "#!/usr/bin/env node",
        "pnpUnpluggedFolder": ".yarn/unplugged",
        "registryPolicy": {
            "npmAlwaysAuth": False,
            "npmAuditRegistryUrl": None,
            "npmPublishRegistryUrl": None,
            "npmRegistryServerUrl": "https://registry.yarnpkg.com",
            "registries": [],
            "scopes": {},
        },
        "supportedArchitectures": {
            "cpu": ["current"],
            "libc": ["current"],
            "os": ["current"],
        },
        "winLinkType": "junctions",
    }

def _package(resolution):
    return {
        "bins": {},
        "conditions": None,
        "dependencies": {},
        "dependency_meta": {},
        "dev_only": False,
        "friendly_version": "1.3.0",
        "has_bin": False,
        "link_type": "HARD",
        "name": _PACKAGE_NAME,
        "optional": False,
        "optional_dependencies": {},
        "peer_dependencies": {},
        "peer_dependencies_meta": {},
        "requires_build": False,
        "resolution": resolution,
        "version": _PACKAGE_VERSION,
        "yarn_build_metadata": {
            "requires_build": False,
        },
    }

def _graph(
        source_format,
        node_linker = None,
        pnp_mode = "strict",
        pnp_fallback_mode = "dependencies-only"):
    is_classic = source_format == "classic-v1"
    locator_hash = "b" * 128
    if is_classic:
        resolution = {
            "archive": "archives/classic-left-pad.tgz",
            "archive_sha256": "a" * 64,
            "integrity": "sha512-" + ("A" * 86) + "==",
            "legacy_sha1": "d" * 40,
            "locator": "left-pad@npm:1.3.0",
            "locator_hash": locator_hash,
            "resolved_url": "https://registry.yarnpkg.com/left-pad/-/left-pad-1.3.0.tgz#" + ("d" * 40),
            "type": "yarn-classic-tarball",
        }
        declared_version = "1.22.22"
        effective_node_linker = node_linker or "pnpm"
    else:
        resolution = {
            "archive": "archives/left-pad.zip",
            "archive_sha256": "a" * 64,
            "locator": "left-pad@npm:1.3.0",
            "locator_hash": locator_hash,
            "type": "yarn-cache",
            "yarn_checksum": "10c0/" + ("c" * 128),
        }
        declared_version = "4.5.0"
        effective_node_linker = node_linker or "pnp"

    return {
        "importers": {
            ".": {
                "dependencies": {
                    _PACKAGE_NAME: _PACKAGE_VERSION,
                },
                "dev_dependencies": {},
                "install_config": {
                    "hoistingLimits": None,
                    "selfReferences": None,
                },
                "optional_dependencies": {},
            },
        },
        "metadata": {
            "configuration": _configuration(
                effective_node_linker,
                pnp_mode,
                pnp_fallback_mode,
            ),
            "declared_package_managers": [{
                "field": "packageManager",
                "name": "yarn",
                "version": declared_version,
            }],
            "exporter_yarn_version": "4.5.0",
            "lifecycle": {
                "package_manifests_inspected": True,
                "scripts_executed": False,
            },
            "pinned_yarn_compatibility_adjustments": [],
            "source_lock_version": _SOURCE_LOCK_VERSIONS[source_format],
            "source_package": "npm/private/test",
            "workspace_package_extension_adjustments": [],
        },
        "packages": {
            _PACKAGE_KEY: _package(resolution),
        },
        "patched_dependencies": {},
        "schema_version": 1,
        "source_format": source_format,
    }

def _valid_berry_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    for source_format in ["berry-v4", "berry-v6", "berry-v8"]:
        importers, packages, error = yarn_graph.parse_json(
            json.encode(_graph(source_format)),
            _GRAPH_LABEL,
        )

        asserts.equals(env, None, error)
        asserts.equals(env, [_PACKAGE_KEY], packages.keys())
        asserts.equals(env, "yarn-cache", packages[_PACKAGE_KEY]["resolution"]["type"])
        asserts.equals(
            env,
            _GRAPH_LABEL.relative("archives/left-pad.zip"),
            packages[_PACKAGE_KEY]["resolution"]["archive"],
        )
        asserts.equals(env, _PACKAGE_KEY, importers["."]["dependencies"][_PACKAGE_NAME])
    return unittest.end(env)

def _linker_pnp_matrix_test_impl(ctx):
    env = unittest.begin(ctx)
    baseline_importers = None
    baseline_packages = None

    for node_linker in ["pnp", "pnpm", "node-modules"]:
        for pnp_mode in ["strict", "loose"]:
            for pnp_fallback_mode in ["none", "dependencies-only", "all"]:
                importers, packages, error = yarn_graph.parse_json(
                    json.encode(_graph(
                        "berry-v8",
                        node_linker = node_linker,
                        pnp_mode = pnp_mode,
                        pnp_fallback_mode = pnp_fallback_mode,
                    )),
                    _GRAPH_LABEL,
                )

                asserts.equals(env, None, error)
                if baseline_importers == None:
                    baseline_importers = importers
                    baseline_packages = packages
                else:
                    asserts.equals(env, baseline_importers, importers)
                    asserts.equals(env, baseline_packages, packages)
    return unittest.end(env)

def _source_schema_rejection_test_impl(ctx):
    env = unittest.begin(ctx)

    unknown_schema = _graph("berry-v8")
    unknown_schema["source_format"] = "berry-v10"
    unknown_schema["metadata"]["source_lock_version"] = 10
    _, _, error = yarn_graph.parse_json(json.encode(unknown_schema), _GRAPH_LABEL)
    asserts.equals(
        env,
        "Yarn graph parse error: unsupported source_format berry-v10",
        error,
    )

    inconsistent_schema = _graph("berry-v6")
    inconsistent_schema["metadata"]["source_lock_version"] = 8
    _, _, error = yarn_graph.parse_json(json.encode(inconsistent_schema), _GRAPH_LABEL)
    asserts.equals(
        env,
        "Yarn graph parse error: metadata.source_lock_version 8 is inconsistent with source_format berry-v6",
        error,
    )
    return unittest.end(env)

def _valid_classic_graph_test_impl(ctx):
    env = unittest.begin(ctx)
    importers, packages, error = yarn_graph.parse_json(
        json.encode(_graph("classic-v1")),
        _GRAPH_LABEL,
    )

    asserts.equals(env, None, error)
    asserts.equals(env, [_PACKAGE_KEY], packages.keys())
    asserts.equals(
        env,
        "yarn-classic-tarball",
        packages[_PACKAGE_KEY]["resolution"]["type"],
    )
    asserts.equals(
        env,
        _GRAPH_LABEL.relative("archives/classic-left-pad.tgz"),
        packages[_PACKAGE_KEY]["resolution"]["archive"],
    )
    asserts.equals(env, _PACKAGE_KEY, importers["."]["dependencies"][_PACKAGE_NAME])
    return unittest.end(env)

_valid_berry_graph_test = unittest.make(_valid_berry_graph_test_impl)
_valid_classic_graph_test = unittest.make(_valid_classic_graph_test_impl)
_linker_pnp_matrix_test = unittest.make(_linker_pnp_matrix_test_impl)
_source_schema_rejection_test = unittest.make(_source_schema_rejection_test_impl)

def _parse_subject_impl(ctx):
    yarn_graph.parse_json(ctx.attr.content, _GRAPH_LABEL)
    return [DefaultInfo()]

_parse_subject = rule(
    implementation = _parse_subject_impl,
    attrs = {
        "content": attr.string(mandatory = True),
    },
)

def _parse_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_message)
    return analysistest.end(env)

_parse_failure_test = analysistest.make(
    _parse_failure_test_impl,
    attrs = {
        "expected_message": attr.string(mandatory = True),
    },
    expect_failure = True,
)

def _failure_case(name, content, expected_message):
    subject = name + "_subject"
    _parse_subject(
        name = subject,
        content = content,
    )
    _parse_failure_test(
        name = name,
        expected_message = expected_message,
        target_under_test = ":" + subject,
    )

def yarn_graph_tests(name):
    """Instantiates the normalized Yarn graph parser test suite.

    Args:
        name: Name of the generated test suite.
    """
    tests = []

    valid_berry = name + "_valid_berry_test"
    _valid_berry_graph_test(name = valid_berry)
    tests.append(":" + valid_berry)

    valid_classic = name + "_valid_classic_test"
    _valid_classic_graph_test(name = valid_classic)
    tests.append(":" + valid_classic)

    linker_pnp_matrix = name + "_linker_pnp_matrix_test"
    _linker_pnp_matrix_test(name = linker_pnp_matrix)
    tests.append(":" + linker_pnp_matrix)

    source_schema_rejection = name + "_source_schema_rejection_test"
    _source_schema_rejection_test(name = source_schema_rejection)
    tests.append(":" + source_schema_rejection)

    malformed = name + "_malformed_json_test"
    _failure_case(malformed, "{", "unexpected end of file")
    tests.append(":" + malformed)

    unknown_graph = _graph("berry-v8")
    unknown_graph["unexpected"] = True
    unknown = name + "_unknown_top_level_field_test"
    _failure_case(
        unknown,
        json.encode(unknown_graph),
        "top-level graph contains unknown fields: unexpected",
    )
    tests.append(":" + unknown)

    unsafe_archive_graph = _graph("berry-v8")
    unsafe_archive_graph["packages"][_PACKAGE_KEY]["resolution"]["archive"] = "../escape.zip"
    unsafe_archive = name + "_unsafe_archive_path_test"
    _failure_case(
        unsafe_archive,
        json.encode(unsafe_archive_graph),
        "resolution.archive escapes the graph repository",
    )
    tests.append(":" + unsafe_archive)

    unknown_reference_graph = _graph("classic-v1")
    unknown_reference_graph["importers"]["."]["dependencies"][_PACKAGE_NAME] = "9.9.9"
    unknown_reference = name + "_unknown_package_reference_test"
    _failure_case(
        unknown_reference,
        json.encode(unknown_reference_graph),
        "resolves to unknown package key left-pad@9.9.9",
    )
    tests.append(":" + unknown_reference)

    unsafe_url_graph = _graph("classic-v1")
    unsafe_url_graph["packages"][_PACKAGE_KEY]["resolution"]["resolved_url"] = (
        "https://registry.yarnpkg.com/left-pad/-/left-pad-1.3.0.tgz?token=secret#" +
        ("d" * 40)
    )
    unsafe_url = name + "_unsafe_classic_url_test"
    _failure_case(
        unsafe_url,
        json.encode(unsafe_url_graph),
        "must be a credential-free HTTPS URL with one SHA-1 fragment",
    )
    tests.append(":" + unsafe_url)

    native.test_suite(
        name = name,
        tests = tests,
    )

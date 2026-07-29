"""Parser and adapter for normalized Yarn dependency graphs."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load(":utils.bzl", "utils")

_SCHEMA_VERSION = 1
_SUPPORTED_EXPORTER_YARN_VERSIONS = ["4.5.0"]
_SOURCE_LOCK_VERSIONS = {
    "berry-v4": 4,
    "berry-v6": 6,
    "berry-v8": 8,
    "classic-v1": 1,
}
_CONDITION_ORDER = {
    "cpu": 1,
    "libc": 2,
    "os": 0,
}

def _error(message):
    return ({}, {}, "Yarn graph parse error: {}".format(message))

def _expect_dict(value, path):
    if type(value) != "dict":
        fail("Yarn graph parse error: expected {} to be an object, got {}".format(path, type(value)))
    return value

def _expect_keys(value, allowed, path, required = None):
    unknown = sorted([key for key in value.keys() if key not in allowed])
    if unknown:
        fail(
            "Yarn graph parse error: {} contains unknown fields: {}".format(
                path,
                ", ".join(unknown),
            ),
        )
    required = allowed if required == None else required
    missing = sorted([key for key in required if key not in value])
    if missing:
        fail(
            "Yarn graph parse error: {} is missing required fields: {}".format(
                path,
                ", ".join(missing),
            ),
        )

def _expect_string(value, path):
    if type(value) != "string" or not value:
        fail("Yarn graph parse error: expected {} to be a non-empty string".format(path))
    return value

def _expect_bool(value, path):
    if type(value) != "bool":
        fail("Yarn graph parse error: expected {} to be a boolean".format(path))
    return value

def _expect_optional_string(value, path):
    if value == None:
        return None
    return _expect_string(value, path)

def _expect_optional_bool(value, path):
    if value == None:
        return None
    return _expect_bool(value, path)

def _expect_enum(value, allowed, path):
    value = _expect_string(value, path)
    if value not in allowed:
        fail(
            "Yarn graph parse error: {} must be one of {}, got {}".format(
                path,
                ", ".join(allowed),
                value,
            ),
        )
    return value

def _expect_optional_enum(value, allowed, path):
    if value == None:
        return None
    return _expect_enum(value, allowed, path)

def _expect_string_list(value, path):
    if type(value) != "list":
        fail("Yarn graph parse error: expected {} to be a list".format(path))
    for index, item in enumerate(value):
        _expect_string(item, "{}[{}]".format(path, index))
    return value

def _expect_optional_string_list(value, path):
    if value == None:
        return None
    return _expect_string_list(value, path)

def _expect_registry_url(value, path):
    url = _expect_optional_string(value, path)
    if url == None:
        return None
    if url.startswith("https://"):
        remainder = url[len("https://"):]
    elif url.startswith("http://"):
        remainder = url[len("http://"):]
    else:
        remainder = ""
    parts = remainder.split("/")
    host = parts[0] if parts else ""
    if (
        not host or
        "@" in host or
        "?" in remainder or
        "#" in remainder or
        "\\" in remainder or
        any([segment in [".", ".."] for segment in parts[1:]])
    ):
        fail(
            "Yarn graph parse error: {} must be a credential-free HTTP(S) registry URL".format(
                path,
            ),
        )
    return url

def _validate_registry_settings(settings, path):
    settings = _expect_dict(settings, path)
    _expect_keys(
        settings,
        [
            "npmAlwaysAuth",
            "npmAuditRegistryUrl",
            "npmPublishRegistryUrl",
            "npmRegistryServerUrl",
        ],
        path,
    )
    _expect_optional_bool(
        settings.get("npmAlwaysAuth"),
        "{}.npmAlwaysAuth".format(path),
    )
    _expect_registry_url(
        settings.get("npmAuditRegistryUrl"),
        "{}.npmAuditRegistryUrl".format(path),
    )
    _expect_registry_url(
        settings.get("npmPublishRegistryUrl"),
        "{}.npmPublishRegistryUrl".format(path),
    )
    _expect_registry_url(
        settings.get("npmRegistryServerUrl"),
        "{}.npmRegistryServerUrl".format(path),
    )

def _validate_configuration(configuration):
    _expect_keys(
        configuration,
        [
            "cacheMigrationMode",
            "checksumBehavior",
            "compressionLevel",
            "defaultLanguageName",
            "defaultProtocol",
            "enableScripts",
            "enableStrictSettings",
            "enableTransparentWorkspaces",
            "httpRetry",
            "httpTimeout",
            "networkConcurrency",
            "nmHoistingLimits",
            "nmMode",
            "nmSelfReferences",
            "nodeLinker",
            "pnpEnableEsmLoader",
            "pnpEnableEsmLoaderExplicit",
            "pnpEnableInlining",
            "pnpFallbackMode",
            "pnpIgnorePatterns",
            "pnpMode",
            "pnpShebang",
            "pnpUnpluggedFolder",
            "registryPolicy",
            "supportedArchitectures",
            "winLinkType",
        ],
        "metadata.configuration",
    )
    _expect_enum(
        configuration.get("checksumBehavior"),
        ["throw"],
        "metadata.configuration.checksumBehavior",
    )
    _expect_enum(
        configuration.get("cacheMigrationMode"),
        ["always", "match-spec", "required-only"],
        "metadata.configuration.cacheMigrationMode",
    )
    compression_level = configuration.get("compressionLevel")
    if (
        compression_level != "mixed" and
        (type(compression_level) != "int" or compression_level < 0 or compression_level > 9)
    ):
        fail(
            "Yarn graph parse error: metadata.configuration.compressionLevel must be mixed or an integer from 0 through 9",
        )
    _expect_string(
        configuration.get("defaultLanguageName"),
        "metadata.configuration.defaultLanguageName",
    )
    _expect_string(
        configuration.get("defaultProtocol"),
        "metadata.configuration.defaultProtocol",
    )
    if configuration.get("enableStrictSettings") != True:
        fail("Yarn graph parse error: metadata.configuration.enableStrictSettings must be true")
    _expect_bool(
        configuration.get("enableTransparentWorkspaces"),
        "metadata.configuration.enableTransparentWorkspaces",
    )
    for field, minimum in [
        ("httpRetry", 0),
        ("httpTimeout", 1),
        ("networkConcurrency", 1),
    ]:
        value = configuration.get(field)
        if type(value) != "int" or value < minimum:
            fail(
                "Yarn graph parse error: metadata.configuration.{} must be an integer greater than or equal to {}".format(
                    field,
                    minimum,
                ),
            )
    _expect_enum(
        configuration.get("nodeLinker"),
        ["node-modules", "pnp", "pnpm"],
        "metadata.configuration.nodeLinker",
    )
    _expect_enum(
        configuration.get("nmHoistingLimits"),
        ["dependencies", "none", "workspaces"],
        "metadata.configuration.nmHoistingLimits",
    )
    _expect_enum(
        configuration.get("nmMode"),
        ["classic", "hardlinks-global", "hardlinks-local"],
        "metadata.configuration.nmMode",
    )
    _expect_bool(
        configuration.get("nmSelfReferences"),
        "metadata.configuration.nmSelfReferences",
    )
    _expect_bool(
        configuration.get("pnpEnableEsmLoader"),
        "metadata.configuration.pnpEnableEsmLoader",
    )
    _expect_bool(
        configuration.get("pnpEnableEsmLoaderExplicit"),
        "metadata.configuration.pnpEnableEsmLoaderExplicit",
    )
    _expect_bool(
        configuration.get("pnpEnableInlining"),
        "metadata.configuration.pnpEnableInlining",
    )
    _expect_enum(
        configuration.get("pnpFallbackMode"),
        ["all", "dependencies-only", "none"],
        "metadata.configuration.pnpFallbackMode",
    )
    _expect_string_list(
        configuration.get("pnpIgnorePatterns"),
        "metadata.configuration.pnpIgnorePatterns",
    )
    _expect_enum(
        configuration.get("pnpMode"),
        ["loose", "strict"],
        "metadata.configuration.pnpMode",
    )
    _expect_string(
        configuration.get("pnpShebang"),
        "metadata.configuration.pnpShebang",
    )
    _expect_optional_string(
        configuration.get("pnpUnpluggedFolder"),
        "metadata.configuration.pnpUnpluggedFolder",
    )
    _expect_enum(
        configuration.get("winLinkType"),
        ["junctions", "symlinks"],
        "metadata.configuration.winLinkType",
    )

    supported_architectures = _expect_dict(
        configuration.get("supportedArchitectures"),
        "metadata.configuration.supportedArchitectures",
    )
    _expect_keys(
        supported_architectures,
        ["cpu", "libc", "os"],
        "metadata.configuration.supportedArchitectures",
    )
    for field in ["cpu", "libc", "os"]:
        _expect_optional_string_list(
            supported_architectures.get(field),
            "metadata.configuration.supportedArchitectures.{}".format(field),
        )

    registry_policy = _expect_dict(
        configuration.get("registryPolicy"),
        "metadata.configuration.registryPolicy",
    )
    _expect_keys(
        registry_policy,
        [
            "npmAlwaysAuth",
            "npmAuditRegistryUrl",
            "npmPublishRegistryUrl",
            "npmRegistryServerUrl",
            "registries",
            "scopes",
        ],
        "metadata.configuration.registryPolicy",
    )
    _expect_bool(
        registry_policy.get("npmAlwaysAuth"),
        "metadata.configuration.registryPolicy.npmAlwaysAuth",
    )
    for field in [
        "npmAuditRegistryUrl",
        "npmPublishRegistryUrl",
        "npmRegistryServerUrl",
    ]:
        _expect_registry_url(
            registry_policy.get(field),
            "metadata.configuration.registryPolicy.{}".format(field),
        )
    scopes = _expect_dict(
        registry_policy.get("scopes"),
        "metadata.configuration.registryPolicy.scopes",
    )
    for scope, settings in scopes.items():
        _expect_string(
            scope,
            "metadata.configuration.registryPolicy.scopes key",
        )
        _validate_registry_settings(
            settings,
            "metadata.configuration.registryPolicy.scopes[{}]".format(scope),
        )
    registries = registry_policy.get("registries")
    if type(registries) != "list":
        fail("Yarn graph parse error: metadata.configuration.registryPolicy.registries must be a list")
    for index, registry in enumerate(registries):
        path = "metadata.configuration.registryPolicy.registries[{}]".format(index)
        registry = _expect_dict(registry, path)
        _expect_keys(registry, ["settings", "url"], path)
        _expect_registry_url(registry.get("url"), "{}.url".format(path))
        _validate_registry_settings(registry.get("settings"), "{}.settings".format(path))

def _is_lower_hex(value):
    return value and not any([
        character not in "0123456789abcdef"
        for character in value.elems()
    ])

def _expect_lower_hex(value, length, path):
    value = _expect_string(value, path)
    if len(value) != length or not _is_lower_hex(value):
        fail(
            "Yarn graph parse error: {} must be {} lowercase hexadecimal characters".format(
                path,
                length,
            ),
        )
    return value

def _validate_adjustments(value, path):
    if type(value) != "list":
        fail("Yarn graph parse error: expected {} to be a list".format(path))
    result = []
    for index, adjustment in enumerate(value):
        item_path = "{}[{}]".format(path, index)
        adjustment = _expect_dict(adjustment, item_path)
        _expect_keys(adjustment, ["fields", "locator", "locator_hash"], item_path)
        fields = _expect_string_list(
            adjustment.get("fields"),
            "{}.fields".format(item_path),
        )
        if fields != sorted(fields) or len(fields) != len({field: True for field in fields}):
            fail("Yarn graph parse error: {}.fields must be unique and sorted".format(item_path))
        locator = _expect_string(
            adjustment.get("locator"),
            "{}.locator".format(item_path),
        )
        if "://" in locator or "\n" in locator or "\r" in locator or "\t" in locator:
            fail("Yarn graph parse error: {}.locator is not a safe locator display".format(item_path))
        result.append({
            "fields": fields,
            "locator": locator,
            "locator_hash": _expect_lower_hex(
                adjustment.get("locator_hash"),
                128,
                "{}.locator_hash".format(item_path),
            ),
        })
    return result

def _is_exact_semver(value):
    if type(value) != "string" or not value:
        return False
    core = value.split("-", 1)[0]
    parts = core.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if not part or (len(part) > 1 and part.startswith("0")):
            return False
        if any([character not in "0123456789" for character in part.elems()]):
            return False
    if "-" in value:
        prerelease = value.split("-", 1)[1]
        if (
            not prerelease or
            prerelease.startswith(".") or
            prerelease.endswith(".") or
            ".." in prerelease or
            any([
                character not in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.-"
                for character in prerelease.elems()
            ])
        ):
            return False
    return True

def _validate_declared_package_managers(value):
    path = "metadata.declared_package_managers"
    if type(value) != "list":
        fail("Yarn graph parse error: expected {} to be a list".format(path))
    result = []
    seen = {}
    for index, declaration in enumerate(value):
        item_path = "{}[{}]".format(path, index)
        declaration = _expect_dict(declaration, item_path)
        _expect_keys(declaration, ["field", "name", "version"], item_path)
        field = _expect_enum(
            declaration.get("field"),
            ["devEngines.packageManager", "packageManager"],
            "{}.field".format(item_path),
        )
        if field in seen:
            fail("Yarn graph parse error: {} repeats field {}".format(path, field))
        seen[field] = True
        if declaration.get("name") != "yarn":
            fail("Yarn graph parse error: {}.name must be yarn".format(item_path))
        version = declaration.get("version")
        if not _is_exact_semver(version):
            fail(
                "Yarn graph parse error: {}.version must be an exact semantic version".format(
                    item_path,
                ),
            )
        result.append({
            "field": field,
            "name": "yarn",
            "version": version,
        })
    return result

def _validate_bool_metadata_map(value, allowed_fields, path):
    value = _expect_dict(value, path)
    result = {}
    for key, metadata in value.items():
        _expect_string(key, "{} key".format(path))
        item_path = "{}[{}]".format(path, key)
        metadata = _expect_dict(metadata, item_path)
        _expect_keys(metadata, allowed_fields, item_path, required = [])
        normalized = {}
        for field, field_value in metadata.items():
            normalized[field] = _expect_bool(
                field_value,
                "{}.{}".format(item_path, field),
            )
        result[key] = utils.sorted_map(normalized)
    return utils.sorted_map(result)

def _validate_dependency_metadata_map(value, path):
    value = _expect_dict(value, path)
    result = {}
    for ident, ranges in value.items():
        _expect_string(ident, "{} key".format(path))
        ident_path = "{}[{}]".format(path, ident)
        ranges = _expect_dict(ranges, ident_path)
        normalized_ranges = {}
        for dependency_range, metadata in ranges.items():
            _expect_string(dependency_range, "{} range key".format(ident_path))
            item_path = "{}[{}]".format(ident_path, dependency_range)
            metadata = _expect_dict(metadata, item_path)
            _expect_keys(
                metadata,
                ["built", "optional", "unplugged"],
                item_path,
                required = [],
            )
            normalized = {}
            for field, field_value in metadata.items():
                normalized[field] = _expect_bool(
                    field_value,
                    "{}.{}".format(item_path, field),
                )
            normalized_ranges[dependency_range] = utils.sorted_map(normalized)
        result[ident] = utils.sorted_map(normalized_ranges)
    return utils.sorted_map(result)

def _validate_install_config(value, path):
    value = _expect_dict(value, path)
    _expect_keys(value, ["hoistingLimits", "selfReferences"], path)
    return {
        "hoistingLimits": _expect_optional_enum(
            value.get("hoistingLimits"),
            ["dependencies", "none", "workspaces"],
            "{}.hoistingLimits".format(path),
        ),
        "selfReferences": _expect_optional_bool(
            value.get("selfReferences"),
            "{}.selfReferences".format(path),
        ),
    }

def _validate_string_map(value, path):
    value = _expect_dict(value, path)
    result = {}
    for key, item in value.items():
        _expect_string(key, "{} key".format(path))
        result[key] = _expect_string(item, "{}[{}]".format(path, key))
    return utils.sorted_map(result)

def _safe_relative_path(value, path):
    original = _expect_string(value, path)
    if "\\" in original or ":" in original or original.startswith("@") or original.startswith("//"):
        fail("Yarn graph parse error: {} is not a repository-relative path".format(path))
    value = paths.normalize(original)
    if paths.is_absolute(value) or value == ".." or value.startswith("../"):
        fail("Yarn graph parse error: {} escapes the graph repository".format(path))
    return value

def _safe_archive_path(value, path, extension):
    original = _expect_string(value, path)
    normalized = _safe_relative_path(original, path)
    if original != normalized:
        fail("Yarn graph parse error: {} must be a canonical path".format(path))
    archive_name = normalized[len("archives/"):] if normalized.startswith("archives/") else ""
    if (
        not normalized.startswith("archives/") or
        not archive_name or
        "/" in archive_name or
        not archive_name.endswith(extension)
    ):
        fail("Yarn graph parse error: {} must name exactly archives/<file>{}".format(path, extension))
    return normalized

def _validate_classic_resolved_url(value, legacy_sha1, path):
    value = _expect_string(value, path)
    if (
        not value.startswith("https://") or
        "\\" in value or
        "?" in value or
        value.count("#") != 1
    ):
        fail("Yarn graph parse error: {} must be a credential-free HTTPS URL with one SHA-1 fragment".format(path))
    without_scheme = value[len("https://"):]
    authority_and_path = without_scheme.split("#")[0]
    authority_parts = authority_and_path.split("/")
    authority = authority_parts[0] if authority_parts else ""
    fragment = value.split("#")[1]
    if (
        not authority or
        "@" in authority or
        len(authority_parts) < 2 or
        not authority_and_path.endswith(".tgz") or
        fragment != legacy_sha1
    ):
        fail("Yarn graph parse error: {} is not a safe canonical Classic tarball URL".format(path))
    return value

def _validate_sri(value, path):
    value = _expect_string(value, path)
    parts = value.split("-")
    if len(parts) != 2 or parts[0] not in ["sha1", "sha256", "sha384", "sha512"]:
        fail("Yarn graph parse error: {} must be one supported canonical SRI token".format(path))
    encoded = parts[1]
    if not encoded or any([
        character not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
        for character in encoded.elems()
    ]):
        fail("Yarn graph parse error: {} contains invalid base64".format(path))
    padding = len(encoded) - len(encoded.rstrip("="))
    expected_lengths = {
        "sha1": 28,
        "sha256": 44,
        "sha384": 64,
        "sha512": 88,
    }
    expected_padding = {
        "sha1": 1,
        "sha256": 1,
        "sha384": 0,
        "sha512": 2,
    }
    if (
        len(encoded) != expected_lengths[parts[0]] or
        padding != expected_padding[parts[0]] or
        ("=" in encoded[:-padding] if padding else "=" in encoded)
    ):
        fail("Yarn graph parse error: {} has a noncanonical digest length or padding".format(path))
    return value

def _validate_locator_display(value, package_name, locator_hash, path):
    value = _expect_string(value, path)
    if "\\" in value or "\n" in value or "\r" in value or "\t" in value or "://" in value:
        fail("Yarn graph parse error: {} is not a credential-free locator display".format(path))
    redacted_marker = "<redacted>#"
    if redacted_marker in value:
        if (
            not value.startswith("{}@".format(package_name)) or
            not value.endswith(locator_hash[:12]) or
            value.count(redacted_marker) != 1
        ):
            fail("Yarn graph parse error: {} is not the canonical redacted locator display".format(path))
    elif not value.startswith("{}@npm:".format(package_name)) or "?" in value or "#" in value:
        fail("Yarn graph parse error: {} must be an npm locator or canonical redacted locator".format(path))
    return value

def _parse_condition_atom(value, path):
    negative = value.startswith("!")
    atom = value[1:] if negative else value
    parts = atom.split("=")
    if len(parts) != 2 or parts[0] not in _CONDITION_ORDER or not parts[1]:
        fail("Yarn graph parse error: {} contains an unsupported condition atom".format(path))
    if any([character not in "abcdefghijklmnopqrstuvwxyz0123456789_-" for character in parts[1].elems()]):
        fail("Yarn graph parse error: {} contains an invalid condition value".format(path))
    return parts[0], ("!" if negative else "") + parts[1]

def _parse_conditions(value, path):
    if value == None:
        return {}
    value = _expect_string(value, path)
    result = {}
    last_index = -1
    for clause_index, clause in enumerate(value.split(" & ")):
        clause_path = "{} clause {}".format(path, clause_index)
        if clause.startswith("("):
            if not clause.endswith(")"):
                fail("Yarn graph parse error: {} contains malformed condition parentheses".format(clause_path))
            atoms = clause[1:-1].split(" | ")
            if len(atoms) < 2:
                fail("Yarn graph parse error: {} condition groups require at least two atoms".format(clause_path))
        else:
            if "(" in clause or ")" in clause or "|" in clause:
                fail("Yarn graph parse error: {} contains a noncanonical condition group".format(clause_path))
            atoms = [clause]

        key = None
        alternatives = []
        for atom_index, atom in enumerate(atoms):
            atom_key, alternative = _parse_condition_atom(
                atom,
                "{} atom {}".format(clause_path, atom_index),
            )
            if key == None:
                key = atom_key
            elif key != atom_key:
                fail("Yarn graph parse error: {} mixes condition dimensions".format(clause_path))
            alternatives.append(alternative)

        index = _CONDITION_ORDER[key]
        if index <= last_index or key in result:
            fail("Yarn graph parse error: {} conditions must be unique and ordered os, cpu, libc".format(path))
        result[key] = alternatives
        last_index = index
    return utils.sorted_map(result)

def _package_key(name, version):
    return "{}@{}".format(name, version)

def _package_key_for_reference(declared_name, reference):
    if reference.startswith("npm:"):
        actual = reference[4:]
        at = actual.rfind("@")
        if at < 1:
            fail("Yarn graph parse error: malformed npm alias reference {}".format(reference))
        return _package_key(actual[:at], actual[at + 1:])
    return _package_key(declared_name, reference)

def _normalize_dependency_map(value, path, packages, directory_refs):
    value = _expect_dict(value, path)
    result = {}
    for name, reference in value.items():
        _expect_string(name, "{} key".format(path))
        _expect_string(reference, "{}[{}]".format(path, name))
        if reference.startswith("link:"):
            result[name] = utils.importer_to_link(
                name,
                _safe_relative_path(
                    reference[5:],
                    "{}[{}]".format(path, name),
                ),
            )
            continue

        package_key = _package_key_for_reference(name, reference)
        if package_key in directory_refs:
            result[name] = utils.importer_to_link(name, directory_refs[package_key])
        elif package_key in packages:
            result[name] = package_key
        else:
            fail(
                "Yarn graph parse error: {}[{}] reference {} resolves to unknown package key {}".format(
                    path,
                    name,
                    reference,
                    package_key,
                ),
            )
    return utils.sorted_map(result)

def _parse_yarn_graph_json(content, graph_label):
    if not content:
        return _error("file is empty")

    decoded = json.decode(content)
    if type(decoded) != "dict":
        return _error("top-level value must be an object")
    _expect_keys(
        decoded,
        [
            "importers",
            "metadata",
            "packages",
            "patched_dependencies",
            "schema_version",
            "source_format",
        ],
        "top-level graph",
    )
    if decoded.get("schema_version") != _SCHEMA_VERSION:
        return _error(
            "unsupported schema_version {}; expected {}".format(
                decoded.get("schema_version"),
                _SCHEMA_VERSION,
            ),
        )

    raw_importers = decoded.get("importers")
    raw_packages = decoded.get("packages")
    if type(raw_importers) != "dict":
        return _error("importers must be an object")
    if type(raw_packages) != "dict":
        return _error("packages must be an object")
    metadata = decoded.get("metadata")
    if type(metadata) != "dict":
        return _error("metadata must be an object")
    _expect_keys(
        metadata,
        [
            "configuration",
            "declared_package_managers",
            "exporter_yarn_version",
            "lifecycle",
            "pinned_yarn_compatibility_adjustments",
            "source_lock_version",
            "source_package",
            "workspace_package_extension_adjustments",
        ],
        "metadata",
    )
    source_package = metadata.get("source_package")
    expected_source_package = graph_label.package if graph_label.package else "."
    if source_package != expected_source_package:
        return _error(
            "metadata.source_package {} does not match graph label package {}".format(
                source_package,
                expected_source_package,
            ),
        )
    source_format = decoded.get("source_format")
    if source_format not in _SOURCE_LOCK_VERSIONS:
        return _error("unsupported source_format {}".format(source_format))
    if metadata.get("source_lock_version") != _SOURCE_LOCK_VERSIONS[source_format]:
        return _error(
            "metadata.source_lock_version {} is inconsistent with source_format {}".format(
                metadata.get("source_lock_version"),
                source_format,
            ),
        )
    _expect_enum(
        metadata.get("exporter_yarn_version"),
        _SUPPORTED_EXPORTER_YARN_VERSIONS,
        "metadata.exporter_yarn_version",
    )
    _validate_declared_package_managers(
        metadata.get("declared_package_managers"),
    )
    _validate_adjustments(
        metadata.get("pinned_yarn_compatibility_adjustments"),
        "metadata.pinned_yarn_compatibility_adjustments",
    )
    _validate_adjustments(
        metadata.get("workspace_package_extension_adjustments"),
        "metadata.workspace_package_extension_adjustments",
    )
    configuration = _expect_dict(metadata.get("configuration"), "metadata.configuration")
    enable_scripts = _expect_bool(
        configuration.get("enableScripts"),
        "metadata.configuration.enableScripts",
    )
    _validate_configuration(configuration)
    lifecycle = _expect_dict(metadata.get("lifecycle"), "metadata.lifecycle")
    _expect_keys(
        lifecycle,
        ["package_manifests_inspected", "scripts_executed"],
        "metadata.lifecycle",
    )
    if lifecycle.get("package_manifests_inspected") != True:
        return _error("metadata.lifecycle.package_manifests_inspected must be true")
    if lifecycle.get("scripts_executed") != False:
        return _error("metadata.lifecycle.scripts_executed must be false")
    patched_dependencies = _expect_dict(
        decoded.get("patched_dependencies"),
        "patched_dependencies",
    )
    if patched_dependencies:
        return _error("patched_dependencies must be empty in schema v1")

    packages = {}
    directory_refs = {}
    raw_by_key = {}
    for package_key, raw_package in raw_packages.items():
        _expect_string(package_key, "packages key")
        raw_package = _expect_dict(raw_package, "packages[{}]".format(package_key))
        _expect_keys(
            raw_package,
            [
                "bins",
                "conditions",
                "dependencies",
                "dependency_meta",
                "dev_only",
                "friendly_version",
                "has_bin",
                "link_type",
                "name",
                "optional",
                "optional_dependencies",
                "peer_dependencies",
                "peer_dependencies_meta",
                "requires_build",
                "resolution",
                "version",
                "yarn_build_metadata",
            ],
            "packages[{}]".format(package_key),
        )
        name = _expect_string(raw_package.get("name"), "packages[{}].name".format(package_key))
        version = _expect_string(raw_package.get("version"), "packages[{}].version".format(package_key))
        expected_key = _package_key(name, version)
        if package_key != expected_key:
            fail(
                "Yarn graph parse error: package key {} must equal normalized name/version key {}".format(
                    package_key,
                    expected_key,
                ),
            )
        if expected_key in raw_by_key:
            fail("Yarn graph parse error: duplicate normalized package key {}".format(expected_key))
        raw_by_key[expected_key] = raw_package

        resolution = _expect_dict(
            raw_package.get("resolution"),
            "packages[{}].resolution".format(package_key),
        )
        resolution_type = resolution.get("type")
        if resolution_type in ["directory", "virtual-directory"]:
            _expect_keys(resolution, ["directory", "type"], "packages[{}].resolution".format(package_key))
            directory = _safe_relative_path(
                resolution.get("directory"),
                "packages[{}].resolution.directory".format(package_key),
            )
            if resolution_type == "directory":
                directory_refs[package_key] = directory
            normalized_resolution = {
                "directory": directory,
                "type": resolution_type,
            }
        elif resolution_type == "yarn-cache":
            if not source_format.startswith("berry-"):
                fail("Yarn graph parse error: yarn-cache resolution requires a Berry source_format")
            _expect_keys(
                resolution,
                [
                    "archive",
                    "archive_sha256",
                    "locator",
                    "locator_hash",
                    "type",
                    "yarn_checksum",
                ],
                "packages[{}].resolution".format(package_key),
            )
            archive = _safe_archive_path(
                resolution.get("archive"),
                "packages[{}].resolution.archive".format(package_key),
                ".zip",
            )
            archive_sha256 = _expect_string(
                resolution.get("archive_sha256"),
                "packages[{}].resolution.archive_sha256".format(package_key),
            )
            if len(archive_sha256) != 64 or not _is_lower_hex(archive_sha256):
                fail(
                    (
                        "Yarn graph parse error: packages[{}].resolution.archive_sha256 " +
                        "must be 64 lowercase hexadecimal characters"
                    ).format(package_key),
                )
            yarn_checksum = _expect_string(
                resolution.get("yarn_checksum"),
                "packages[{}].resolution.yarn_checksum".format(package_key),
            )
            checksum_parts = yarn_checksum.split("/")
            if (
                len(checksum_parts) != 2 or
                checksum_parts[0] != "10c0" or
                len(checksum_parts[1]) != 128 or
                not _is_lower_hex(checksum_parts[1])
            ):
                fail(
                    "Yarn graph parse error: packages[{}].resolution.yarn_checksum must be Yarn 4.5's 10c0/<128 lowercase hex> form".format(
                        package_key,
                    ),
                )
            locator_hash = _expect_string(
                resolution.get("locator_hash"),
                "packages[{}].resolution.locator_hash".format(package_key),
            )
            if len(locator_hash) != 128 or not _is_lower_hex(locator_hash):
                fail(
                    "Yarn graph parse error: packages[{}].resolution.locator_hash must be 128 lowercase hexadecimal characters".format(
                        package_key,
                    ),
                )
            normalized_resolution = {
                "archive": graph_label.relative(archive),
                "archive_sha256": archive_sha256,
                "locator": _validate_locator_display(
                    resolution.get("locator"),
                    name,
                    locator_hash,
                    "packages[{}].resolution.locator".format(package_key),
                ),
                "locator_hash": locator_hash,
                "type": "yarn-cache",
                "yarn_checksum": yarn_checksum,
            }
        elif resolution_type == "yarn-classic-tarball":
            if source_format != "classic-v1":
                fail("Yarn graph parse error: yarn-classic-tarball resolution requires source_format classic-v1")
            _expect_keys(
                resolution,
                [
                    "archive",
                    "archive_sha256",
                    "integrity",
                    "legacy_sha1",
                    "locator",
                    "locator_hash",
                    "resolved_url",
                    "type",
                ],
                "packages[{}].resolution".format(package_key),
            )
            archive = _safe_archive_path(
                resolution.get("archive"),
                "packages[{}].resolution.archive".format(package_key),
                ".tgz",
            )
            archive_sha256 = _expect_string(
                resolution.get("archive_sha256"),
                "packages[{}].resolution.archive_sha256".format(package_key),
            )
            if len(archive_sha256) != 64 or not _is_lower_hex(archive_sha256):
                fail(
                    "Yarn graph parse error: packages[{}].resolution.archive_sha256 must be 64 lowercase hexadecimal characters".format(
                        package_key,
                    ),
                )
            legacy_sha1 = _expect_string(
                resolution.get("legacy_sha1"),
                "packages[{}].resolution.legacy_sha1".format(package_key),
            )
            if len(legacy_sha1) != 40 or not _is_lower_hex(legacy_sha1):
                fail(
                    "Yarn graph parse error: packages[{}].resolution.legacy_sha1 must be 40 lowercase hexadecimal characters".format(
                        package_key,
                    ),
                )
            locator_hash = _expect_string(
                resolution.get("locator_hash"),
                "packages[{}].resolution.locator_hash".format(package_key),
            )
            if len(locator_hash) != 128 or not _is_lower_hex(locator_hash):
                fail(
                    "Yarn graph parse error: packages[{}].resolution.locator_hash must be 128 lowercase hexadecimal characters".format(
                        package_key,
                    ),
                )
            normalized_resolution = {
                "archive": graph_label.relative(archive),
                "archive_sha256": archive_sha256,
                "integrity": _validate_sri(
                    resolution.get("integrity"),
                    "packages[{}].resolution.integrity".format(package_key),
                ),
                "legacy_sha1": legacy_sha1,
                "locator": _validate_locator_display(
                    resolution.get("locator"),
                    name,
                    locator_hash,
                    "packages[{}].resolution.locator".format(package_key),
                ),
                "locator_hash": locator_hash,
                "resolved_url": _validate_classic_resolved_url(
                    resolution.get("resolved_url"),
                    legacy_sha1,
                    "packages[{}].resolution.resolved_url".format(package_key),
                ),
                "type": "yarn-classic-tarball",
            }
        else:
            fail(
                "Yarn graph parse error: packages[{}].resolution.type must be directory, yarn-cache, or yarn-classic-tarball".format(
                    package_key,
                ),
            )

        yarn_build_metadata = _expect_dict(
            raw_package.get("yarn_build_metadata"),
            "packages[{}].yarn_build_metadata".format(package_key),
        )
        _expect_keys(
            yarn_build_metadata,
            [
                "dependency_meta_built",
                "dependency_meta_unplugged",
                "prefer_unplugged",
                "requires_build",
            ],
            "packages[{}].yarn_build_metadata".format(package_key),
            required = ["requires_build"],
        )
        for field in [
            "dependency_meta_built",
            "dependency_meta_unplugged",
            "prefer_unplugged",
        ]:
            _expect_optional_bool(
                yarn_build_metadata.get(field),
                "packages[{}].yarn_build_metadata.{}".format(package_key, field),
            )
        metadata_requires_build = _expect_bool(
            yarn_build_metadata.get("requires_build"),
            "packages[{}].yarn_build_metadata.requires_build".format(package_key),
        )
        requires_build = _expect_bool(
            raw_package.get("requires_build"),
            "packages[{}].requires_build".format(package_key),
        )
        if requires_build != metadata_requires_build:
            fail(
                "Yarn graph parse error: packages[{}] has inconsistent requires_build evidence".format(
                    package_key,
                ),
            )

        conditions = _parse_conditions(
            raw_package.get("conditions"),
            "packages[{}].conditions".format(package_key),
        )
        dependency_meta = _validate_dependency_metadata_map(
            raw_package.get("dependency_meta"),
            "packages[{}].dependency_meta".format(package_key),
        )
        peer_dependencies_meta = _validate_bool_metadata_map(
            raw_package.get("peer_dependencies_meta"),
            ["optional"],
            "packages[{}].peer_dependencies_meta".format(package_key),
        )
        link_type = _expect_enum(
            raw_package.get("link_type"),
            ["HARD", "SOFT"],
            "packages[{}].link_type".format(package_key),
        )
        raw_bins = _expect_dict(
            raw_package.get("bins"),
            "packages[{}].bins".format(package_key),
        )
        bins = {}
        for bin_name, bin_path in raw_bins.items():
            _expect_string(bin_name, "packages[{}].bins key".format(package_key))
            bins[bin_name] = _safe_relative_path(
                bin_path,
                "packages[{}].bins[{}]".format(package_key, bin_name),
            )
        bins = utils.sorted_map(bins)
        has_bin = _expect_bool(
            raw_package.get("has_bin"),
            "packages[{}].has_bin".format(package_key),
        )
        if has_bin != bool(bins):
            fail(
                "Yarn graph parse error: packages[{}].has_bin is inconsistent with bins".format(
                    package_key,
                ),
            )

        packages[package_key] = {
            "bins": bins,
            "conditions": conditions,
            "dependencies": {},
            "dev_only": _expect_bool(
                raw_package.get("dev_only"),
                "packages[{}].dev_only".format(package_key),
            ),
            "friendly_version": _expect_string(
                raw_package.get("friendly_version"),
                "packages[{}].friendly_version".format(package_key),
            ),
            "has_bin": has_bin,
            "lifecycle_scripts_enabled": enable_scripts,
            "name": name,
            "optional": _expect_bool(
                raw_package.get("optional"),
                "packages[{}].optional".format(package_key),
            ),
            "optional_dependencies": {},
            "requires_build": requires_build,
            "resolution": normalized_resolution,
            "version": version,
            "yarn_build_metadata": yarn_build_metadata,
            "yarn_metadata": {
                "conditions": conditions,
                "dependency_meta": dependency_meta,
                "link_type": link_type,
                "peer_dependencies": {},
                "peer_dependencies_meta": peer_dependencies_meta,
            },
        }

    for package_key, package_info in packages.items():
        raw_package = raw_by_key[package_key]
        package_info["dependencies"] = _normalize_dependency_map(
            raw_package.get("dependencies", {}),
            "packages[{}].dependencies".format(package_key),
            packages,
            directory_refs,
        )
        package_info["optional_dependencies"] = _normalize_dependency_map(
            raw_package.get("optional_dependencies", {}),
            "packages[{}].optional_dependencies".format(package_key),
            packages,
            directory_refs,
        )
        package_info["yarn_metadata"]["peer_dependencies"] = _validate_string_map(
            raw_package.get("peer_dependencies", {}),
            "packages[{}].peer_dependencies".format(package_key),
        )
        duplicate_dependencies = [
            name
            for name in package_info["optional_dependencies"].keys()
            if name in package_info["dependencies"]
        ]
        if duplicate_dependencies:
            fail(
                "Yarn graph parse error: packages[{}] repeats dependencies in optional_dependencies: {}".format(
                    package_key,
                    ", ".join(sorted(duplicate_dependencies)),
                ),
            )

    importers = {}
    for import_path, raw_importer in raw_importers.items():
        _expect_string(import_path, "importers key")
        normalized_path = paths.normalize(import_path)
        if normalized_path != ".":
            normalized_path = _safe_relative_path(normalized_path, "importers key")
        if normalized_path in importers:
            fail(
                "Yarn graph parse error: importer paths {} and {} normalize to the same path".format(
                    import_path,
                    normalized_path,
                ),
            )
        raw_importer = _expect_dict(
            raw_importer,
            "importers[{}]".format(import_path),
        )
        _expect_keys(
            raw_importer,
            ["dependencies", "dev_dependencies", "install_config", "optional_dependencies"],
            "importers[{}]".format(import_path),
        )
        install_config = _validate_install_config(
            raw_importer.get("install_config"),
            "importers[{}].install_config".format(import_path),
        )
        importers[normalized_path] = {
            "yarn_metadata": {
                "install_config": install_config,
            },
        }
        for field in ["dependencies", "dev_dependencies", "optional_dependencies"]:
            importers[normalized_path][field] = _normalize_dependency_map(
                raw_importer.get(field, {}),
                "importers[{}].{}".format(import_path, field),
                packages,
                directory_refs,
            )
        importer_categories = {}
        for field in ["dependencies", "dev_dependencies", "optional_dependencies"]:
            for name in importers[normalized_path][field]:
                previous = importer_categories.get(name)
                if previous != None:
                    fail(
                        "Yarn graph parse error: importers[{}] repeats {} in {} and {}".format(
                            import_path,
                            name,
                            previous,
                            field,
                        ),
                    )
                importer_categories[name] = field

    for package_key, package_info in packages.items():
        for field in ["dependencies", "optional_dependencies"]:
            for reference in package_info[field].values():
                if reference.startswith("link:") and utils.link_to_importer(reference) not in importers:
                    fail(
                        "Yarn graph parse error: packages[{}].{} links unknown importer {}".format(
                            package_key,
                            field,
                            utils.link_to_importer(reference),
                        ),
                    )
    for import_path, importer in importers.items():
        for field in ["dependencies", "dev_dependencies", "optional_dependencies"]:
            for reference in importer[field].values():
                if reference.startswith("link:") and utils.link_to_importer(reference) not in importers:
                    fail(
                        "Yarn graph parse error: importers[{}].{} links unknown importer {}".format(
                            import_path,
                            field,
                            utils.link_to_importer(reference),
                        ),
                    )

    return (utils.sorted_map(importers), utils.sorted_map(packages), None)

yarn_graph = struct(
    parse_json = _parse_yarn_graph_json,
)

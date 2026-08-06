"""Converter for Yarn Berry lockfiles (parsed via yq) to pnpm-compatible format.

This module converts yarn.lock JSON (from yq) to the same structure that
pnpm.parse_pnpm_lock_json() returns, allowing npm_translate_lock to work with
Yarn projects without running pnpm import.

Uses yq.bzl upstream for YAML parsing - no duplication of YAML parsing logic.
"""

def _parse_package_specifier(specifier):
    """Parse a Yarn specifier like 'lodash@npm:4.17.21' into (name, version, protocol).
    
    Args:
        specifier: A Yarn package specifier
        
    Returns:
        A tuple of (name, version, protocol)
    """
    # Handle scoped packages: @scope/name@npm:version
    if specifier.startswith("@"):
        # Find the second @ which separates name from protocol:version
        at_idx = specifier.find("@", 1)
        if at_idx == -1:
            return (specifier, "", "")
        name = specifier[:at_idx]
        rest = specifier[at_idx + 1:]
    else:
        at_idx = specifier.find("@")
        if at_idx == -1:
            return (specifier, "", "")
        name = specifier[:at_idx]
        rest = specifier[at_idx + 1:]
    
    # rest is now "npm:version" or "patch:..." or just "version"
    colon_idx = rest.find(":")
    if colon_idx == -1:
        return (name, rest, "npm")
    
    protocol = rest[:colon_idx]
    version = rest[colon_idx + 1:]
    return (name, version, protocol)

def _resolution_to_pnpm_key(resolution):
    """Convert a Yarn resolution to a pnpm package key.
    
    Yarn resolution: "@babel/core@npm:7.24.0"
    pnpm key: "@babel/core@7.24.0"
    """
    name, version, protocol = _parse_package_specifier(resolution)
    
    if protocol == "npm":
        return "{}@{}".format(name, version)
    elif protocol == "patch":
        return resolution  # Keep as-is for now
    elif protocol == "workspace":
        return "link:{}".format(version)
    else:
        return "{}@{}".format(name, version)

def _yarn_checksum_to_integrity(checksum):
    """Convert Yarn checksum format to integrity hash.
    
    Yarn stores checksums as either:
    - "10c0-<sha512 hex>" (Yarn 4.x cache key format)
    - bare sha512 hex (Yarn 3.x)
    """
    if not checksum:
        return None
    
    # Remove cache key prefix if present (e.g., "10c0-")
    if "-" in checksum:
        parts = checksum.split("-", 1)
        if len(parts) == 2:
            checksum = parts[1]
    
    return "sha512-" + checksum

def _convert_dependencies(deps_dict, lock_entries, descriptors):
    """Convert Yarn dependency map to pnpm format.
    
    Returns a dict mapping package name -> pnpm key (name@version).
    The transitive_closure.bzl expects the values to be full package keys.
    """
    result = {}
    for name, spec in deps_dict.items():
        descriptor = "{}@{}".format(name, spec)
        resolution = descriptors.get(descriptor)
        if resolution:
            entry = lock_entries.get(resolution)
            if entry:
                version = entry.get("version", spec)
                # Return the full pnpm key: name@version
                result[name] = "{}@{}".format(name, version)
            else:
                # No entry found - construct key from name and spec
                result[name] = "{}@{}".format(name, spec)
        else:
            # No descriptor found - construct key from name and spec
            result[name] = "{}@{}".format(name, spec)
    return result

def _resolution_to_tarball_url(name, version, resolution):
    """Convert a resolution to a tarball URL."""
    if resolution.startswith(name + "@npm:"):
        return "https://registry.npmjs.org/{}/-/{}-{}.tgz".format(
            name,
            name.split("/")[-1],
            version,
        )
    return None

def _parse_yarn_lock_json(yarn_lock_json, no_dev = False, no_optional = False):
    """Convert yarn.lock JSON (from yq) to pnpm format.
    
    Args:
        yarn_lock_json: JSON string from yq parsing of yarn.lock YAML
        no_dev: If True, exclude devDependencies
        no_optional: If True, exclude optionalDependencies
        
    Returns:
        Tuple of (importers, packages, patched_dependencies, error)
    """
    root = json.decode(yarn_lock_json)
    
    # Validate it's a Yarn Berry lockfile
    metadata = root.get("__metadata", None)
    if metadata == None:
        return {}, {}, {}, "yarn.lock has no __metadata block; only Yarn Berry lockfiles are supported"
    
    version = str(metadata.get("version", ""))
    supported_versions = ["6", "8", "10"]  # Yarn 3.x, 4.0-4.12, 4.18+
    if version not in supported_versions:
        return {}, {}, {}, "yarn.lock metadata version {} is not supported (supported: {})".format(version, ", ".join(supported_versions))
    
    # Build entries and descriptors maps
    entries = {}
    descriptors = {}
    for key, entry in root.items():
        if key == "__metadata":
            continue
        if type(entry) != "dict":
            return {}, {}, {}, "yarn.lock entry {} is not a map".format(key)
        resolution = entry.get("resolution", None)
        if resolution == None:
            return {}, {}, {}, "yarn.lock entry {} has no resolution".format(key)
        entries[resolution] = entry
        # A key can be multiple descriptors separated by ", "
        for descriptor in key.split(", "):
            descriptors[descriptor] = resolution
    
    importers = {}
    packages = {}
    patched_dependencies = {}
    
    workspace_packages = {}
    
    # First pass: identify workspace packages
    for resolution, entry in entries.items():
        link_type = entry.get("linkType", "hard")
        if link_type == "soft":
            name, version, _ = _parse_package_specifier(resolution)
            workspace_packages[name] = resolution
    
    # Second pass: convert packages
    for resolution, entry in entries.items():
        link_type = entry.get("linkType", "hard")
        
        if link_type == "soft":
            # Workspace package - add to importers
            name, version, _ = _parse_package_specifier(resolution)
            
            deps = entry.get("dependencies", {})
            dev_deps = {}
            opt_deps = entry.get("optionalDependencies", {})
            
            if version.startswith("workspace:"):
                importer_path = version.replace("workspace:", "")
                if importer_path in ("*", "^", "~"):
                    importer_path = "."
            else:
                importer_path = "."
            
            importers[importer_path] = {
                "dependencies": _convert_dependencies(deps, entries, descriptors),
                "dev_dependencies": _convert_dependencies(dev_deps, entries, descriptors) if not no_dev else {},
                "optional_dependencies": _convert_dependencies(opt_deps, entries, descriptors) if not no_optional else {},
            }
        else:
            # Regular package - add to packages
            name, version, protocol = _parse_package_specifier(resolution)
            
            if protocol == "workspace":
                continue
            
            checksum = entry.get("checksum")
            integrity = _yarn_checksum_to_integrity(checksum)
            
            deps = entry.get("dependencies", {})
            opt_deps = entry.get("optionalDependencies", {})
            
            pnpm_deps = _convert_dependencies(deps, entries, descriptors)
            pnpm_opt_deps = _convert_dependencies(opt_deps, entries, descriptors) if not no_optional else {}
            
            conditions = entry.get("conditions")
            cpu = None
            os = None
            if conditions:
                for cond in conditions.split("&"):
                    cond = cond.strip()
                    if cond.startswith("os="):
                        os = [cond[3:]]
                    elif cond.startswith("cpu="):
                        cpu = [cond[4:]]
            
            pnpm_key = "{}@{}".format(name, version)
            
            resolution_info = {
                "integrity": integrity,
            }
            tarball_url = _resolution_to_tarball_url(name, version, resolution)
            if tarball_url:
                resolution_info["tarball"] = tarball_url
            
            packages[pnpm_key] = {
                "name": name,
                "version": version,
                "friendly_version": version,
                "dependencies": pnpm_deps,
                "optional_dependencies": pnpm_opt_deps,
                "has_bin": entry.get("bin") != None,
                "optional": False,
                "resolution": resolution_info,
                "cpu": cpu,
                "os": os,
            }
            
            if protocol == "patch":
                patched_dependencies[name] = {
                    "path": version,
                    "hash": checksum,
                }
    
    if not importers:
        importers["."] = {
            "dependencies": {},
            "dev_dependencies": {},
            "optional_dependencies": {},
        }
    
    return importers, packages, patched_dependencies, None

yarn_lock_starlark = struct(
    parse = _parse_yarn_lock_json,
)

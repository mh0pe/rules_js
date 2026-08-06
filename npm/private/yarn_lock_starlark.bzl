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

def _convert_dependencies(deps_dict, lock_entries, descriptors):
    """Convert Yarn dependency map to pnpm format.
    
    Returns a dict mapping dependency name -> pnpm key (package_name@version).
    The transitive_closure.bzl expects the values to be full package keys.
    
    Note: For aliased dependencies (like react-helmet-async -> @slorber/react-helmet-async),
    the key is the alias name, but the value is the actual package key.
    
    For workspace packages, returns link:package_name|path format.
    
    Yarn Berry v10+ lockfiles may not include range descriptors when only one
    package references a dependency with a range. We handle this by falling
    back to finding the package by name in entries.
    """
    result = {}
    
    # Build a map from package name -> list of (version, resolution, protocol) for fallback
    name_to_versions = {}
    for resolution, entry in lock_entries.items():
        pkg_name, pkg_version, pkg_protocol = _parse_package_specifier(resolution)
        if pkg_name not in name_to_versions:
            name_to_versions[pkg_name] = []
        name_to_versions[pkg_name].append((pkg_version, resolution, pkg_protocol))
    
    for dep_name, spec in deps_dict.items():
        # Try exact descriptor lookup first
        descriptor = "{}@{}".format(dep_name, spec)
        resolution = descriptors.get(descriptor)
        
        if resolution:
            entry = lock_entries.get(resolution)
            if entry:
                # Parse the resolution to get the actual package name and version
                # This handles aliased packages correctly
                pkg_name, pkg_version, pkg_protocol = _parse_package_specifier(resolution)
                
                # Handle workspace packages - use link: format
                if pkg_protocol == "workspace":
                    # Format: link:package_name|relative_path
                    # pkg_version contains the workspace-relative path (e.g., "packages/api")
                    result[dep_name] = "link:{}|{}".format(pkg_name, pkg_version)
                else:
                    result[dep_name] = "{}@{}".format(pkg_name, pkg_version)
                continue
        
        # Fallback: find the package by name in entries
        # This handles cases where Yarn v10 optimizes away range descriptors
        if dep_name in name_to_versions:
            versions = name_to_versions[dep_name]
            if len(versions) == 1:
                # Only one version of this package - use it
                pkg_version, _, pkg_protocol = versions[0]
                if pkg_protocol == "workspace":
                    result[dep_name] = "link:{}|{}".format(dep_name, pkg_version)
                else:
                    result[dep_name] = "{}@{}".format(dep_name, pkg_version)
                continue
            else:
                # Multiple versions - try to match the spec
                # Strip npm: prefix and range chars to find matching version
                clean_spec = spec
                if clean_spec.startswith("npm:"):
                    clean_spec = clean_spec[4:]
                
                # Try exact version match first
                found_match = False
                for pkg_version, _, pkg_protocol in versions:
                    if pkg_version == clean_spec:
                        if pkg_protocol == "workspace":
                            result[dep_name] = "link:{}|{}".format(dep_name, pkg_version)
                        else:
                            result[dep_name] = "{}@{}".format(dep_name, pkg_version)
                        found_match = True
                        break
                
                if found_match:
                    continue
                
                # Check for workspace protocol in spec
                if spec.startswith("workspace:"):
                    # Find the workspace package
                    for pkg_version, _, pkg_protocol in versions:
                        if pkg_protocol == "workspace":
                            result[dep_name] = "link:{}|{}".format(dep_name, pkg_version)
                            found_match = True
                            break
                
                if found_match:
                    continue
                
                # No exact match, use the first one as fallback
                pkg_version, _, pkg_protocol = versions[0]
                if pkg_protocol == "workspace":
                    result[dep_name] = "link:{}|{}".format(dep_name, pkg_version)
                else:
                    result[dep_name] = "{}@{}".format(dep_name, pkg_version)
                continue
        
        # Last resort fallback - strip prefixes and ranges
        clean_spec = spec
        if clean_spec.startswith("npm:"):
            clean_spec = clean_spec[4:]
        if clean_spec.startswith("^") or clean_spec.startswith("~"):
            clean_spec = clean_spec[1:]
        result[dep_name] = "{}@{}".format(dep_name, clean_spec)
    
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
            name, version, protocol = _parse_package_specifier(resolution)
            
            deps = entry.get("dependencies", {})
            dev_deps = {}
            opt_deps = entry.get("optionalDependencies", {})
            
            # For workspace: protocol, version is already the path (e.g., "packages/api-local")
            # For other soft links, use "." as fallback
            if protocol == "workspace":
                importer_path = version if version and version not in ("*", "^", "~") else "."
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
            
            # Skip Yarn's internal patch entries - they reference packages that
            # are already in the lockfile with npm: protocol
            if protocol == "patch":
                continue
            
            checksum = entry.get("checksum")
            # NOTE: Yarn's checksums (10c0/<hex>) are computed over unpacked package
            # contents, NOT the npm tarball. They cannot be used for npm_import integrity.
            # We provide the tarball URL instead and let rules_js download without
            # integrity verification (it may fetch integrity from the npm registry).
            
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
            
            tarball_url = _resolution_to_tarball_url(name, version, resolution)
            resolution_info = {}
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

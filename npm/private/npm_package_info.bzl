"NpmPackageInfo provider"

NpmPackageInfo = provider(
    doc = "Provides the sources of an npm package along with the package name and version",
    fields = {
        "archive_format": "format of src when it is an archive; one of tar, zip, or empty for a directory",
        "archive_root": "archive path prefix containing the package, or empty to select the whole archive",
        "archive_strip_components": "number of leading path components to strip when extracting an archive",
        "package": "name of this npm package",
        "version": "version of this npm package",
        "src": "the sources of this npm package; either an archive file, a TreeArtifact or a source directory",
        "npm_package_store_infos": "A depset of NpmPackageStoreInfo providers from npm dependencies of the package and the packages's transitive deps to use as direct dependencies when linking with npm_link_package",
    },
)

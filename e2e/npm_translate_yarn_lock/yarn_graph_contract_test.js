const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')

const paths = Object.fromEntries(
    process.argv.slice(2).map((argument) => {
        const separator = argument.indexOf('=')
        assert.notEqual(
            separator,
            -1,
            `expected name=path argument, got ${argument}`
        )
        return [argument.slice(0, separator), argument.slice(separator + 1)]
    })
)

const readGraph = (name) => JSON.parse(readFileSync(paths[name], 'utf8'))
const readText = (name) => readFileSync(paths[name], 'utf8')

const LINKER_PACKAGE_KEY =
    'is-number@7.0.0_yarn_060086935c565e62959c3dec0328c8d0'
const LINKER_ARCHIVE =
    'archives/is-number-npm-7.0.0-060086935c-060086935c565e62959c3dec0328c8d0.zip'
const LINKER_ARCHIVE_SHA256 =
    'faf5a4eb4d522e2a5f62a310639554537c4f9345ede8fbb252ecbc7160b6dd96'

const linkerModes = {
    pnpStrict: {
        configuration: {
            nodeLinker: 'pnp',
            pnpFallbackMode: 'dependencies-only',
            pnpMode: 'strict',
        },
        sourcePackage: 'linker_modes/pnp_strict',
    },
    pnpLoose: {
        configuration: {
            nodeLinker: 'pnp',
            pnpFallbackMode: 'dependencies-only',
            pnpMode: 'loose',
        },
        sourcePackage: 'linker_modes/pnp_loose',
    },
    pnpFallbackNone: {
        configuration: {
            nodeLinker: 'pnp',
            pnpFallbackMode: 'none',
            pnpMode: 'strict',
        },
        sourcePackage: 'linker_modes/pnp_fallback_none',
    },
    pnpFallbackAll: {
        configuration: {
            nodeLinker: 'pnp',
            pnpFallbackMode: 'all',
            pnpMode: 'strict',
        },
        sourcePackage: 'linker_modes/pnp_fallback_all',
    },
    nodeModules: {
        configuration: {
            nodeLinker: 'node-modules',
        },
        sourcePackage: 'linker_modes/node_modules_linker',
    },
    pnpm: {
        configuration: {
            nodeLinker: 'pnpm',
        },
        sourcePackage: 'linker_modes/pnpm',
    },
}

const canonicalPayload = (graph) => {
    const copy = structuredClone(graph)
    delete copy.metadata.configuration
    // Source provenance is asserted separately because each configuration needs
    // its own real Yarn project directory.
    delete copy.metadata.source_package
    return copy
}

const modeGraphs = Object.fromEntries(
    Object.entries(linkerModes).map(([name, expectation]) => {
        const graph = readGraph(name)
        assert.equal(graph.source_format, 'berry-v10')
        assert.equal(graph.metadata.exporter_yarn_version, '4.18.0')
        assert.equal(graph.metadata.source_package, expectation.sourcePackage)
        for (const [key, value] of Object.entries(expectation.configuration)) {
            assert.equal(
                graph.metadata.configuration[key],
                value,
                `${name} configuration.${key}`
            )
        }

        const packageEntries = Object.entries(graph.packages)
        assert.equal(
            packageEntries.length,
            1,
            `${name} must export exactly one registry package`
        )
        const [[packageKey, pkg]] = packageEntries
        assert.equal(packageKey, LINKER_PACKAGE_KEY)
        assert.equal(pkg.name, 'is-number')
        assert.equal(pkg.friendly_version, '7.0.0')
        assert.equal(pkg.resolution.archive, LINKER_ARCHIVE)
        assert.equal(pkg.resolution.archive_sha256, LINKER_ARCHIVE_SHA256)
        assert.equal(
            graph.importers['.'].dependencies['is-number'],
            pkg.version
        )

        return [name, graph]
    })
)

const baselinePayload = canonicalPayload(modeGraphs.pnpStrict)
for (const [name, graph] of Object.entries(modeGraphs)) {
    assert.deepEqual(
        canonicalPayload(graph),
        baselinePayload,
        `${name} changed the canonical dependency graph payload`
    )
}

const findPackage = (graph, name, friendlyVersion) => {
    const matches = Object.values(graph.packages).filter(
        (pkg) => pkg.name === name && pkg.friendly_version === friendlyVersion
    )
    assert.equal(
        matches.length,
        1,
        `expected exactly one ${name}@${friendlyVersion}, got ${matches.length}`
    )
    return matches[0]
}

const findPackageVersion = (graph, name, version) => {
    const matches = Object.values(graph.packages).filter(
        (pkg) => pkg.name === name && pkg.version === version
    )
    assert.equal(
        matches.length,
        1,
        `expected exactly one ${name} with graph version ${version}`
    )
    return matches[0]
}

const assertReachability = (fixtureName) => {
    const graph = readGraph(fixtureName)
    const importer = graph.importers['.']
    assert.ok(importer, `${fixtureName} must export its root importer`)

    const debug = findPackage(graph, 'debug', '4.3.4')
    assert.deepEqual(
        {
            dev_only: debug.dev_only,
            optional: debug.optional,
            prod_reachable: debug.prod_reachable,
        },
        {
            dev_only: false,
            optional: false,
            prod_reachable: true,
        }
    )

    const chokidar = findPackage(graph, 'chokidar', '3.5.3')
    const fillRange = findPackage(graph, 'fill-range', '7.1.1')
    const fsevents = findPackage(graph, 'fsevents', '2.3.3')

    assert.equal(importer.dev_dependencies.chokidar, chokidar.version)
    assert.equal(
        importer.optional_dependencies['fill-range'],
        fillRange.version
    )

    const braces = findPackageVersion(
        graph,
        'braces',
        chokidar.dependencies.braces
    )
    assert.equal(
        braces.dependencies['fill-range'],
        fillRange.version,
        `${fixtureName} must reach fill-range through the dev-only chokidar path`
    )
    assert.deepEqual(
        {
            dev_only: fillRange.dev_only,
            optional: fillRange.optional,
            prod_reachable: fillRange.prod_reachable,
        },
        {
            dev_only: false,
            optional: false,
            prod_reachable: false,
        },
        `${fixtureName} must merge the dev and optional reachability paths`
    )

    assert.equal(chokidar.optional_dependencies.fsevents, fsevents.version)
    assert.deepEqual(
        {
            dev_only: fsevents.dev_only,
            optional: fsevents.optional,
            prod_reachable: fsevents.prod_reachable,
        },
        {
            dev_only: true,
            optional: true,
            prod_reachable: false,
        },
        `${fixtureName} must preserve the dev path crossing an optional edge`
    )
}

assertReachability('classicGraph')
assertReachability('berryGraph')

const containsPackage = (defs, name, friendlyVersion) =>
    defs.includes(`__${name}__${friendlyVersion}_yarn_`)

const filterContracts = {
    all: {
        chokidar: true,
        debug: true,
        fillRange: true,
        fsevents: true,
    },
    noDev: {
        chokidar: false,
        debug: true,
        fillRange: true,
        fsevents: false,
    },
    noOptional: {
        chokidar: true,
        debug: true,
        fillRange: true,
        fsevents: false,
    },
    prodOnly: {
        chokidar: false,
        debug: true,
        fillRange: false,
        fsevents: false,
    },
}

for (const fixtureName of ['classic', 'berry']) {
    for (const [filterName, expectation] of Object.entries(filterContracts)) {
        const defs = readText(`${fixtureName}${filterName}`)
        assert.equal(
            containsPackage(defs, 'debug', '4.3.4'),
            expectation.debug,
            `${fixtureName} ${filterName} debug contract`
        )
        assert.equal(
            containsPackage(defs, 'chokidar', '3.5.3'),
            expectation.chokidar,
            `${fixtureName} ${filterName} chokidar contract`
        )
        assert.equal(
            containsPackage(defs, 'fill-range', '7.1.1'),
            expectation.fillRange,
            `${fixtureName} ${filterName} fill-range contract`
        )
        assert.equal(
            containsPackage(defs, 'fsevents', '2.3.3'),
            expectation.fsevents,
            `${fixtureName} ${filterName} fsevents contract`
        )
    }
}

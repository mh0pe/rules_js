const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const isNumber = require('is-number')

if (!isNumber(7) || isNumber('seven')) {
    throw new Error('Yarn v9 fixture did not resolve is-number@7.0.0')
}

const [graphPath, packageJsonPath] = process.argv.slice(2)
const graph = JSON.parse(readFileSync(graphPath, 'utf8'))
const packageJson = JSON.parse(readFileSync(packageJsonPath, 'utf8'))

assert.equal(graph.source_format, 'berry-v9')
assert.equal(graph.metadata.source_lock_version, 9)
assert.equal(graph.metadata.exporter_yarn_version, '4.18.0')
assert.equal(packageJson.packageManager, 'yarn@4.14.1')
assert.deepEqual(graph.metadata.declared_package_managers, [
    {
        field: 'packageManager',
        name: 'yarn',
        version: '4.14.1',
    },
])
const packages = Object.values(graph.packages)
assert.equal(packages.length, 1)
assert.equal(packages[0].name, 'is-number')
assert.equal(packages[0].friendly_version, '7.0.0')
assert.equal(packages[0].resolution.type, 'yarn-cache')

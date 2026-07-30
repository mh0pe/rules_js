const assert = require('node:assert/strict')
const { readFileSync, statSync } = require('node:fs')
const { join } = require('node:path')

const packageRoot = process.argv[2]
assert.ok(packageRoot, 'expected the untouched Berry package TreeArtifact root')

const packageJson = JSON.parse(
    readFileSync(join(packageRoot, 'package.json'), 'utf8')
)
assert.equal(packageJson.name, 'semver')
assert.equal(packageJson.version, '6.3.1')
assert.ok(
    readFileSync(join(packageRoot, 'semver.js'), 'utf8').startsWith(
        'exports = module.exports = SemVer'
    )
)
if (process.platform !== 'win32') {
    assert.notEqual(
        statSync(join(packageRoot, 'bin', 'semver.js')).mode & 0o111,
        0
    )
}

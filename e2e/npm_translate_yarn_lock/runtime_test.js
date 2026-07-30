const assert = require('node:assert/strict')
const { readFileSync } = require('node:fs')
const { join } = require('node:path')
const semver = require('semver')

assert.equal(semver.valid('7.6.3'), '7.6.3')
assert.equal(semver.RULES_JS_PATCH_SENTINEL, 'native-yarn-patch-applied')
const isNumberPath = require.resolve('is-number', {
    paths: [require.resolve('semver')],
})
assert.equal(require(isNumberPath)('42'), true)
assert.equal(
    readFileSync(join(__dirname, 'binary_fixture.dat'), 'utf8'),
    'rules_js native Yarn binary_data source fixture\n'
)

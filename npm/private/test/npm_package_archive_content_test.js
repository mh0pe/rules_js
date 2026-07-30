const assert = require('node:assert/strict')
const { readFileSync, statSync } = require('node:fs')
const { join } = require('node:path')

const packageRoot = process.argv[2]
const validationStamp = process.argv[3]
assert.ok(packageRoot, 'expected the extracted package TreeArtifact root')
assert.equal(
    readFileSync(validationStamp, 'utf8'),
    'archive content validated\n'
)

const hidden = join(packageRoot, '.rules-js-hidden')
assert.equal(readFileSync(hidden, 'utf8'), 'rules_js archive dotfile\n')
assert.equal(
    readFileSync(join(packageRoot, 'nested', 'BUILD.bazel'), 'utf8'),
    'exports_files(["deeper/kept.txt"])\n'
)
assert.equal(
    readFileSync(join(packageRoot, 'nested', 'deeper', 'kept.txt'), 'utf8'),
    'rules_js nested BUILD descendant\n'
)

assert.notEqual(
    statSync(join(packageRoot, 'bin', 'rules-js-parity')).mode & 0o111,
    0
)

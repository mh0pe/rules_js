const assert = require('node:assert/strict')
const {
    existsSync,
    lstatSync,
    readFileSync,
    readlinkSync,
    statSync,
    writeFileSync,
} = require('node:fs')
const { isAbsolute, join } = require('node:path')

const packageRoot = process.argv[2]
const stamp = process.argv[3]
assert.ok(packageRoot, 'expected the extracted package TreeArtifact root')
assert.ok(stamp, 'expected a validation stamp path')

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

const link = join(packageRoot, 'rules-js-hidden-link')
assert.equal(lstatSync(link).isSymbolicLink(), true)
const stagedTarget = readlinkSync(link)
if (isAbsolute(stagedTarget)) {
    // Sandboxed actions stage TreeArtifact children as absolute symlinks back
    // to the execroot. Peel that transport link and inspect the archive's
    // underlying symlink rather than confusing the staging layer for content.
    assert.equal(lstatSync(stagedTarget).isSymbolicLink(), true)
    assert.equal(readlinkSync(stagedTarget), '.rules-js-hidden')
} else {
    assert.equal(stagedTarget, '.rules-js-hidden')
}
assert.equal(readFileSync(link, 'utf8'), 'rules_js archive dotfile\n')
assert.equal(existsSync(join(packageRoot, 'leak')), false)

writeFileSync(stamp, 'archive content validated\n')

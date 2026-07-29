const assert = require('node:assert/strict')

const {
    __internal: {
        assertClassicSelectorAcceptsLockedVersion,
        assertNoClassicSelectiveResolutions,
        rejectPinnedYarnUnsupportedSettings,
    },
} = require('../yarn_lock_exporter.cjs')

const parseRange = (range) => ({
    selector: range.slice(range.lastIndexOf('@') + 1),
})
const satisfiesWithPrereleases = (version, selector) =>
    selector === version || selector === `^${version.split('.')[0]}.0.0`
const stringifyDescriptor = (descriptor) => descriptor.display
const rejectMismatch = (display, range, lockedVersion) => {
    assert.throws(
        () =>
            assertClassicSelectorAcceptsLockedVersion({
                descriptor: { display, range },
                lockedVersion,
                parseRange,
                satisfiesWithPrereleases,
                stringifyDescriptor,
            }),
        (error) => {
            assert.equal(
                error.message,
                `Classic selector ${display} does not accept locked version ${lockedVersion}`
            )
            return true
        }
    )
}

rejectMismatch('direct@npm:^2.0.0', 'npm:^2.0.0', '1.0.0')
rejectMismatch('transitive@npm:^3.0.0', 'npm:^3.0.0', '2.0.0')
rejectMismatch('alias@npm:actual@^2.0.0', 'npm:actual@^2.0.0', '1.0.0')

assert.throws(
    () =>
        assertNoClassicSelectiveResolutions([
            {
                manifest: {
                    resolutions: [{ pattern: 'left-pad', reference: '1.3.0' }],
                },
            },
        ]),
    /Yarn Classic selective resolutions are not supported/
)

assert.throws(
    () =>
        rejectPinnedYarnUnsupportedSettings(
            { pnpmStoreFolder: '.cache/.store' },
            '/generated/project/.yarnrc.yml'
        ),
    /pinned Yarn 4\.5\.0.*fixed project-local node_modules\/\.store/
)

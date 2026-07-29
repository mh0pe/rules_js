const assert = require('node:assert/strict')
const { posix } = require('node:path')

const {
    __internal: {
        classicHttpStatusError,
        classicHttpsProxyIsConfigured,
        classicRetryAfterMilliseconds,
        isAbsoluteYarnUserPath,
        isExecutableYarnGitReference,
        rejectExecutableYarnGitLocator,
        rejectUnsafeYarnLocatorBeforeFetch,
        retryClassicOperation,
    },
} = require('../yarn_lock_exporter.cjs')

for (const reference of [
    'ssh://git@github.com/example/project.git#commit=0123456789abcdef',
    'git:https://github.com/example/project.git#commit=0123456789abcdef',
    'git+ssh://git@github.com/example/project.git#commit=0123456789abcdef',
    'git+http://github.com/example/project.git#commit=0123456789abcdef',
    'git+https://github.com/example/project.git#commit=0123456789abcdef',
    'git@github.com/example/project.git#0123456789abcdef',
    'github:example/project#0123456789abcdef',
    'example/project#0123456789abcdef',
    'https://github.com/example/project.git#commit=0123456789abcdef',
    'https://github.com/example/project/tarball/0123456789abcdef',
]) {
    assert.equal(isExecutableYarnGitReference(reference), true, reference)
    assert.throws(
        () => rejectExecutableYarnGitLocator(reference, 'example@<redacted>'),
        /Unsupported executable Yarn Git fetch locator for example@<redacted>/
    )
}

for (const reference of [
    'npm:1.2.3',
    'https://registry.yarnpkg.com/example/-/example-1.2.3.tgz',
    'https://github.com/example/project/releases/download/v1.2.3/example.tgz',
    'file:../example',
]) {
    assert.equal(isExecutableYarnGitReference(reference), false, reference)
    assert.doesNotThrow(() =>
        rejectExecutableYarnGitLocator(reference, 'example@<redacted>')
    )
}

for (const path of [
    '/tmp/example',
    '/C:/repo/example',
    'C:/repo/example',
    'C:\\repo\\example',
    '//server/share/example',
    '\\\\server\\share\\example',
    '\\example',
]) {
    assert.equal(isAbsoluteYarnUserPath(path), true, path)
}
for (const path of [
    '../example',
    'packages/example',
    '~/patches/example.patch',
    'builtin<compat/example>',
]) {
    assert.equal(isAbsoluteYarnUserPath(path), false, path)
}

const parseProtocol = (reference) => {
    const colon = reference.indexOf(':')
    const hash = reference.indexOf('#', colon + 1)
    return {
        protocol: `${reference.slice(0, colon)}:`,
        source: hash === -1 ? null : reference.slice(colon + 1, hash),
        selector: reference.slice(hash === -1 ? colon + 1 : hash + 1) || null,
        params: null,
    }
}
const repositoryRoot = '/generated'
const projectRoot = '/generated/project'
const locatorPolicyPaths = {
    repositoryRoot,
    projectRoot,
    resolvePath: posix.resolve,
    relativePath: posix.relative,
}
const identityPortablePath = (path) => path
const rejectFilePath = (path, reference = 'file:fixture') =>
    rejectUnsafeYarnLocatorBeforeFetch({
        reference,
        display: 'example@file:<redacted>',
        ...locatorPolicyPaths,
        parseRange: parseProtocol,
        parseFileStyleRange: () => ({
            parentLocator: { reference: 'workspace:.' },
            path,
        }),
        parseLocator: (value) => ({ reference: value }),
        toPortablePath: identityPortablePath,
    })

for (const path of [
    '/tmp/example',
    '/C:/repo/example',
    'C:\\repo\\example',
    '\\\\server\\share\\example',
]) {
    assert.throws(
        () => rejectFilePath(path),
        /Unsupported absolute Yarn file fetch path/
    )
}
assert.doesNotThrow(() => rejectFilePath('../declared/example'))
assert.throws(
    () =>
        rejectFilePath(
            '../../outside/example',
            'file:%2E%2E%2F%2E%2E%2Foutside%2Fexample'
        ),
    /Yarn file fetch path escapes the generated repository/
)

const rejectPatchLocator = ({
    reference = 'patch:fixture',
    selector,
    sourceReference = 'npm:1.2.3',
    parentReference = 'workspace:.',
    nestedFilePath = null,
}) =>
    rejectUnsafeYarnLocatorBeforeFetch({
        reference,
        display: 'example@patch:<redacted>',
        ...locatorPolicyPaths,
        parseRange: (currentReference) =>
            currentReference === reference
                ? {
                      protocol: 'patch:',
                      source: 'source-locator',
                      selector,
                      params:
                          parentReference === null
                              ? null
                              : { locator: 'parent-locator' },
                  }
                : parseProtocol(currentReference),
        parseFileStyleRange: () => ({
            parentLocator: { reference: 'workspace:.' },
            path: nestedFilePath,
        }),
        parseLocator: (value) => ({
            reference:
                value === 'source-locator' ? sourceReference : parentReference,
        }),
        toPortablePath: identityPortablePath,
    })

for (const selector of [
    '/tmp/example.patch',
    'optional!/C:/repo/example.patch',
    'C:\\repo\\example.patch',
    '\\\\server\\share\\example.patch',
]) {
    assert.throws(
        () => rejectPatchLocator({ selector }),
        /Unsupported absolute Yarn user patch path/
    )
}
for (const selector of [
    'patches/example.patch',
    '~/patches/example.patch',
    'optional!builtin<compat/example>',
]) {
    assert.doesNotThrow(() => rejectPatchLocator({ selector }))
}
assert.throws(
    () =>
        rejectPatchLocator({
            reference: 'patch:fixture#~%2F%2E%2E%2F%2E%2E%2Foutside.patch',
            selector: '~/../../outside.patch',
        }),
    /Yarn project patch path escapes the generated repository/
)
assert.throws(
    () =>
        rejectPatchLocator({
            selector: '../../outside.patch',
        }),
    /Yarn user patch path escapes the generated repository/
)
assert.throws(
    () =>
        rejectPatchLocator({
            selector: 'patches/example.patch',
            sourceReference:
                'git+https://github.com/example/project.git#commit=0123456789abcdef',
        }),
    /Unsupported executable Yarn Git fetch locator/
)
assert.throws(
    () =>
        rejectPatchLocator({
            selector: 'patches/example.patch',
            sourceReference:
                'virtual:peer-hash#git+https://github.com/example/project.git#commit=0123456789abcdef',
        }),
    /Unsupported executable Yarn Git fetch locator/
)
for (const sourceReference of [
    'link:../declared/source',
    'portal:../declared/source',
]) {
    assert.throws(
        () =>
            rejectPatchLocator({
                selector: 'patches/example.patch',
                sourceReference,
            }),
        /Unsupported Yarn (?:link|portal): fetch locator/
    )
}
for (const parentReference of [
    'link:../declared/parent',
    'portal:../declared/parent',
]) {
    assert.throws(
        () =>
            rejectPatchLocator({
                selector: 'patches/example.patch',
                parentReference,
            }),
        /Unsupported Yarn (?:link|portal): fetch locator/
    )
}
assert.throws(
    () =>
        rejectPatchLocator({
            selector: 'patches/example.patch',
            sourceReference: 'file:absolute-source',
            nestedFilePath: '/tmp/undeclared-source',
        }),
    /Unsupported absolute Yarn file fetch path/
)
assert.throws(
    () =>
        rejectPatchLocator({
            selector: 'patches/example.patch',
            parentReference: 'file:absolute-parent',
            nestedFilePath: 'C:\\undeclared-parent',
        }),
    /Unsupported absolute Yarn file fetch path/
)

const configuration = (globalValue, explicitlyConfigured = false) => ({
    get: (key) => {
        assert.equal(key, 'httpsProxy')
        return globalValue
    },
    sources: new Map(
        explicitlyConfigured ? [['httpsProxy', '.yarnrc.yml']] : []
    ),
})

assert.equal(classicHttpsProxyIsConfigured(configuration(null), null), false)
assert.equal(
    classicHttpsProxyIsConfigured(configuration(null, true), null),
    true
)
assert.equal(classicHttpsProxyIsConfigured(configuration('', true), ''), true)
assert.equal(classicHttpsProxyIsConfigured(configuration(null), ''), true)
assert.equal(
    classicHttpsProxyIsConfigured(configuration('http://global.example'), ''),
    true
)

assert.equal(classicRetryAfterMilliseconds('600'), 600_000)

void (async () => {
    let calls = 0
    const delays = []
    const result = await retryClassicOperation(
        async () => {
            calls += 1
            if (calls <= 3) {
                throw classicHttpStatusError(
                    'proxy CONNECT returned 503',
                    503,
                    '0'
                )
            }
            return 'ok'
        },
        { retries: 3 },
        async (delay) => delays.push(delay)
    )
    assert.equal(result, 'ok')
    assert.equal(calls, 4)
    assert.equal(delays.length, 3)
    assert.ok(delays[0] >= 1000 && delays[0] < 1100)
    assert.ok(delays[1] >= 2000 && delays[1] < 2100)
    assert.ok(delays[2] >= 4000 && delays[2] < 4100)
})().catch((error) => {
    process.stderr.write(`${error.stack ?? error}\n`)
    process.exitCode = 1
})

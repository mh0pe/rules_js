import assert from 'node:assert/strict'
import {
    lstat,
    mkdir,
    readFile,
    rm,
    symlink,
    writeFile,
} from 'node:fs/promises'
import { join } from 'node:path'

import { copyVerifiedInput } from '../yarn_lock_input_copy.mjs'

const testRoot = join(process.env.TEST_TMPDIR, 'yarn-lock-input-copy')
await rm(testRoot, { recursive: true, force: true })
await mkdir(testRoot, { recursive: true })

const source = join(testRoot, 'source.tgz')
const destination = join(testRoot, 'destination.tgz')
const original = Buffer.from([0, 1, 2, 127, 128, 254, 255])
await writeFile(source, original)
await symlink(source, destination)

await copyVerifiedInput(source, destination)
assert.deepEqual(await readFile(source), original)
assert.deepEqual(await readFile(destination), original)
assert.equal((await lstat(destination)).isSymbolicLink(), false)

const changingSource = join(testRoot, 'changing-source.tgz')
const rejectedDestination = join(testRoot, 'rejected-destination.tgz')
await writeFile(changingSource, original)
await assert.rejects(
    copyVerifiedInput(changingSource, rejectedDestination, {
        afterCopy: () => writeFile(changingSource, Buffer.from('mutated')),
    }),
    /binary_data source changed while it was copied/
)
await assert.rejects(
    lstat(rejectedDestination),
    (error) => error.code === 'ENOENT'
)

const symlinkSource = join(testRoot, 'symlink-source.tgz')
await symlink(source, symlinkSource)
await assert.rejects(
    copyVerifiedInput(symlinkSource, join(testRoot, 'symlink-source-copy.tgz')),
    /binary_data source is not a regular file/
)

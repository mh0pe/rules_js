const assert = require('node:assert/strict')
const { writeFileSync } = require('node:fs')

const output = process.argv[2]
const archiveRoot = process.argv[3]
assert.ok(output, 'expected an output archive path')
assert.ok(archiveRoot, 'expected an archive root')

function writeString(buffer, offset, length, value) {
    const bytes = Buffer.from(value, 'utf8')
    assert.ok(bytes.length <= length, `${value} exceeds its tar field`)
    bytes.copy(buffer, offset)
}

function writeOctal(buffer, offset, length, value) {
    const encoded = `${value.toString(8).padStart(length - 1, '0')}\0`
    writeString(buffer, offset, length, encoded)
}

function splitPath(path) {
    if (Buffer.byteLength(path) <= 100) {
        return { name: path, prefix: '' }
    }

    for (let separator = path.lastIndexOf('/'); separator > 0; ) {
        const prefix = path.slice(0, separator)
        const name = path.slice(separator + 1)
        if (
            Buffer.byteLength(prefix) <= 155 &&
            Buffer.byteLength(name) <= 100
        ) {
            return { name, prefix }
        }
        separator = path.lastIndexOf('/', separator - 1)
    }
    assert.fail(`cannot encode ${path} as a ustar path`)
}

function makeHeader({ path, content, mode, type, linkname = '' }) {
    const header = Buffer.alloc(512)
    const { name, prefix } = splitPath(path)
    writeString(header, 0, 100, name)
    writeOctal(header, 100, 8, mode)
    writeOctal(header, 108, 8, 0)
    writeOctal(header, 116, 8, 0)
    writeOctal(header, 124, 12, content.length)
    writeOctal(header, 136, 12, 0)
    header.fill(0x20, 148, 156)
    writeString(header, 156, 1, type)
    writeString(header, 157, 100, linkname)
    writeString(header, 257, 6, 'ustar\0')
    writeString(header, 263, 2, '00')
    writeString(header, 265, 32, 'rules_js')
    writeString(header, 297, 32, 'rules_js')
    writeString(header, 345, 155, prefix)

    const checksum = header.reduce((sum, byte) => sum + byte, 0)
    writeString(
        header,
        148,
        8,
        `${checksum.toString(8).padStart(6, '0')}\0 `
    )
    return header
}

const entries = [
    {
        path: `${archiveRoot}/.rules-js-hidden`,
        content: Buffer.from('rules_js archive dotfile\n'),
        mode: 0o644,
        type: '0',
    },
    {
        path: `${archiveRoot}/bin/rules-js-parity`,
        content: Buffer.from('#!/usr/bin/env sh\nexit 0\n'),
        mode: 0o755,
        type: '0',
    },
    {
        path: `${archiveRoot}/nested/BUILD.bazel`,
        content: Buffer.from('exports_files(["deeper/kept.txt"])\n'),
        mode: 0o644,
        type: '0',
    },
    {
        path: `${archiveRoot}/nested/deeper/kept.txt`,
        content: Buffer.from('rules_js nested BUILD descendant\n'),
        mode: 0o644,
        type: '0',
    },
    {
        path: `${archiveRoot}/rules-js-hidden-link`,
        content: Buffer.alloc(0),
        mode: 0o777,
        type: '2',
        linkname: '.rules-js-hidden',
    },
    {
        path: `${archiveRoot}-shadow/leak`,
        content: Buffer.from('must not extract\n'),
        mode: 0o644,
        type: '0',
    },
]

const chunks = []
for (const entry of entries) {
    chunks.push(makeHeader(entry))
    chunks.push(entry.content)
    const padding = (512 - (entry.content.length % 512)) % 512
    if (padding) {
        chunks.push(Buffer.alloc(padding))
    }
}
chunks.push(Buffer.alloc(1024))
writeFileSync(output, Buffer.concat(chunks))

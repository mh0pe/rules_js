const assert = require("node:assert/strict");
const debug = require("debug");
const isOdd = require("is-odd");
const semver = require("semver");

assert.equal(typeof debug("rules-js:test"), "function");
assert.equal(isOdd(3), true);
assert.equal(semver.valid("7.5.1"), "7.5.1");

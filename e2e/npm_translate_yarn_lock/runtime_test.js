const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const semver = require("semver");

assert.equal(semver.valid("7.6.3"), "7.6.3");
assert.equal(
  readFileSync(join(__dirname, "binary_fixture.dat"), "utf8"),
  "rules_js native Yarn binary_data source fixture\n",
);

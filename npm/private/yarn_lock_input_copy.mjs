import { createHash } from "node:crypto";
import { constants, createReadStream } from "node:fs";
import {
  copyFile,
  lstat,
  mkdir,
  rename,
  rm,
} from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

async function sha256(path) {
  const hash = createHash("sha256");
  const stream = createReadStream(path);
  for await (const chunk of stream) hash.update(chunk);
  return hash.digest("hex");
}

export async function copyVerifiedInput(source, destination, hooks = {}) {
  const sourcePath = resolve(source);
  const destinationPath = resolve(destination);
  const sourceStat = await lstat(sourcePath);
  if (sourceStat.isSymbolicLink() || !sourceStat.isFile()) {
    throw new Error(`binary_data source is not a regular file: ${sourcePath}`);
  }

  const sourceBefore = await sha256(sourcePath);
  try {
    const existing = await lstat(destinationPath);
    if (!existing.isSymbolicLink()) {
      throw new Error(`binary_data destination already exists: ${destinationPath}`);
    }
    await rm(destinationPath);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  await mkdir(dirname(destinationPath), { recursive: true });
  const temporaryPath = `${destinationPath}.aspect_rules_js_copy_${process.pid}`;
  await rm(temporaryPath, { force: true });
  try {
    await copyFile(sourcePath, temporaryPath, constants.COPYFILE_EXCL);
    if (hooks.afterCopy) await hooks.afterCopy({ sourcePath, temporaryPath });

    const [copied, sourceAfter] = await Promise.all([
      sha256(temporaryPath),
      sha256(sourcePath),
    ]);
    if (sourceAfter !== sourceBefore) {
      throw new Error(
        `binary_data source changed while it was copied: ${sourcePath} ` +
          `(${sourceBefore} != ${sourceAfter})`,
      );
    }
    if (copied !== sourceBefore) {
      throw new Error(
        `binary_data copy does not match its source: ${destinationPath} ` +
          `(${sourceBefore} != ${copied})`,
      );
    }

    await rename(temporaryPath, destinationPath);
    const destinationStat = await lstat(destinationPath);
    if (!destinationStat.isFile() || destinationStat.isSymbolicLink()) {
      throw new Error(`binary_data destination is not a regular copied file: ${destinationPath}`);
    }
    const destinationDigest = await sha256(destinationPath);
    if (destinationDigest !== sourceBefore) {
      throw new Error(
        `binary_data destination changed after copy: ${destinationPath} ` +
          `(${sourceBefore} != ${destinationDigest})`,
      );
    }
    const sourceFinal = await sha256(sourcePath);
    if (sourceFinal !== sourceBefore) {
      throw new Error(
        `binary_data source changed after destination verification: ${sourcePath} ` +
          `(${sourceBefore} != ${sourceFinal})`,
      );
    }
    return sourceBefore;
  } catch (error) {
    await rm(temporaryPath, { force: true });
    await rm(destinationPath, { force: true });
    throw error;
  }
}

async function main() {
  const [source, destination] = process.argv.slice(2);
  if (!source || !destination || process.argv.length !== 4) {
    throw new Error("usage: yarn_lock_input_copy.mjs <source> <destination>");
  }
  await copyVerifiedInput(source, destination);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    process.stderr.write(`${error.stack ?? error}\n`);
    process.exitCode = 1;
  });
}

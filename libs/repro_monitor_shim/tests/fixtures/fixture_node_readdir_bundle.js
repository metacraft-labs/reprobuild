// fixture_node_readdir_bundle.js — adversarial Node.js fixture for
// the shim's directory-enumerate + file-write paths.
//
// Mimics the back-half of a webpack build: enumerate a source tree,
// read each source file, and write a single bundled output. The
// libuv calls:
//
//   fs.readdirSync     →  uv_fs_scandir
//                       →  FindFirstFileW + FindNextFileW + FindClose
//                       →  shim records mrDirectoryEnumerate
//
//   fs.readFileSync    →  uv_fs_open + uv_fs_read + uv_fs_close
//                       →  CreateFileW(OPEN_EXISTING) + ReadFile
//                       →  shim records mrFileOpen + read-side write
//
//   fs.writeFileSync   →  uv_fs_open(O_CREAT|O_WRONLY) + uv_fs_write
//                       →  CreateFileW(CREATE_ALWAYS) + WriteFile
//                       →  shim records mrFileWrite
//
// The fixture creates N source files in source-dir, scans the
// directory, reads each entry, concatenates, and writes the result
// to <output-dir>/bundle.txt.
//
// Invocation:
//   node fixture_node_readdir_bundle.js <source-dir> <output-dir> <N>
//
// Strict-equality contract:
//   - at least 1 mrDirectoryEnumerate record for source-dir (some
//     libuv builds emit one scandir → one record; others fragment
//     across page boundaries, but at least one fires)
//   - 2*N + 1 mrFileWrite records matching source-dir or output-dir
//     (N create-empty + N create-on-write, plus the bundle write)
//   - the bundle.txt file exists at the end and contains all N
//     concatenated source contents

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const args = process.argv.slice(2);
if (args.length !== 3) {
    console.error('usage: node fixture_node_readdir_bundle.js ' +
                  '<source-dir> <output-dir> <N>');
    process.exit(2);
}

const sourceDir = args[0];
const outputDir = args[1];
const N = parseInt(args[2], 10);
if (!Number.isInteger(N) || N <= 0 || N > 256) {
    console.error('N must be 1..256, got ' + args[2]);
    process.exit(2);
}

// Step 1: populate source-dir with N tiny source files.
for (let i = 0; i < N; i++) {
    const p = path.join(sourceDir, `src.${i}.txt`);
    fs.writeFileSync(p, `// source ${i}\n`);
}

// Step 2: enumerate source-dir via fs.readdirSync. libuv's
// uv_fs_scandir lowers to FindFirstFileW + FindNextFileW which the
// shim catches via its directory-enumerate hook.
const entries = fs.readdirSync(sourceDir);
const filtered = entries.filter((name) => name.startsWith('src.'));
if (filtered.length !== N) {
    console.error('readdir found ' + filtered.length +
                  ' src.* entries, expected ' + N);
    process.exit(3);
}

// Step 3: read each file and bundle.
let bundled = '';
for (const name of filtered.sort()) {
    bundled += fs.readFileSync(path.join(sourceDir, name), 'utf8');
}

// Step 4: write the bundle.
const bundlePath = path.join(outputDir, 'bundle.txt');
fs.writeFileSync(bundlePath, bundled);

console.log('OK ' + N + ' sources bundled to ' + bundlePath);

// fixture_node_fs_read.js — adversarial Node.js fixture for the
// shim's file-read path.
//
// Mimics webpack's hot-path module-loading pattern: read N source
// files in rapid succession via Node's fs.readFileSync. Each read
// resolves to libuv's uv_fs_open + uv_fs_read + uv_fs_close, which
// on Windows lower to:
//
//   - CreateFileW(OPEN_EXISTING, GENERIC_READ) → shim records mrFileOpen
//   - ReadFile → shim records mrFileOpen-attached read evidence
//   - CloseHandle → shim records nothing observable (handle key only)
//
// libuv resolves the win-side calls through kernel32 imports declared
// with __declspec(dllimport); the shim's IAT patch + inline detour
// must catch both shapes (libuv embeds a static kernel32 import table,
// and node's V8/icu DLLs reach kernel32 through their own IATs).
//
// Invocation:
//   node fixture_node_fs_read.js <source-dir> <N>
//
// Strict-equality contract: the depfile must contain exactly N
// mrFileOpen records whose path matches one of the source-dir entries.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const args = process.argv.slice(2);
if (args.length !== 2) {
    console.error('usage: node fixture_node_fs_read.js <source-dir> <N>');
    process.exit(2);
}

const sourceDir = args[0];
const N = parseInt(args[1], 10);
if (!Number.isInteger(N) || N <= 0 || N > 256) {
    console.error('N must be 1..256, got ' + args[1]);
    process.exit(2);
}

// Pre-populate the source-dir with N tiny files so the reads succeed.
// We do this from the fixture itself so the test driver doesn't have
// to: the createFile/write here ALSO get recorded, which the test
// must account for (we use a different marker substring for the
// source-files vs the populated-files to keep the counts
// distinguishable).
//
// NOTE: the populate-side mrFileOpen/mrFileWrite records appear in the
// depfile too, but they go to paths with the "fr.<i>.src" suffix
// while the read-side records have the same paths (different mode
// flag). The test counts only mrFileOpen events; both write-side
// (during populate) and read-side (during the loop below) are
// mrFileOpen events to the same paths, so a strict equality of "2*N
// mrFileOpen records matching the marker" verifies both passes
// executed.

for (let i = 0; i < N; i++) {
    const p = path.join(sourceDir, `fr.${i}.src`);
    fs.writeFileSync(p, `// file ${i}\n`);
}

for (let i = 0; i < N; i++) {
    const p = path.join(sourceDir, `fr.${i}.src`);
    const contents = fs.readFileSync(p, 'utf8');
    if (!contents.includes('file ' + i)) {
        console.error('content mismatch at index ' + i);
        process.exit(3);
    }
}

console.log('OK ' + N + ' files');

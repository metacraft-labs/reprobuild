// fixture_node_fs_stat.js — adversarial Node.js fixture for the
// shim's path-probe path.
//
// Mimics webpack's module-resolution chain. When require('foo') runs,
// Node tries every candidate path in sequence:
//
//   ./foo.js
//   ./foo/index.js
//   ./foo/package.json
//   ./node_modules/foo.js
//   ./node_modules/foo/index.js
//   ./node_modules/foo/package.json
//   ../node_modules/foo.js
//   ... up to the filesystem root
//
// Each candidate that doesn't exist generates a stat() syscall →
// libuv's uv_fs_stat → Win32 GetFileAttributesExW (or wstat / stat
// depending on the path shape) → the shim's GetFileAttributesExW
// hook callback. The shim records an mrPathProbe event for each
// non-existent path. webpack's module-graph resolution can generate
// thousands of these probes in a single build.
//
// Invocation:
//   node fixture_node_fs_stat.js <probe-dir> <N>
//
// Strict-equality contract: the depfile must contain exactly N
// mrPathProbe records whose path matches the probe-dir + a per-probe
// suffix. None of the probed paths exist (we never create them) so
// every stat() returns ENOENT, which the shim must still record.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const args = process.argv.slice(2);
if (args.length !== 2) {
    console.error('usage: node fixture_node_fs_stat.js <probe-dir> <N>');
    process.exit(2);
}

const probeDir = args[0];
const N = parseInt(args[1], 10);
if (!Number.isInteger(N) || N <= 0 || N > 1024) {
    console.error('N must be 1..1024, got ' + args[1]);
    process.exit(2);
}

// Issue N stats against non-existent paths. We use fs.statSync inside
// a try/catch because fs.statSync throws on ENOENT — the throw is
// expected; the syscall and its recording happened before the
// exception was raised, which is the load-bearing observation.

let observed = 0;
for (let i = 0; i < N; i++) {
    const p = path.join(probeDir, `probe.${i}.missing`);
    try {
        fs.statSync(p);
    } catch (e) {
        if (e.code === 'ENOENT') {
            observed += 1;
        } else {
            console.error('unexpected error at index ' + i + ': ' + e.code);
            process.exit(3);
        }
    }
}

if (observed !== N) {
    console.error('observed ' + observed + ' ENOENTs, expected ' + N);
    process.exit(4);
}

console.log('OK ' + N + ' probes');

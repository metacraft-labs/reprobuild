// fixture_node_webpack_proxy.js — minimal Node.js script that exercises
// the same APIs webpack uses heavily, so we can reproduce build-engine
// wedges at the fs-snoop integration level without needing the full
// webpack toolchain.
//
// Operations (in order):
//   1. fs.readdirSync against the working tree's node_modules sibling
//      (or a fallback directory). Spec-required mrDirectoryEnumerate.
//   2. fs.statSync against N candidate paths (mrPathProbe via
//      NtQueryInformationByName).
//   3. fs.readFileSync against N tiny source files (mrFileOpen via
//      NtCreateFile + ReadFile).
//   4. Emit M lines of progress-style stdout — mimics webpack's
//      --progress flood that wedges the build engine's pipe-captured
//      stdio drain.
//   5. fs.writeFileSync of a bundle file (mrFileWrite).
//
// Invocation:
//   node fixture_node_webpack_proxy.js <source-dir> <output-dir> <N> <M>
//
// On success prints ``OK n=<N> m=<M>`` and exits 0.

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const args = process.argv.slice(2);
if (args.length !== 4) {
    console.error('usage: node fixture_node_webpack_proxy.js ' +
                  '<source-dir> <output-dir> <N> <M>');
    process.exit(2);
}

const sourceDir = args[0];
const outputDir = args[1];
const N = parseInt(args[2], 10);
const M = parseInt(args[3], 10);
if (!Number.isInteger(N) || N <= 0 || N > 1024) {
    console.error('N must be 1..1024, got ' + args[2]);
    process.exit(2);
}
if (!Number.isInteger(M) || M < 0 || M > 200000) {
    console.error('M must be 0..200000, got ' + args[3]);
    process.exit(2);
}

// Step 1: populate source-dir with N tiny files (so steps 2/3 have
// real paths to operate on).
for (let i = 0; i < N; i++) {
    const p = path.join(sourceDir, `src.${i}.txt`);
    fs.writeFileSync(p, `// source ${i}\n`);
}

// Step 2: fs.readdirSync — the spec-required directory-enumerate op.
const entries = fs.readdirSync(sourceDir);
const filtered = entries.filter((n) => n.startsWith('src.'));
if (filtered.length !== N) {
    console.error('readdir found ' + filtered.length +
                  ' src.* entries, expected ' + N);
    process.exit(3);
}

// Step 3: fs.statSync against non-existent siblings — exercises
// NtQueryInformationByName / NtQueryAttributesFile probe paths.
let observed = 0;
for (let i = 0; i < N; i++) {
    const p = path.join(sourceDir, `probe.${i}.missing`);
    try {
        fs.statSync(p);
    } catch (e) {
        if (e.code === 'ENOENT') observed += 1;
    }
}

// Step 4: read each existing source — exercises CreateFileW + ReadFile.
let totalBytes = 0;
for (const name of filtered.sort()) {
    const buf = fs.readFileSync(path.join(sourceDir, name));
    totalBytes += buf.length;
}

// Step 5: emit M progress-style lines on stdout. This is what wedges
// the build engine — it captures stdio via a fixed-size pipe and
// drains it via a 50ms-tick pollCompletion. At high write rates the
// pipe fills before the next drain.
for (let i = 0; i < M; i++) {
    // Lines are ~80 bytes — comparable to webpack's progress emissions.
    process.stdout.write(`[progress] tick ${i} / ${M} files=${N} bytes=${totalBytes}\n`);
}

// Step 6: write the bundle output.
fs.writeFileSync(path.join(outputDir, 'bundle.txt'),
                 `bundle: N=${N} M=${M} bytes=${totalBytes}\n`);

console.log(`OK n=${N} m=${M} probes=${observed} bytes=${totalBytes}`);

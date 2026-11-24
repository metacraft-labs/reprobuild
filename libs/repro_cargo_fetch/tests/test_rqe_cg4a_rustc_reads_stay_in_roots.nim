## A registry crate's rustc edge, run with the store-root Rust toolchain,
## reads nothing outside the logical roots and writes a portable record.
##
## One fixture crate (`rqreads`, a plain library) is fetched into a crate
## store under the store root, and its rustc edge (`registryCrateEdge`, with
## its `--remap-path-prefix`) runs through the real engine and monitor with
## the relocated store-root `rustc`, under the logical roots `repro build`
## declares for a project with that store root (`declaredFilesystemRoots`).
## The setup is `store_root_rust.nim`'s.
##
## The verdict asserted is the engine's own, the one it records with the
## edge's result (`finishPortableRecord`): the result is `portable`, the
## trace carries `portable-fingerprint` and never
## `portable-fingerprint-unavailable`, and no trace line names a read
## `outside every logical root`. That verdict already includes the cache's
## embedded-path scan of the outputs (Caching-Architecture D4,
## `embeddedRootReason`), which turns a record whose rlib or rmeta names a
## root's physical path non-portable; the test also runs that scan
## (`scanOutputForEmbeddedRoots`) over the rlib and the rmeta for every
## tracked root itself, so a finding is shown with where it was.
##
## When the verdict exists: rustc reads unseeded entropy (its hash maps are
## randomly seeded), so the engine withholds the first run's result, and the
## second run, the determinism probe, records it when the outputs are
## byte-identical. The engine computes the portable verdict when it records
## a result, so the second run carries it; the third is a local cache hit,
## whose portable record the engine derives from the second run's accesses,
## and it must agree.
##
## Vacuity: the monitor saw the edge read the relocated rustc's prefix, the
## store-root C library rustc runs on, and the crate's prefix. A verdict over
## a run the monitor did not enter would be portable for no reason.
##
## Falsifying mutations (run by hand, not in this file): running the edge
## with the host's rustc (here the dev shell's, from the Nix store) makes the
## record non-portable, and the trace names the read
## (`portable-fingerprint-unavailable ... outside every logical root`);
## dropping the remap from the edge leaves the store root's physical path in
## the rlib, which the D4 scan refuses, so the record is non-portable.
##
## No mocks: the catalog's toolchain and the engine's realizer, the
## production fetch, store and edge, the real engine and monitor, a real
## HTTPS server on loopback. Linux x86_64 only, where the catalog relocates
## the Rust toolchain; elsewhere the case is skipped with the reason.

import std/[strutils, tables, unittest]

import repro_test_support/reasoned_skip

import ./store_root_rust

let run = newCrateRun("cg4a-reads", @[
  FixturePackage(name: "rqreads", version: "0.1.0",
    files: @[("src/lib.rs",
      "use std::collections::HashMap;\n" &
      "pub fn count(words: &[&str]) -> usize {\n" &
      "  let mut m = HashMap::new();\n" &
      "  for w in words { *m.entry(*w).or_insert(0usize) += 1; }\n" &
      "  if m.len() > 99 { panic!(\"too many\") }\n  m.len()\n}\n")])])

suite "a store-root rustc edge of a registry crate":
  test "reads stay in the logical roots and the record is portable":
    if not run.ok:
      skip(run.why)
    else:
      let rustc = run.tc.rustc.executable
      let e = registryCrateEdge(run.rows["rqreads"], run.crateStore,
        rustc, run.outRoot("units"), DevProfileArgs)
      check e.prefix.inside(run.tc.storeRoot)
      check e.action.argv[0] == rustc
      var runs: seq[EdgeRun]
      for i in 1 .. 3:
        let r = run.runOnce([e.action])[e.action.id]
        let res = r.result
        checkpoint("run " & $i & ": " & $res.status & " " &
          $res.cacheDecision & " " & res.reason & "; portable " &
          $res.portable & " (" & res.portableReason & ")" &
          (if res.stderr.len > 0: "\nstderr: " & res.stderr else: "") &
          "\ntrace:\n  " & r.trace.join("\n  "))
        require res.status in {asSucceeded, asCacheHit}
        runs.add r
      echo "    runs: " & $runs[0].result.status & ", " &
        $runs[1].result.status & ", " & $runs[2].result.status
      echo "    run 2 verdict: " & runs[1].verdict
      echo "    run 3 verdict: " & runs[2].verdict

      # Vacuity: the monitor entered the store-root compiler.
      var sawRust, sawLibc, sawCrate = false
      for path in runs[0].result.evidence.monitorReads:
        if path.inside(run.tc.rustc.prefix): sawRust = true
        if path.inside(run.tc.gcc.prefix): sawLibc = true
        if path.inside(e.prefix): sawCrate = true
      check sawRust
      check sawLibc
      check sawCrate

      # No run names a read outside every logical root.
      for r in runs:
        check OutsideRoots notin r.result.portableReason
        for line in r.trace:
          check OutsideRoots notin line
          check not line.startsWith(NotPortableEvent & " ")

      # The engine's verdict, recorded by the determinism probe and derived
      # again from the local hit.
      check runs[1].result.status == asSucceeded
      check runs[1].result.portable
      check runs[1].verdict.startsWith(PortableEvent & " ")
      check runs[1].result.portableOutputs.len == 2
      check runs[2].result.status == asCacheHit
      check runs[2].result.portable
      check runs[2].result.portableStrongHex ==
        runs[1].result.portableStrongHex

      # And the D4 scan of the rlib and rmeta, for every tracked root.
      for output in [e.rlib, e.rmeta]:
        let f = scanOutputForEmbeddedRoots(output, run.trackedNeedles())
        checkpoint(output & ": found=" & $f.found & " " & f.label & " " &
          f.path & " " & f.where & " " & f.unscannable)
        check not f.found
        check f.unscannable.len == 0

teardown(run)

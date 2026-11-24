## A registry crate compiled from its store prefix by the relocated
## store-root Rust toolchain yields an rlib and an rmeta that pass the
## cache's embedded-path scan, so its record stays portable; without the
## remap they do not.
##
## One fixture crate (`rqscan`, a plain library whose code can panic, so its
## outputs carry source locations) is fetched into a crate store under the
## store root (`store_root_rust.nim`). Under cargo's dev profile (debuginfo
## on) and its release profile, two edges compile it with the store-root
## `rustc` through the real engine and monitor:
##
## * the registry crate edge (`registryCrateEdge`), whose argv ends with
##   `--remap-path-prefix=<prefix>=rqscan-0.1.0`;
## * a control: the same edge with cargo's argv alone (`cargoArgv`, no
##   remap), in its own output directory.
##
## What is checked, per profile:
##
## * The remapped edge's declared outputs are the rlib and the rmeta, and the
##   dep-info file is not among them (it is the edge's depfile, which the
##   remap does not rewrite and the cache never stores or scans).
## * The cache's embedded-path scan (`scanOutputForEmbeddedRoots`: raw
##   bytes, decompressed ELF sections and every `ar` member), with the
##   physical path of every tracked logical root of the invocation as its
##   needles (project, work, store and out: the needles the cache's own D4
##   check `embeddedRootReason` uses), finds nothing in the rlib or the rmeta
##   and has nothing it cannot scan.
## * The engine's own verdict: the record the determinism probe (the second
##   run; rustc reads unseeded entropy, so the first run's result is
##   withheld) writes is portable.
## * Positive control: in the control's rlib and rmeta the same scan finds
##   the store root, and the engine's verdict on the control's record is
##   non-portable with the D4 reason, naming the store root. So the scan can
##   see the embedding the remap removes, with this toolchain.
##
## Falsifying mutation (run by hand, not in this file): dropping the remap
## from the registry crate edge leaves the store root's path in its rlib and
## rmeta, and its record is non-portable.
##
## No mocks: the catalog's toolchain and the engine's realizer, the
## production fetch, store and edge, the real engine and monitor, a real
## HTTPS server on loopback. Linux x86_64 only, where the catalog relocates
## the Rust toolchain; elsewhere the case is skipped with the reason.

import std/[strutils, tables, unittest]

import repro_test_support/reasoned_skip

import ./store_root_rust

const EmbedsStore = "embeds the physical path of the store root"
  ## The D4 reason (`EmbeddedRootFinding.describe`) for the store root.

let run = newCrateRun("cg4a-d4", @[
  FixturePackage(name: "rqscan", version: "0.1.0",
    files: @[("src/lib.rs",
      "pub fn pick(xs: &[u32], i: usize) -> u32 {\n" &
      "  if i >= xs.len() { panic!(\"index {} out of range\", i) }\n" &
      "  xs[i]\n}\n")])])

suite "store-root registry crate outputs":
  test "the rlib and rmeta pass the D4 scan and the record is portable":
    if not run.ok:
      skip(run.why)
    else:
      let row = run.rows["rqscan"]
      for (profile, args) in [("dev", @DevProfileArgs),
                              ("release", @ReleaseProfileArgs)]:
        checkpoint("profile " & profile)
        let e = registryCrateEdge(row, run.crateStore,
          run.tc.rustc.executable, run.outRoot(profile), args)
        let c = registryCrateEdge(row, run.crateStore,
          run.tc.rustc.executable, run.outRoot("control-" & profile), args)
        let control = rebuiltWithArgv(c.action, c.cargoArgv,
          c.action.id & "-no-remap")
        check e.prefix.inside(run.tc.storeRoot)
        check e.action.argv[0] == run.tc.rustc.executable
        check e.action.outputs == @[e.rmeta, e.rlib]
        check e.depInfo notin e.action.outputs
        # One check, so an edge without the remap fails it and the case goes
        # on to the D4 scan below instead of stopping on an empty sequence.
        check e.argvDifference.len == 1 and
          e.argvDifference[0].startsWith("--remap-path-prefix=" & e.prefix &
            "=")
        check not control.argv[^1].startsWith("--remap-path-prefix")

        var runs: seq[Table[string, EdgeRun]]
        for i in 1 .. 2:
          let r = run.runOnce([e.action, control])
          for id in [e.action.id, control.id]:
            let res = r[id].result
            checkpoint(profile & " run " & $i & " " & id & ": " &
              $res.status & " " & res.reason & "; portable " &
              $res.portable & " (" & res.portableReason & ")" &
              (if res.stderr.len > 0: "\nstderr: " & res.stderr else: "") &
              "\ntrace:\n  " & r[id].trace.join("\n  "))
            require res.status == asSucceeded
          runs.add r
        let mine = runs[1][e.action.id]
        let theirs = runs[1][control.id]
        echo "    " & profile & " remapped verdict: " & mine.verdict
        echo "    " & profile & " control verdict: " & theirs.verdict

        # The remapped outputs: path-free for every tracked root.
        for output in [e.rlib, e.rmeta]:
          let f = scanOutputForEmbeddedRoots(output, run.trackedNeedles())
          checkpoint(output & ": found=" & $f.found & " " & f.label & " " &
            f.path & " " & f.where & " " & f.unscannable)
          check not f.found
          check f.unscannable.len == 0
        check mine.result.portable
        check mine.verdict.startsWith(PortableEvent & " ")

        # Positive control: without the remap the store root is embedded,
        # and the engine refuses the record for it.
        for output in [c.rlib, c.rmeta]:
          let f = scanOutputForEmbeddedRoots(output, [EmbeddedRootNeedle(
            label: "store", path: run.tc.storeRoot)])
          checkpoint(output & " (no remap): found=" & $f.found & " " &
            f.path & " " & f.where)
          check f.found
        check not theirs.result.portable
        check EmbedsStore in theirs.result.portableReason
        check theirs.verdict.startsWith(NotPortableEvent & " ")
        check EmbedsStore in theirs.verdict

teardown(run)

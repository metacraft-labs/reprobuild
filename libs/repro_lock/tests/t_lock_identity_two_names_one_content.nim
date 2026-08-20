## NLF-ID-1 — identical content under two names collapses to one lock file.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-ID-1**
## (`Named-Lock-Files-Test-Corpus.md` §3), verifying design §6.2 and §8.
##
## - **Input.** Declare `hostTools` and `targetRuntime`. Bind both to the same
##   lock file. Build a target whose closure includes library `libfoo`.
## - **Expect.** One set of actions. `libfoo` is built **once**.
## - **Catches.** "An implementation that keys on the lock-file *name* — the
##   position the owner considered and rejected (§6.4). Under that
##   implementation `libfoo` builds twice and the case reports double the
##   action count. This is the single most important identity case, because
##   name-keying is the plausible wrong choice rather than an unlikely one."
##
## ## What makes this discriminating rather than tautological
##
## Asserting only that two identical locks hash equally would pass against an
## implementation that hashes nothing at all. So the case is built as a
## matched pair:
##
##   * the SHARING half — two names, one lock content — must collapse to one
##     identity and therefore one action;
##   * the CONTROL half — two names, two genuinely different lock contents —
##     must NOT collapse, and must produce two actions that both run.
##
## Together they pin the mechanism from both sides: an implementation that
## always collapses fails the control, and one that never collapses fails the
## sharing half. Neither can be passed by accident.
##
## "Builds once" is MEASURED, not inferred. The final case runs the real
## engine over a graph carrying one action per distinct governing lock
## identity and counts how many times the shared library's edge actually
## executed, by counting the outputs it wrote.
##
## Test-double policy: NO mocks, doubles, or fakes. Real committed
## `…lock.v2` files on a real filesystem, read by the product's own
## `parseSolvedGraphLock`; identities from the product's `lockIdentityOf`;
## actions from the engine's real `action` / `builtinAction`; execution by the
## real `runBuild`.

import std/[os, sets, strutils, tempfiles, unittest]

import repro_build_engine
import repro_lock

import ./nlf_lock_fixtures

const
  HostTools = "hostTools"
  TargetRuntime = "targetRuntime"

proc sharedLibraryPackages(): seq[(string, string)] =
  @[("libfoo", "1.4.2"), ("nim", "2.2.0"), ("zlib", "1.3.1")]

proc libfooEdge(outputPath: string; identity: LockIdentity): BuildAction =
  ## The shared library's edge, constructed under `identity`.
  ##
  ## §7: "An edge built under two lock files is two actions with two cache
  ## entries." Two actions need two ids, so the id carries the governing
  ## IDENTITY. It carries no NAME: §6.2 keeps the name out of the key, and a
  ## name reaching an id would reach the fingerprint through it — the partial
  ## name-in-key shape NLF-ID-2 exists to catch.
  ##
  ## The id-derivation scheme itself is not what this case tests; the number
  ## of DISTINCT governing identities is. NLF-M7 owns the real scheme.
  builtinAction(bakWriteText, "build/libfoo@" & $identity,
    outputs = [outputPath],
    text = "libfoo\n",
    # Not cacheable, so "did this edge execute" is a direct measurement.
    # A cacheable edge could report up-to-date from a previous case's action
    # cache and write nothing, which would make the count measure the cache
    # rather than the partitioning.
    cacheable = false,
    governingLockIdentity = identity)

suite "NLF-ID-1 two names, one lock content":

  test "two names bound to the same lock file yield ONE identity":
    let tempRoot = createTempDir("repro-nlf-id1-share", "")
    defer: removeDir(tempRoot)

    # One solved graph, written to two paths and bound under two names. This
    # is "bind both to the same lock file" in the only form the model allows:
    # §3 separates name / file / binding, and a file is its content.
    let sol = solutionOf(sharedLibraryPackages(),
      @[("enableTLS", "true"), ("compiler", "clang")])
    let hostPath = tempRoot / "host-tools.lock"
    let targetPath = tempRoot / "aarch64.lock"
    writeCommittedLock(hostPath, sol)
    writeCommittedLock(targetPath, sol)

    # Sanity: the two files really are separate files with identical bytes,
    # so nothing below is passing because one path was silently reused.
    check hostPath != targetPath
    check readFile(hostPath) == readFile(targetPath)

    let hostIdentity = lockIdentityOf(readCommittedLock(hostPath))
    let targetIdentity = lockIdentityOf(readCommittedLock(targetPath))

    check hostIdentity.isValid()
    check hostIdentity == targetIdentity

    # And the names are absent from the key. A name-keyed implementation
    # would have to smuggle the name in somewhere; assert it is not in the
    # identity's own bytes.
    check not ($hostIdentity).contains(HostTools)
    check not ($targetIdentity).contains(TargetRuntime)

  test "the CONTROL: two genuinely different locks do NOT collapse":
    # Without this, the case above passes against `lockIdentityOf` returning a
    # constant.
    let tempRoot = createTempDir("repro-nlf-id1-control", "")
    defer: removeDir(tempRoot)

    let a = tempRoot / "a.lock"
    let b = tempRoot / "b.lock"
    writeCommittedLock(a, solutionOf(sharedLibraryPackages()))
    writeCommittedLock(b, solutionOf(@[("libfoo", "2.0.0"), ("nim", "2.2.0"),
      ("zlib", "1.3.1")]))

    check lockIdentityOf(readCommittedLock(a)) !=
      lockIdentityOf(readCommittedLock(b))

  test "the shared library builds ONCE, and the control builds twice":
    # The measured half. One action per DISTINCT governing lock identity is
    # the partitioning §7 specifies ("An edge built under two lock files is
    # two actions with two cache entries"); the count of distinct identities
    # is therefore the count of times the edge is built.
    let tempRoot = createTempDir("repro-nlf-id1-build", "")
    defer: removeDir(tempRoot)
    let sameA = tempRoot / "same-a.lock"
    let sameB = tempRoot / "same-b.lock"
    let sol = solutionOf(sharedLibraryPackages(), @[("enableTLS", "true")])
    writeCommittedLock(sameA, sol)
    writeCommittedLock(sameB, sol)

    let differing = tempRoot / "differing.lock"
    writeCommittedLock(differing,
      solutionOf(sharedLibraryPackages(), @[("enableTLS", "false")]))

    proc buildUnder(bindings: openArray[(string, string)];
                    outDir: string): int =
      ## Emit the `libfoo` edge once per DISTINCT governing lock identity
      ## across `bindings` (name -> lock path), run the real engine, and
      ## return the number of times the edge actually executed — counted from
      ## the outputs on disk, not from the engine's own bookkeeping.
      createDir(outDir)
      # A cache root per invocation, so the second call cannot inherit the
      # first call's action-cache state.
      let cacheRoot = outDir & "-cache"
      createDir(cacheRoot)
      var seen = initHashSet[string]()
      var actions: seq[BuildAction] = @[]
      for (name, path) in bindings:
        let identity = lockIdentityOf(readCommittedLock(path))
        if seen.containsOrIncl($identity):
          continue
        # The output path is derived from the IDENTITY, never from `name`:
        # two names on one lock write one file, which is the sharing.
        let outPath = absolutePath(outDir / ($identity).replace(":", "_"))
        actions.add(libfooEdge(outPath, identity))
      var cfg = defaultBuildEngineConfig(cacheRoot)
      cfg.maxParallelism = 1
      cfg.bypassRunQuota = true
      cfg.deferLocalOutputBlobs = false
      discard runBuild(graph(actions), cfg)
      result = 0
      for _ in walkFiles(outDir / "*"):
        inc result

    # The two locks genuinely differ — same versions, one variant flipped —
    # so the control below is measuring divergence and not a typo.
    check lockIdentityOf(readCommittedLock(sameA)) !=
      lockIdentityOf(readCommittedLock(differing))

    # Two names, one lock file -> ONE build of the shared library.
    check buildUnder(@[(HostTools, sameA), (TargetRuntime, sameB)],
      tempRoot / "out-shared") == 1

    # Two names, two lock files that genuinely differ -> TWO builds. Under a
    # name-keyed implementation the first count would also have been 2, and
    # under an implementation that collapses everything this one would be 1.
    check buildUnder(@[(HostTools, sameA), (TargetRuntime, differing)],
      tempRoot / "out-diverged") == 2

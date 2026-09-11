## Producers are content-addressed build edges: the graph a
## ``Distribution`` lowers to is a pure function of that value.
##
## M0's gate: "Producers are content-addressed build edges (rebuild is
## cache-hit-identical)."
##
## The cache-hit half of that is an END-TO-END property and is verified
## by an actual second ``repro build`` — a unit suite cannot observe a
## cache decision. What a unit suite CAN observe, and what these cases
## check, is its precondition: the same ``Distribution`` must lower to
## the same action ids, the same argv and the same output paths, every
## time, on every host. If it did not, a rebuild would miss for reasons
## that have nothing to do with the inputs changing, and the cache
## decision downstream would be meaningless.
##
## The failure modes this is written against are specific, and all
## three are easy to introduce without noticing:
##
## * an action id derived from a counter or a hash of a pointer, so two
##   evaluations of the same recipe disagree;
## * an input set that depends on iteration order of a hash table;
## * a path built with the HOST's separator, so a Windows builder and a
##   Linux builder produce different fingerprints for the same tree.

import std/[algorithm, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/packaging
import ./packaging_test_support

proc graphSignature(): seq[string] =
  ## A stable, order-independent rendering of the whole recorded graph.
  ##
  ## Sorted, because the ORDER edges are recorded in is not part of the
  ## contract and comparing it would make this case fail for a reason
  ## that does not matter. Everything else — ids, argv, inputs, outputs
  ## — is part of the contract, and is compared.
  for act in registeredBuildActions():
    var inputs = act.inputs
    inputs.sort()
    var outputs = act.outputs
    outputs.sort()
    var refs = act.toolIdentityRefs
    refs.sort()
    result.add(act.id & "\x1f" & argvOf(act).join(" ") & "\x1f" &
      inputs.join(",") & "\x1f" & outputs.join(",") & "\x1f" &
      refs.join(","))
  result.sort()

proc signatureFor(dist: Distribution;
                  produce: proc (d: Distribution): PackagedArtifact):
    seq[string] =
  resetBuildActionRegistry()
  discard produce(dist)
  graphSignature()

suite "packaging: the lowered graph is a pure function of the Distribution":

  test "the deb producer lowers identically on two evaluations":
    let dist = sampleDistribution(toLinux)
    let a = signatureFor(dist, proc (d: Distribution): PackagedArtifact =
      debPackage(d))
    let b = signatureFor(dist, proc (d: Distribution): PackagedArtifact =
      debPackage(d))
    check a.len > 0
    check a == b

  test "the MSI producer lowers identically on two evaluations":
    let dist = sampleDistribution(toWindows)
    let a = signatureFor(dist, proc (d: Distribution): PackagedArtifact =
      msiPackage(d))
    let b = signatureFor(dist, proc (d: Distribution): PackagedArtifact =
      msiPackage(d))
    check a.len > 0
    check a == b

  test "the tarball producer lowers identically on two evaluations":
    let dist = sampleDistribution(toLinux)
    let a = signatureFor(dist, proc (d: Distribution): PackagedArtifact =
      tarballPackage(d))
    let b = signatureFor(dist, proc (d: Distribution): PackagedArtifact =
      tarballPackage(d))
    check a.len > 0
    check a == b

  test "changing ONE component changes the graph":
    # The other half of the property, and the one a broken
    # implementation still passes the cases above with: a signature that
    # is stable because it ignores the inputs is not content-addressing,
    # it is a constant.
    let base = signatureFor(sampleDistribution(toLinux),
      proc (d: Distribution): PackagedArtifact = debPackage(d))
    var changed = sampleDistribution(toLinux)
    changed.components[1] = executableComponent("build/bin/subtractor")
    let after = signatureFor(changed,
      proc (d: Distribution): PackagedArtifact = debPackage(d))
    check base != after

  test "changing an env default changes the graph":
    # The §5 wrapper text is an input to the tree, so a changed default
    # must reach the artifact. If it did not, a release that fixed a
    # wrong default would ship the old one from cache.
    let base = signatureFor(sampleDistribution(toLinux),
      proc (d: Distribution): PackagedArtifact = debPackage(d))
    var changed = sampleDistribution(toLinux)
    changed.runtime.envDefaults[1] = ("SAMPLETOOL_MODE", "development")
    let after = signatureFor(changed,
      proc (d: Distribution): PackagedArtifact = debPackage(d))
    check base != after

  test "changing the version changes the artifact path and the graph":
    let base = signatureFor(sampleDistribution(toLinux),
      proc (d: Distribution): PackagedArtifact = debPackage(d))
    var changed = sampleDistribution(toLinux)
    changed.version = "0.3.0"
    let after = signatureFor(changed,
      proc (d: Distribution): PackagedArtifact = debPackage(d))
    check base != after

  test "no path in the lowered graph carries a host separator":
    # A backslash in a declared path would make the fingerprint differ
    # between a Windows builder and a Linux builder for the same tree,
    # so a cache entry published by one could never be reused by the
    # other — and the failure would look like a mysterious permanent
    # miss rather than like a path bug.
    resetBuildActionRegistry()
    discard debPackage(sampleDistribution(toLinux))
    for act in registeredBuildActions():
      for path in act.outputs:
        check not path.contains('\\')
      for path in act.inputs:
        check not path.contains('\\')

  test "every action id is unique within one lowering":
    # Two edges sharing an id is not a cosmetic problem: the engine
    # keys the action cache by id, so a collision silently serves one
    # edge's outputs for the other.
    resetBuildActionRegistry()
    discard debPackage(sampleDistribution(toLinux))
    discard tarballPackage(sampleDistribution(toLinux))
    var ids: seq[string] = @[]
    for act in registeredBuildActions():
      check act.id notin ids
      ids.add(act.id)

  test "TWO distributions in one recipe do not collide on ids either":
    # The variant alone was enough while a recipe staged one
    # distribution, and stopped being enough the moment one staged two.
    # Reprobuild's own packaging is exactly that case -- section 3 splits
    # the product into ``reprobuild`` and ``reprobuild-binary-cache``,
    # both built from one recipe, both staging a ``deb`` tree -- and the
    # first real build of it was refused outright with
    # ``duplicate graph node id: project:action:pkg-deb-runtime-closure``.
    # The refusal was the engine doing the right thing; what a producer
    # must not do is make it possible.
    resetBuildActionRegistry()
    var first = sampleDistribution(toLinux)
    var second = sampleDistribution(toLinux, withService = false)
    second.name = "sampletool-extra"
    second.stagingRoot = "build/dist/sampletool-extra-0.2.0"
    discard debPackage(first)
    discard debPackage(second)
    var ids: seq[string] = @[]
    for act in registeredBuildActions():
      check act.id notin ids
      ids.add(act.id)
    var outputs: seq[string] = @[]
    for act in registeredBuildActions():
      for output in act.outputs:
        check output notin outputs
        outputs.add(output)

  test "the staged id prefix names both the variant and the distribution":
    let dist = sampleDistribution(toLinux)
    check stagedIdPrefix(dist, "deb") == "pkg-deb-sampletool-"
    check stagedIdPrefix(dist, "tar") == "pkg-tar-sampletool-"
    var other = sampleDistribution(toLinux)
    other.name = "other"
    check stagedIdPrefix(other, "deb") != stagedIdPrefix(dist, "deb")

  test "two producers over one Distribution do not collide on outputs":
    # The deb tree and the tarball tree are separate on purpose (the deb
    # needs a DEBIAN/ directory the tarball must not carry). If the
    # variant did not reach the staging paths, the two producers would
    # write to the same files and the second would win.
    resetBuildActionRegistry()
    let deb = debPackage(sampleDistribution(toLinux))
    let tar = tarballPackage(sampleDistribution(toLinux))
    check deb.tree.root != tar.tree.root
    var seen: seq[string] = @[]
    for act in registeredBuildActions():
      for output in act.outputs:
        check output notin seen
        seen.add(output)

## The real tracked flake graph must not bring a second Reprobuild release
## through its bootstrap module input. A consumer already supplies the one
## intended Reprobuild revision; a nested release breaks the rollout's pin gate.
## Likewise the graph must hold exactly one codetracer-trace-format-nim node,
## the one the root input ``ct-trace-format-src`` names, so no nested input can
## smuggle in a second, differently pinned trace-format source.
## MOCKS: none. This reads the repository's actual committed lock format.
import std/[json, os, unittest]

suite "flake bootstrap pin closure":
  test "bootstrap dependencies do not pin another reprobuild release":
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let graph = parseFile(root / "flake.lock")
    var competing: seq[string] = @[]
    for name, node in graph["nodes"]:
      if node.hasKey("locked"):
        let locked = node["locked"]
        if locked.hasKey("repo") and locked["repo"].getStr() == "reprobuild":
          competing.add(name)
    checkpoint "competing Reprobuild inputs: " & $competing
    check competing.len == 0

  test "trace format retains exactly one matching immutable source":
    # The expected revision is read from the lock graph itself -- the node the
    # root input ``ct-trace-format-src`` resolves to -- rather than written
    # here as a literal. A literal drifted every time the pin moved with
    # ``codetracer-src``; whether that move went to the RIGHT revision is the
    # ``ct-trace-format-pin-coherence`` flake check's question. This test
    # asks only that no second, differently pinned trace-format node exists.
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let graph = parseFile(root / "flake.lock")
    let nodes = graph["nodes"]
    let rootInputs = nodes[graph["root"].getStr()]["inputs"]
    require rootInputs.hasKey("ct-trace-format-src")
    # A root input that ``follows`` another is a JSON array, not a node name;
    # the trace-format input must be a direct, locked node of its own.
    require rootInputs["ct-trace-format-src"].kind == JString
    let rootNode = nodes[rootInputs["ct-trace-format-src"].getStr()]
    require rootNode.hasKey("locked")
    let rootLocked = rootNode["locked"]
    check rootLocked["repo"].getStr() == "codetracer-trace-format-nim"
    let pinned = rootLocked["rev"].getStr()
    check pinned.len == 40
    var revisions: seq[string] = @[]
    for name, node in nodes:
      if node.hasKey("locked"):
        let locked = node["locked"]
        if locked.hasKey("repo") and
            locked["repo"].getStr() == "codetracer-trace-format-nim":
          revisions.add(locked["rev"].getStr())
    check revisions == @[pinned]

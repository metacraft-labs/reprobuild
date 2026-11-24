## The real tracked flake graph must not bring a second Reprobuild release
## through its bootstrap module input. A consumer already supplies the one
## intended Reprobuild revision; a nested release breaks the rollout's pin gate.
## Likewise the graph must hold no codetracer-trace-format-nim or codetracer
## node at all: both are read from the CodeTracer pin, so no input can smuggle
## in a second, differently pinned source.
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

  test "trace format and CodeTracer are read from the pin, never locked":
    # Both are derived at evaluation time (nix/codetracer-pin.nix): CodeTracer
    # from pins/codetracer.json in metacraft-github-actions, the trace-format
    # source from that CodeTracer revision's repro.lock. A lock node for
    # either would be a second, independently moved pin -- the drift the
    # derivation exists to rule out (``ct-trace-format-pin-coherence``).
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let graph = parseFile(root / "flake.lock")
    let nodes = graph["nodes"]
    let rootInputs = nodes[graph["root"].getStr()]["inputs"]
    # Positive control: the pin set is locked, and the override slot
    # ``codetracer-src`` follows it (a JSON array, not a node of its own).
    require rootInputs.hasKey("metacraft-github-actions")
    require rootInputs["metacraft-github-actions"].kind == JString
    let pinSet = nodes[rootInputs["metacraft-github-actions"].getStr()]
    require pinSet.hasKey("locked")
    check pinSet["locked"]["repo"].getStr() == "metacraft-github-actions"
    require rootInputs.hasKey("codetracer-src")
    check rootInputs["codetracer-src"].kind == JArray
    check not rootInputs.hasKey("ct-trace-format-src")
    var locked: seq[string] = @[]
    for name, node in nodes:
      if node.hasKey("locked"):
        let repo = node["locked"].getOrDefault("repo")
        if repo != nil and repo.getStr() in ["codetracer-trace-format-nim", "codetracer"]:
          locked.add(name)
    checkpoint "CodeTracer-family lock nodes: " & $locked
    check locked.len == 0

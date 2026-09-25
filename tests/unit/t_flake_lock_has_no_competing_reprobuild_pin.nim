## The real tracked flake graph must not bring a second Reprobuild release
## through its bootstrap module input. A consumer already supplies the one
## intended Reprobuild revision; a nested release breaks the rollout's pin gate.
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
    let root = currentSourcePath().parentDir.parentDir.parentDir
    let graph = parseFile(root / "flake.lock")
    var revisions: seq[string] = @[]
    for name, node in graph["nodes"]:
      if node.hasKey("locked"):
        let locked = node["locked"]
        if locked.hasKey("repo") and
            locked["repo"].getStr() == "codetracer-trace-format-nim":
          revisions.add(locked["rev"].getStr())
    check revisions == @["bc7c5d256d0a4b1246f9a9bbb51a83071d3d8e26"]

## De-inheriting a git-vendored crate's Cargo.toml.
##
## A crates.io crate arrives with its `workspace = true` fields already
## inlined by `cargo publish`; a git crate that is a workspace member does
## not, and cargo cannot resolve those fields once the crate is vendored
## standalone. These cases pin the inlining that closes that gap — the same
## rewrite `cargo vendor` performs, checked against the exact spellings
## cargo writes (dotted `version.workspace`, inline `dep = { workspace =
## true }`, and the feature-merge case), including one taken verbatim from a
## real dependency of the codex agent.

import std/[strutils, tables, unittest]

import repro_core/cargo_deinherit

proc ws(): WorkspaceInheritance =
  result.package = {
    "version": "\"0.8.0\"",
    "edition": "\"2021\"",
    "license": "\"MIT\"",
  }.toTable
  result.dependencies = {
    "getrandom": "\"0.2\"",
    "serde": "{ version = \"1\", features = [\"derive\"] }",
    "thiserror": "\"1\"",
  }.toTable
  result.lints = @["rust.unsafe_code = \"forbid\""]

suite "de-inheriting a git-vendored crate manifest":

  test "the cheap inheritance test spots both spellings and the negative":
    check usesWorkspaceInheritance("version.workspace = true\n")
    check usesWorkspaceInheritance("serde = { workspace = true }\n")
    check usesWorkspaceInheritance(
      "serde = { workspace = true, features = [\"x\"] }\n")
    check not usesWorkspaceInheritance(
      "[package]\nname = \"x\"\nversion = \"1\"\n")

  test "dotted package fields are inlined from [workspace.package]":
    let crate = "[package]\nname = \"appcontainer_common\"\n" &
      "version.workspace = true\nedition.workspace = true\n" &
      "license.workspace = true\n"
    let res = deinheritCargoToml(crate, ws())
    check "version = \"0.8.0\"" in res
    check "edition = \"2021\"" in res
    check "license = \"MIT\"" in res
    check "workspace = true" notin res
    # The name line is untouched — only inheriting lines change.
    check "name = \"appcontainer_common\"" in res

  test "an inline `{ workspace = true }` dependency takes the workspace value":
    let crate = "[dependencies]\ngetrandom = { workspace = true }\n" &
      "thiserror = { workspace = true }\n"
    let res = deinheritCargoToml(crate, ws())
    check "getrandom = \"0.2\"" in res
    check "thiserror = \"1\"" in res
    check "workspace = true" notin res

  test "a dotted `dep.workspace = true` also resolves":
    let res = deinheritCargoToml("[dependencies]\ngetrandom.workspace = true\n",
      ws())
    check "getrandom = \"0.2\"" in res

  test "local features union onto the workspace dependency's":
    # `{ workspace = true, features = [...] }` keeps the workspace version and
    # adds the local features onto whatever the workspace declared.
    let res = deinheritCargoToml(
      "[dependencies]\nserde = { workspace = true, features = [\"rc\"] }\n",
      ws())
    check "version = \"1\"" in res
    check "\"derive\"" in res
    check "\"rc\"" in res
    check "workspace = true" notin res

  test "local optional is carried onto a bare-version workspace dependency":
    let res = deinheritCargoToml(
      "[dependencies]\ngetrandom = { workspace = true, optional = true }\n",
      ws())
    check "version = \"0.2\"" in res
    check "optional = true" in res

  test "[lints] workspace = true is replaced by the workspace lints body":
    let res = deinheritCargoToml("[lints]\nworkspace = true\n", ws())
    check "workspace = true" notin res
    check "unsafe_code" in res

  test "a non-inheriting crate passes through byte for byte":
    let crate = "[package]\nname = \"x\"\nversion = \"1.2.3\"\n\n" &
      "[dependencies]\nserde = \"1\"\n"
    check deinheritCargoToml(crate, ws()) == crate

  test "inheriting a field the workspace root lacks is refused, not dropped":
    expect CargoDeinheritError:
      discard deinheritCargoToml(
        "[dependencies]\nnope = { workspace = true }\n", ws())
    expect CargoDeinheritError:
      discard deinheritCargoToml(
        "[package]\nrust-version.workspace = true\n", ws())

  test "a dependency name that is not inheriting is left alone":
    # A `workspace = true` inside a table is the trigger; a normal dep in the
    # same table must not be touched even when it shares a workspace name.
    let res = deinheritCargoToml(
      "[dependencies]\nserde = \"1.0.200\"\ngetrandom = { workspace = true }\n",
      ws())
    check "serde = \"1.0.200\"" in res
    check "getrandom = \"0.2\"" in res

  test "a multi-line workspace dependency value is captured whole":
    # cargo writes a long `features = [ … ]` across many lines in the
    # workspace root. A reader that stopped at the first line would inline a
    # truncated `{ version = "0.62", features = [` — malformed TOML that
    # fails the build, which is exactly what a real microsoft/mxc crate hit.
    let root = "[workspace.dependencies]\n" &
      "windows = { version = \"0.62\", features = [\n" &
      "    \"Win32_Foundation\",\n" &
      "    \"Win32_Security\",\n" &
      "] }\n"
    let w = parseWorkspaceInheritance(root)
    check "Win32_Foundation" in w.dependencies["windows"]
    check "Win32_Security" in w.dependencies["windows"]
    # The captured value has balanced brackets — a truncated one would not.
    var depth = 0
    for ch in w.dependencies["windows"]:
      if ch == '[' or ch == '{': inc depth
      elif ch == ']' or ch == '}': dec depth
    check depth == 0
    # And it inlines into a crate as one valid line.
    let res = deinheritCargoToml(
      "[dependencies]\nwindows = { workspace = true }\n", w)
    check "Win32_Foundation" in res
    check "workspace = true" notin res

  test "reading the three tables out of a workspace root":
    let root = "[workspace]\nmembers = [\"a\"]\n\n" &
      "[workspace.package]\nversion = \"9.9\"\nedition = \"2024\"\n\n" &
      "[workspace.dependencies]\nfoo = \"3\"\nbar = { version = \"2\" }\n\n" &
      "[workspace.lints.clippy]\nall = \"warn\"\n"
    let w = parseWorkspaceInheritance(root)
    check w.package["version"] == "\"9.9\""
    check w.package["edition"] == "\"2024\""
    check w.dependencies["foo"] == "\"3\""
    check w.dependencies["bar"] == "{ version = \"2\" }"

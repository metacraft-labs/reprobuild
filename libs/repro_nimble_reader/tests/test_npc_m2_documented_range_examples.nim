## NPC-M2 `test_npc_m2_documented_range_examples`: the seven `^=` / `~=`
## examples Nimble documents (nimble-guide `create-packages.md`, "Here are
## some examples of the `^=` and `~=` operators") normalize exactly into the
## solver's constraint language, and the solver's own range parser reads each
## translation back to the same bounds.
##
## The `~=` and `^=` rules differ only in which component they bump, so a
## reader that treats `~=` like `^=` gets `nim ~= 1.2.2` wrong (`< 2.0.0`
## instead of `< 1.3.0`); the per-example check names the case that fails.

import std/[options, unittest]

import repro_solver/version_constraints
import repro_nimble_reader

const Documented = [
  # (requirement, package, normalized)
  ("nim ^= 1.2.2", "nim", ">= 1.2.2, < 2.0.0"),
  ("nim ~= 1.2.2", "nim", ">= 1.2.2, < 1.3.0"),
  ("jester ^= 0.4.1", "jester", ">= 0.4.1, < 0.5.0"),
  ("jester ~= 0.4.1", "jester", ">= 0.4.1, < 0.5.0"),
  ("jester ~= 0.4", "jester", ">= 0.4.0, < 1.0.0"),
  ("choosenim ~= 0", "choosenim", ">= 0.0.0, < 1.0.0"),
  ("choosenim ^= 0", "choosenim", ">= 0.0.0, < 1.0.0")]

suite "npc-m2 documented range examples":
  test "test_npc_m2_documented_range_examples":
    for (written, package, normalized) in Documented:
      let reading = readRequirements(written)
      checkpoint written
      check reading.errors.len == 0
      require reading.requirements.len == 1
      let r = reading.requirements[0]
      check r.target.kind == tkPackage
      check r.target.name == package
      require r.version.kind == vkRange
      check r.version.normalized == normalized
      # The solver reads the translation back as the same half-open range.
      check r.version.range == parseSemverRange(normalized)

  test "the tilde example bounds admit and refuse the right versions":
    let r = readRequirement("nim ~= 1.2.2").get
    check satisfies(semver(1, 2, 2), r.version.range)
    check satisfies(semver(1, 2, 99), r.version.range)
    check not satisfies(semver(1, 3, 0), r.version.range)
    check not satisfies(semver(1, 2, 1), r.version.range)

  test "the caret example bounds admit and refuse the right versions":
    let r = readRequirement("nim ^= 1.2.2").get
    check satisfies(semver(1, 9, 0), r.version.range)
    check not satisfies(semver(2, 0, 0), r.version.range)

  test "the same requirements read through a .nimble file":
    var src = ""
    for (written, _, _) in Documented:
      src.add "requires \"" & written & "\"\n"
    let f = readNimbleSource(src, "examples.nimble")
    check f.readerClass == rcPlain
    # `nim` constrains the toolchain and is kept apart from package entries.
    check f.nim.len == 2
    check f.requires.len == 5
    check f.nim[1].requirement.version.normalized == ">= 1.2.2, < 1.3.0"

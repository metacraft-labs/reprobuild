## `nimble-sources.toml` is read as a closed TOML subset: every refusal
## names its line, every cause is reported, and the identity is a function
## of the content, not of its spelling.

import std/[strutils, unittest]

import repro_nimble_generator

const Commit = "0123456789abcdef0123456789abcdef01234567"

proc refusal(text: string): string =
  try:
    discard parseSourceSet(text, "nimble-sources.toml")
    ""
  except SourceSetError as e:
    e.msg

suite "nimble-sources.toml":

  test "the spec's example reads, with every policy field":
    let s = parseSourceSet("""
schema = "reprobuild.nimble-source-set.v1"

[[registry]]
remote = "https://github.com/nim-lang/packages"
commit = "$1"          # packages.json is read at this commit

[[root]]                     # optional; without any, the whole registry
package = "chronicles"

[[extra]]                    # a source the registry does not list
name = "quicktest"
origin = "https://github.com/alehander92/nim-quicktest?subdir=src/qt"

[[override]]                 # see NPC-AREQ16 and §11.4
package = "chronicles"
origin = "https://github.com/metacraft-labs/nim-chronicles"
commit = "$1"

[[override]]
package = "jester"
tag = "v0.4.0"
requires = ["httpbeast >= 0.2.0", "nim >= 1.0",]

[policy]
unlisted = "refuse"          # or "allow"
probe = "off"                # or "sandboxed"
cooldown_days = 7
track_head = ["jester", "asynctools"]
""" % [Commit], "nimble-sources.toml")
    check s.registries.len == 1
    check s.registries[0].commit == Commit
    check s.roots == @["chronicles"]
    check s.extras[0].origin == "https://github.com/alehander92/nim-quicktest"
    check s.extras[0].subdir == "src/qt"
    check s.overrides.len == 2
    check s.overrides[1].requires == @["httpbeast >= 0.2.0", "nim >= 1.0"]
    check s.policy.cooldownDays == 7
    check s.policy.trackHead == @["asynctools", "jester"]
    check s.policy.unlisted == upRefuse
    check s.policy.probe == ppOff

  test "defaults: refuse unlisted, probe off, no cooldown":
    let s = parseSourceSet("schema = \"reprobuild.nimble-source-set.v1\"\n" &
      "[[registry]]\nremote = \"https://x.invalid/p\"\ncommit = \"" & Commit &
      "\"\n", "f")
    check s.policy.unlisted == upRefuse
    check s.policy.probe == ppOff
    check s.policy.cooldownDays == 0
    check s.policy.trackHead.len == 0

  test "unknown keys, tables, types and duplicates are refused, each naming its line":
    let msg = refusal("""schema = "reprobuild.nimble-source-set.v1"
[[registry]]
remote = "https://x.invalid/p"
ref = "master"
[[root]]
package = "a"
packages = "b"
[policy]
cooldown_days = "7"
probe = "on"
probe = "off"
enabled = true
[mirrors]
url = "x"
[policy]
""")
    check "nimble-sources.toml:4: unknown key \"ref\" in [[registry]]" in msg
    check "accepted only by the command that updates the pin" in msg
    check "[[registry]] is missing `commit`" in msg
    check "nimble-sources.toml:7: unknown key \"packages\" in [[root]]" in msg
    check "nimble-sources.toml:9: `cooldown_days` must be a non-negative integer" in msg
    check "nimble-sources.toml:10: `probe` must be \"off\" or \"sandboxed\"" in msg
    check "nimble-sources.toml:11: duplicate key \"probe\" in [policy]" in msg
    check "nimble-sources.toml:12: the value of \"enabled\" must be a basic" in msg
    check "nimble-sources.toml:13: unsupported table header \"[mirrors]\"" in msg
    check "nimble-sources.toml:15: duplicate table [policy]" in msg

  test "an abbreviated registry commit, a multi-line array and a missing schema are refused":
    check "is not a full-width commit id" in refusal(
      "schema = \"reprobuild.nimble-source-set.v1\"\n[[registry]]\n" &
      "remote = \"https://x.invalid/p\"\ncommit = \"0123456\"\n")
    check "does not close on its line" in refusal(
      "schema = \"reprobuild.nimble-source-set.v1\"\n[[extra]]\nname = \"a\"\n" &
      "origin = \"https://x.invalid/a\"\n[policy]\ntrack_head = [\"a\",\n\"b\"]\n")
    check "missing `schema" in refusal("[[extra]]\nname = \"a\"\n" &
      "origin = \"https://x.invalid/a\"\n")
    check "names no source" in refusal(
      "schema = \"reprobuild.nimble-source-set.v1\"\n")

  test "the identity ignores order, comments and spacing, not content":
    let a = parseSourceSet("schema = \"reprobuild.nimble-source-set.v1\"\n" &
      "[[extra]]\nname = \"a\"\norigin = \"https://x.invalid/a\"\n" &
      "[[extra]]\nname = \"b\"\norigin = \"https://x.invalid/b\"\n" &
      "[policy]\ntrack_head = [\"b\", \"a\"]\n", "a")
    let b = parseSourceSet("# reordered\nschema = \"reprobuild.nimble-source-set.v1\"\n" &
      "[policy]\n  track_head = [ \"a\" , \"b\" ]\n" &
      "[[extra]]\norigin = \"https://x.invalid/b\"\nname = \"b\"\n\n" &
      "[[extra]]\nname = \"a\"   # first\norigin = \"https://x.invalid/a\"\n", "b")
    check sourceSetIdentity(a) == sourceSetIdentity(b)
    let c = parseSourceSet("schema = \"reprobuild.nimble-source-set.v1\"\n" &
      "[[extra]]\nname = \"a\"\norigin = \"https://x.invalid/a\"\n" &
      "[[extra]]\nname = \"b\"\norigin = \"https://x.invalid/b\"\n" &
      "[policy]\ntrack_head = [\"b\", \"a\"]\ncooldown_days = 1\n", "c")
    check sourceSetIdentity(a) != sourceSetIdentity(c)

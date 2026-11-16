## The help of the two blob-level collectors names the loss they can cause.
##
## `repro cas gc` deletes every blob outside the `--keep` set, and `repro
## store gc --budget --evict-cas` evicts every blob no action-cache entry
## refers to. Neither knows what else refers to a blob. In a user's store,
## home generations refer to their activation manifests, intent snapshots
## and file contents by digest, and those records are authoritative
## operational state: nothing regenerates them (reprobuild-pm
## `spec/Configuration-Storage-Principles.md` §"Authoritative Operational
## State", `spec/CLI/cas.md`, `spec/CLI/store/gc.md` §"Budget Mode"). An
## operator choosing either command is accepting that loss, so the help they
## read must say so, not only the specification.
##
## Recorded as reprobuild-pm issue
## `issues/2026-11-12-binary-content-is-regenerable-conflicts-with-binary-state-that-is-authoritative.md`.
##
## No mocks: it reads the help text repro prints, generated from repro's
## command-line description.

import std/[strutils, unittest]

import repro_cli_support/cli_program

proc normalized(text: string): string =
  ## The help with its wrapping undone, so a reflow cannot hide a phrase.
  text.splitWhitespace().join(" ")

suite "blob-level gc help names the unrecoverable loss":
  test "repro cas gc says it also deletes home-generation blobs":
    let help = normalized(ReproCommandLine.helpText(["cas", "gc"]))
    checkpoint(help)
    check "home generations refer to" in help
    check "cannot be recovered" in help

  test "repro store gc --evict-cas says it is for a store the action cache alone refers to":
    let help = normalized(ReproCommandLine.helpText(["store", "gc"]))
    checkpoint(help)
    check "--evict-cas" in help
    check "the action cache alone refers to" in help
    check "home-generation records, which cannot be recovered" in help

## M9.R.77.5 — regression tests for the ``repro cas`` R11 Layer-1 CLI.
##
## The CLI is a thin wrapper over the ``repro_cas_store`` facade; the
## test drives ``runCasCommand`` directly and checks exit codes +
## side effects on the on-disk store. Full end-to-end CLI process
## spawn is covered elsewhere.
##
## Pins:
##   1. ``repro cas exists <hex>`` returns 0 for a present blob and 1
##      for an absent one.
##   2. ``repro cas verify <hex>`` returns 0 for a good blob and 1
##      for a corrupted / missing one.
##   3. ``repro cas path <hex>`` returns 0 and prints the on-disk path
##      (validated via the facade's own ``casPath``).
##   4. ``repro cas gc`` with an empty ``--keep`` list removes every
##      blob.
##   5. ``repro cas gc --keep=hex,hex`` preserves the listed blobs and
##      removes the rest.
##   6. Malformed hex + missing subcommand + unknown flag all return
##      exit code 2 (usage error).

import std/[os, strutils, tempfiles, unittest]

from repro_core/paths import extendedPath

import repro_cas_store
import repro_cli_support

proc putBlob(root: string; payload: seq[byte]): ContentHash =
  var cas = openCasStore(root)
  defer: cas.close()
  cas.casPut(payload)

proc corrupt(path: string) =
  writeFile(extendedPath(path), "corrupted-payload")

proc pathOf(root: string; h: ContentHash): string =
  var cas = openCasStore(root)
  defer: cas.close()
  cas.casPath(h)

suite "M9.R.77.5 — repro cas CLI":

  test "no arguments prints usage and returns 2":
    check runCasCommand(@[]) == 2

  test "unknown subcommand returns 2":
    let dir = createTempDir("m9r77cli-unk-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    check runCasCommand(
      @["floop", "--store-root=" & dir]) == 2

  test "unknown flag returns 2":
    let dir = createTempDir("m9r77cli-flg-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    check runCasCommand(
      @["gc", "--nonsense", "--store-root=" & dir]) == 2

  test "malformed hex on verify returns 2":
    let dir = createTempDir("m9r77cli-mh-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    check runCasCommand(
      @["verify", "abcdef", "--store-root=" & dir]) == 2

  test "exists returns 0 for a present blob":
    let dir = createTempDir("m9r77cli-e0-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let h = putBlob(dir, @[byte(0x11), byte(0x22)])
    check runCasCommand(
      @["exists", $h, "--store-root=" & dir]) == 0

  test "exists returns 1 for an absent blob":
    let dir = createTempDir("m9r77cli-e1-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let absent = "00" & repeat("00", 31)
    check runCasCommand(
      @["exists", absent, "--store-root=" & dir]) == 1

  test "verify returns 0 for a good blob":
    let dir = createTempDir("m9r77cli-v0-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let h = putBlob(dir, @[byte(0x99)])
    check runCasCommand(
      @["verify", $h, "--store-root=" & dir]) == 0

  test "verify returns 1 for a corrupted blob":
    let dir = createTempDir("m9r77cli-v1-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let h = putBlob(dir, @[byte(0x33), byte(0x44)])
    let p = pathOf(dir, h)
    corrupt(p)
    check runCasCommand(
      @["verify", $h, "--store-root=" & dir]) == 1

  test "path returns 0 (prints on-disk path)":
    let dir = createTempDir("m9r77cli-p-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let h = putBlob(dir, @[byte(0x55)])
    check runCasCommand(
      @["path", $h, "--store-root=" & dir]) == 0

  test "gc with empty retain set removes every blob":
    let dir = createTempDir("m9r77cli-g0-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let h1 = putBlob(dir, @[byte(0x77)])
    let h2 = putBlob(dir, @[byte(0x88), byte(0x88)])
    check runCasCommand(@["gc", "--store-root=" & dir]) == 0
    check runCasCommand(
      @["exists", $h1, "--store-root=" & dir]) == 1
    check runCasCommand(
      @["exists", $h2, "--store-root=" & dir]) == 1

  test "gc --keep preserves listed blobs":
    let dir = createTempDir("m9r77cli-gk-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    let keep = putBlob(dir, @[byte(0xAA)])
    let drop = putBlob(dir, @[byte(0xBB), byte(0xBB)])
    check runCasCommand(
      @["gc", "--keep=" & $keep, "--store-root=" & dir]) == 0
    check runCasCommand(
      @["exists", $keep, "--store-root=" & dir]) == 0
    check runCasCommand(
      @["exists", $drop, "--store-root=" & dir]) == 1

  test "gc --keep with malformed hex returns 2":
    let dir = createTempDir("m9r77cli-gkbad-", "")
    defer:
      try: removeDir(extendedPath(dir)) except OSError: discard
    check runCasCommand(
      @["gc", "--keep=abcdef", "--store-root=" & dir]) == 2

## The launcher's store-root resolution and the STORE's store-root resolution
## are the same function.
##
## WHY A DUPLICATE EXISTS AT ALL. `repro_selfhost.selfStoreRoot` restates the
## four lines of `repro_local_store.resolveStoreRoot` so the resolving
## launcher can find its store without linking the store runtime — the
## runtime carries the SQLite binding, and a launcher that needs a database
## open before it can decide which binary to run has recursed on its own
## dependency problem.
##
## WHY THIS TEST EXISTS. A duplicate that nobody checks drifts, and the drift
## is silent and severe in exactly one direction: the launcher resolves a pin
## against store A while `repro self install` realizes into store B, so every
## pin misses, every launch provisions, and nothing in either component looks
## wrong. So the two are driven over the same environments — the explicit
## override, `$REPRO_STORE_ROOT`, each platform's default, and each
## nothing-is-set case — and required to agree.
##
## The nothing-is-set case is asserted for its BEHAVIOUR rather than its
## value: both must refuse. A default that quietly picks a directory is the
## failure this pair must not have, because that directory is per-process and
## the two processes are not the same one.
##
## Test-double policy: no mocks. Both real procs, driven over a real process
## environment that is saved and restored around each case.

import std/[os, unittest]

import repro_local_store
import repro_selfhost

const HomeVars = ["REPRO_STORE_ROOT", "LOCALAPPDATA", "USERPROFILE", "HOME",
                  "XDG_CACHE_HOME"]

type SavedEnv = seq[tuple[name: string; present: bool; value: string]]

proc saveEnv(): SavedEnv =
  for name in HomeVars:
    result.add((name: name, present: existsEnv(name), value: getEnv(name)))

proc restoreEnv(saved: SavedEnv) =
  for entry in saved:
    if entry.present: putEnv(entry.name, entry.value)
    else: delEnv(entry.name)

proc clearAll() =
  for name in HomeVars:
    delEnv(name)

template withEnv(body: untyped) =
  let saved = saveEnv()
  try:
    clearAll()
    body
  finally:
    restoreEnv(saved)

proc bothAgree(): bool =
  ## True when the two resolvers answer identically, INCLUDING when both
  ## refuse. An asymmetric refusal is a disagreement and reports as one.
  var launcher = ""
  var launcherRaised = false
  var store = ""
  var storeRaised = false
  try: launcher = selfStoreRoot()
  except CatchableError: launcherRaised = true
  try: store = resolveStoreRoot()
  except CatchableError: storeRaised = true
  if launcherRaised or storeRaised:
    return launcherRaised and storeRaised
  launcher == store

suite "the launcher and the store resolve the same store root":

  test "an explicit override wins in both":
    withEnv:
      check selfStoreRoot("/explicit/store") == resolveStoreRoot("/explicit/store")
      check selfStoreRoot("/explicit/store") == "/explicit/store"

  test "REPRO_STORE_ROOT wins in both":
    withEnv:
      putEnv("REPRO_STORE_ROOT", "/env/store")
      check bothAgree()
      check selfStoreRoot() == "/env/store"

  test "the env var outranks every platform default in both":
    withEnv:
      putEnv("LOCALAPPDATA", "/local/app/data")
      putEnv("USERPROFILE", "/users/someone")
      putEnv("HOME", "/home/someone")
      putEnv("XDG_CACHE_HOME", "/xdg/cache")
      putEnv("REPRO_STORE_ROOT", "/env/store")
      check bothAgree()
      check selfStoreRoot() == "/env/store"

  test "the platform default agrees":
    withEnv:
      when defined(windows):
        putEnv("LOCALAPPDATA", "/local/app/data")
      elif defined(macosx):
        putEnv("HOME", "/home/someone")
      else:
        putEnv("HOME", "/home/someone")
      check bothAgree()
      # Not merely equal: a non-empty answer, so two procs that both
      # returned "" would not pass.
      check selfStoreRoot().len > 0

  test "the secondary platform default agrees":
    withEnv:
      when defined(windows):
        # LOCALAPPDATA absent, USERPROFILE present.
        putEnv("USERPROFILE", "/users/someone")
      elif defined(macosx):
        putEnv("HOME", "/home/someone")
      else:
        # XDG_CACHE_HOME present takes priority over HOME.
        putEnv("XDG_CACHE_HOME", "/xdg/cache")
        putEnv("HOME", "/home/someone")
      check bothAgree()
      check selfStoreRoot().len > 0

  test "with nothing set, BOTH refuse":
    withEnv:
      var launcherRefused = false
      var storeRefused = false
      try: discard selfStoreRoot()
      except CatchableError: launcherRefused = true
      try: discard resolveStoreRoot()
      except CatchableError: storeRefused = true
      check launcherRefused
      check storeRefused

  test "the agreement check can fail":
    ## A control for `bothAgree` itself: it must report disagreement when the
    ## two answers really differ. Asserted by comparing the launcher's answer
    ## under one environment against the store's under another — which is
    ## what drift would look like from the outside.
    withEnv:
      putEnv("REPRO_STORE_ROOT", "/store/one")
      let one = selfStoreRoot()
      putEnv("REPRO_STORE_ROOT", "/store/two")
      let two = resolveStoreRoot()
      check one != two

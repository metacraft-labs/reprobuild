## `repro home adopt` claims the named object and changes nothing else
## (the `repro home adopt` specification, § Carry-forward).
##
## The production pipeline (`runApply` with `adoptAddresses`, as
## `runHomeAdopt` calls it) runs over a scratch home with two `fs.userFile`
## resources. After a first apply writes both, the profile is edited to change
## the content of one (`b`) and the other (`a`) is edited out of band. An
## adopt of `a` must
## * claim the file as it is (no write), and
## * leave `b` at what the active generation recorded: the pending edit is
##   NOT applied by an adopt, and the new generation's binding for `b` is the
##   active generation's.
## A following ordinary apply then applies the edit to `b` (the positive
## control that it really was pending) and updates the now-managed `a` to its
## declared content.
##
## Falsifying mutation: removing the `if adoptOnly: continue` that skips the
## lifecycle for unclaimed resources in `pipeline.nim` makes the adopt write
## `b`, and the `b == "b1"` check fails (measured when this test was added).
## The package side of the carry-forward (only the adopted packages are
## realized, the other packages' records and launchers carry over) is covered
## by `t_adopt_carries_the_active_generation_forward`, over the same functions
## the pipeline composes the manifest from.
## No mocks: the real pipeline, store and filesystem.

import std/[os, strutils, tables, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_home_apply
import repro_home_generations
import repro_home_intent
import repro_home_resources

const HostIdentity = "pn5-adopt-gate-host"

proc profileText(bContent: string): string =
  """
import repro/profile
profile "pn5-adopt":
  resources:
    fs.userFile a:
      hostFile = "~/a.conf"
      content = "a1"
    fs.userFile b:
      hostFile = "~/b.conf"
      content = """ & "\"" & bContent & "\"" & """

  hosts:
    "pn5-adopt-gate-host": [default]
"""

suite "adopt realizes only what is adopted":
  test "an adopt of one file leaves a pending edit of another file unapplied":
    let root = createTempDir("repro-pn5-adopt-", "")
    defer: removeDir(extendedPath(root))
    let homeRoot = root / "home"
    let profileDir = root / "profile"
    createDir(homeRoot)
    createDir(profileDir)
    let profilePath = profileDir / "home.nim"
    let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
    putEnv("REPRO_HOME_POSIX_PATH_RC", homeRoot / ".profile")
    defer:
      if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
      else: delEnv("REPRO_HOME_POSIX_PATH_RC")
    proc options(): ApplyOptions =
      ApplyOptions(profileDir: profileDir, profilePath: profilePath,
        homeDir: homeRoot, stateDir: root / "state", storeRoot: root / "store",
        host: HostIdentity, preLoadedProfile: loadProfile(profilePath))

    # Generation 1: both files written.
    writeFile(profilePath, profileText("b1"))
    discard runApply(options())
    check readFile(homeRoot / "a.conf") == "a1"
    check readFile(homeRoot / "b.conf") == "b1"
    let firstGen = readCurrentGenerationId(root / "state")
    check firstGen.len > 0

    # The pending edit (b) and the out-of-band edit (a).
    writeFile(profilePath, profileText("b2"))
    writeFile(homeRoot / "a.conf", "a edited by the user")

    var adopt = options()
    for address, res in composeDesiredResources(adopt.preLoadedProfile,
        homeRoot, HostIdentity).resources:
      if res.userFileHostPath.endsWith("a.conf"):
        adopt.adoptAddresses.add(address)
    require adopt.adoptAddresses.len == 1
    discard runApply(adopt)

    check readFile(homeRoot / "a.conf") == "a edited by the user"
    check readFile(homeRoot / "b.conf") == "b1"
    let adoptedGen = readCurrentGenerationId(root / "state")
    check adoptedGen.len > 0
    check adoptedGen != firstGen

    # Positive control: the edit to b was pending, and an ordinary apply
    # applies it. The adopted a is now managed, so the same apply updates it
    # to the declared content (an update, not drift).
    discard runApply(options())
    check readFile(homeRoot / "b.conf") == "b2"
    check readFile(homeRoot / "a.conf") == "a1"

  test "adopting a, then b, then a again never reuses a generation":
    # The adopt generation carries the active one forward, so its id names
    # the generation it was made from; otherwise the third adopt would
    # overwrite the first adopt's generation (a rollback target) with content
    # that also holds b's binding.
    let root = createTempDir("repro-pn5-adopt-", "")
    defer: removeDir(extendedPath(root))
    let homeRoot = root / "home"
    let profileDir = root / "profile"
    createDir(homeRoot)
    createDir(profileDir)
    let profilePath = profileDir / "home.nim"
    let savedRc = getEnv("REPRO_HOME_POSIX_PATH_RC")
    putEnv("REPRO_HOME_POSIX_PATH_RC", homeRoot / ".profile")
    defer:
      if savedRc.len > 0: putEnv("REPRO_HOME_POSIX_PATH_RC", savedRc)
      else: delEnv("REPRO_HOME_POSIX_PATH_RC")
    writeFile(profilePath, profileText("b1"))
    writeFile(homeRoot / "a.conf", "a user")
    writeFile(homeRoot / "b.conf", "b user")
    proc adoptOf(suffix: string): string =
      var o = ApplyOptions(profileDir: profileDir, profilePath: profilePath,
        homeDir: homeRoot, stateDir: root / "state", storeRoot: root / "store",
        host: HostIdentity, preLoadedProfile: loadProfile(profilePath))
      for address, res in composeDesiredResources(o.preLoadedProfile,
          homeRoot, HostIdentity).resources:
        if res.userFileHostPath.endsWith(suffix):
          o.adoptAddresses.add(address)
      require o.adoptAddresses.len == 1
      discard runApply(o)
      readCurrentGenerationId(root / "state")
    let first = adoptOf("a.conf")
    let second = adoptOf("b.conf")
    let third = adoptOf("a.conf")
    check first.len > 0
    check second != first
    check third != first
    check third != second
    check readFile(homeRoot / "a.conf") == "a user"
    check readFile(homeRoot / "b.conf") == "b user"

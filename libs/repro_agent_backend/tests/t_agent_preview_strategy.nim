## ReproOS-Agent-Harbor-Integration M4 deliverable 1: HCR is chosen only
## when the running application proves it supports it, and every fallback
## to restart names its reason. Pure decision logic; nothing to mock.

import std/[strutils, unittest]

import repro_agent_backend

const P = "linux-x86_64-elf-direct-hcr-v1"

proc app(profile = P; caps = @["direct-patch-injection", "source-reload"]):
    HcrAdvertisement =
  HcrAdvertisement(connected: true, supportProfile: profile, capabilities: caps)

suite "M4 — preview strategy":
  test "HCR when the app's agent matches the host and the change is source":
    let d = choosePreviewStrategy(P, app(), @["greeter/src/main.c"])
    check d.strategy == psHcr

  test "every missing proof falls back to restart with its reason":
    let cases = [
      (choosePreviewStrategy("", app(), @["a.c"]), "no direct-patch"),
      (choosePreviewStrategy(P, HcrAdvertisement(), @["a.c"]), "did not connect"),
      (choosePreviewStrategy(P, app(profile = "macos-arm64-direct-hcr-in-codetracer-v1"),
                             @["a.c"]), "is not this host's"),
      (choosePreviewStrategy(P, app(caps = @["direct-patch-injection"]), @["a.c"]),
       "does not offer source-reload"),
      (choosePreviewStrategy(P, app(), @[]), "nothing changed"),
      (choosePreviewStrategy(P, app(), @["greeter/src/main.c", "greeter/repro.nim"]),
       "edits the recipe")]
    for (d, why) in cases:
      checkpoint why
      check d.strategy == psRestart
      check why in d.reason

  test "the changed paths are read from a git diff":
    let diff = "diff --git a/greeter/src/main.c b/greeter/src/main.c\n" &
      "--- a/greeter/src/main.c\n+++ b/greeter/src/main.c\n@@ -1 +1 @@\n-a\n+b\n" &
      "diff --git a/greeter/repro.nim b/greeter/repro.nim\n"
    check changedPathsOf(diff) == @["greeter/src/main.c", "greeter/repro.nim"]
    check touchesDefinition(changedPathsOf(diff))
    check not touchesDefinition(@["greeter/src/repro.nim.in"])

## Confinement for home-apply tests, including directly executed test binaries.
## The ambient home deliberately differs from the explicit apply home: a
## forgotten homeDir argument must fail rather than silently pass in isolation.
import std/[os, tempfiles]

const HomeEnvironment = ["HOME", "USERPROFILE", "XDG_CONFIG_HOME",
  "REPRO_HOME_POSIX_PATH_RC"]

template withHomeApplyGuard*(body: untyped) =
  ## Redirect fallback home lookups for this scope and inherited children.
  ## No files, directories or symlinks may be created there. Verification runs
  ## even when the body throws; restoration and cleanup run even on violation.
  ## Like other environment fixtures this must not overlap on multiple threads.
  block:
    let guardRoot = createTempDir("repro-home-guard-", "")
    let guardHome = guardRoot / "ambient-home"
    createDir(guardHome)
    var saved: array[HomeEnvironment.len, tuple[present: bool, value: string]]
    for i, name in HomeEnvironment:
      saved[i] = (existsEnv(name), getEnv(name))
    try:
      putEnv("HOME", guardHome)
      putEnv("USERPROFILE", guardHome)
      putEnv("XDG_CONFIG_HOME", guardHome / ".config")
      delEnv("REPRO_HOME_POSIX_PATH_RC")
      try:
        body
      finally:
        if not dirExists(guardHome) or symlinkExists(guardHome):
          raise newException(IOError, "home-apply test mutated ambient HOME: " & guardHome)
        for kind, path in walkDir(guardHome):
          raise newException(IOError, "home-apply test wrote outside explicit home: " & path)
    finally:
      for i, name in HomeEnvironment:
        if saved[i].present: putEnv(name, saved[i].value)
        else: delEnv(name)
      removeDir(guardRoot)

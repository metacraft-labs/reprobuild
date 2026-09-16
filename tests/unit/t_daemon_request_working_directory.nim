import std/[os, tempfiles, unittest]

import repro_cli_support

suite "daemon request working directory":
  var root, original: string
  setup:
    original = getCurrentDir()
    root = createTempDir("repro-daemon-cwd-", "")
  teardown:
    setCurrentDir(original)
    removeDir(root)

  test "a request enters its directory and returns the restoration directory":
    check enterDaemonRequestDirectory(root) == original
    check getCurrentDir() == root

  test "an invalid request directory still fails":
    expect OSError:
      discard enterDaemonRequestDirectory(root / "absent")
    check getCurrentDir() == original

  when defined(posix):
    test "a valid request survives a deleted daemon startup directory":
      let startup = root / "startup"
      createDir(startup)
      setCurrentDir(startup)
      removeDir(startup)
      expect OSError:
        discard getCurrentDir()
      check enterDaemonRequestDirectory(root) == ""
      check getCurrentDir() == root

    test "a deleted directory without a replacement is not silently accepted":
      let startup = root / "startup"
      createDir(startup)
      setCurrentDir(startup)
      removeDir(startup)
      expect OSError:
        discard enterDaemonRequestDirectory("")

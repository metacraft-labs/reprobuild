## The clean-up at the end of an image's assembly boot
## (``image_assemble.cleanUp``; ReproOS Add-On Mode §6.5.2 step 5): what
## the assembly added and the add-on does not own is removed, and the
## first-boot state the boot consumed is put back, so that every device
## booted from the image has an identity of its own (owner review of A16,
## 2026-11-08: finding F2).
##
## It runs against a scratch root laid out as an image's root filesystem
## after the assembly boot: the boot's machine id, the SSH host keys it
## generated next to one the image shipped, the random seed and credential
## secret, the staged ``.deb`` cache, the assembly unit and its link, the
## payload. No mocks: the real ``cleanUp`` on a real directory tree; only
## the journal rotation (a host tool acting on the running system) is
## left out.
##
## Falsifier: built with ``-d:reproAddonMutation=image-keeps-first-boot-state``
## the machine id and host-key cases fail.

import std/[os, strutils, tempfiles, unittest]

import repro_addon/image_assemble
import repro_addon/mutations

proc put(path, content: string) =
  createDir(path.parentDir)
  writeFile(path, content)

suite "the assembly's clean-up restores a first boot":
  let root = createTempDir("repro-a16-cleanup-", "")
  let payload = root / "var/lib/addon-image-assembly"
  put(root / "etc/machine-id", "0123456789abcdef0123456789abcdef\n")
  put(root / "etc/ssh/ssh_host_ed25519_key", "assembly private\n")
  put(root / "etc/ssh/ssh_host_ed25519_key.pub", "assembly public\n")
  put(root / "etc/ssh/ssh_host_rsa_key.pub", "shipped by the image\n")
  put(root / "etc/ssh/sshd_config", "kept\n")
  put(root / "var/lib/systemd/random-seed", "seed")
  put(root / "var/lib/systemd/credential.secret", "secret")
  put(root / "var/cache/repro/apt/aa.deb", "deb")
  put(root / "etc/systemd/system/addon-image-assembly.service", "[Unit]\n")
  createDir(root / "etc/systemd/system/multi-user.target.wants")
  createSymlink("/etc/systemd/system/addon-image-assembly.service",
    root / "etc/systemd/system/multi-user.target.wants/addon-image-assembly.service")
  put(payload / "repro", "binary")
  put(payload / "profile.txt", "profile")
  put(payload / "result.json", "{}")
  let spec = AssemblySpec(machineId: "uninitialized\n",
    keepSshHostKeys: @["ssh_host_rsa_key.pub"], stagedDebs: @["aa.deb"],
    removeDebCacheParents: @["/var/cache/repro/apt", "/var/cache/repro"])
  let before = sshHostKeyDigests(root)
  cleanUp(spec, payload, root = root, rotateJournal = false)

  test "the image's own machine id is put back":
    check readFile(root / "etc/machine-id") == "uninitialized\n"

  test "the assembly boot's SSH host keys are gone, the image's are kept":
    check not fileExists(root / "etc/ssh/ssh_host_ed25519_key")
    check not fileExists(root / "etc/ssh/ssh_host_ed25519_key.pub")
    check fileExists(root / "etc/ssh/ssh_host_rsa_key.pub")
    check fileExists(root / "etc/ssh/sshd_config")
    check before.len == 2 and sshHostKeyDigests(root).len == 1

  test "the boot's random seed and credential secret are gone":
    check not fileExists(root / "var/lib/systemd/random-seed")
    check not fileExists(root / "var/lib/systemd/credential.secret")

  test "the staged .deb cache, the unit and its link are gone":
    check not dirExists(root / "var/cache/repro")
    check not fileExists(root / "etc/systemd/system/addon-image-assembly.service")
    check not symlinkExists(root /
      "etc/systemd/system/multi-user.target.wants/addon-image-assembly.service")

  test "the payload is gone except the result the build host reads":
    check not fileExists(payload / "repro")
    check not fileExists(payload / "profile.txt")
    check fileExists(payload / "result.json")

  test "a cache directory that holds other files is kept":
    let r2 = createTempDir("repro-a16-cleanup2-", "")
    put(r2 / "var/cache/repro/apt/aa.deb", "deb")
    put(r2 / "var/cache/repro/apt/someone-elses.deb", "deb")
    put(r2 / "etc/machine-id", "x\n")
    createDir(r2 / "payload")
    cleanUp(AssemblySpec(machineId: "", stagedDebs: @["aa.deb"],
      removeDebCacheParents: @["/var/cache/repro/apt", "/var/cache/repro"]),
      r2 / "payload", root = r2, rotateJournal = false)
    check fileExists(r2 / "var/cache/repro/apt/someone-elses.deb")
    check not fileExists(r2 / "var/cache/repro/apt/aa.deb")
    check readFile(r2 / "etc/machine-id") == ""
    removeDir(r2)

  removeDir(root)

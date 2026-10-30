## Opened secrets are written with their declared mode from the moment they
## exist, and never through a symbolic link.
##
## `materialiseSecrets` runs as root (or SYSTEM). It used to write each staged
## file with the process umask and narrow the mode afterwards, leaving a window
## in which plaintext was group- or world-readable, and it followed a link
## planted at the staged name or on the destination path -- which redirects the
## plaintext, or overwrites a file of the planter's choosing with it.
##
## The cases, on real files under a temporary directory:
##
##   * a link planted at `<name>.staged` pointing at a victim file: the write
##     is refused and the victim is unchanged;
##   * a destination subdirectory that is a link to outside: refused, nothing
##     written outside;
##   * the staged file's mode at creation: an inotify-free observation is not
##     portable, so the test makes the umask maximally permissive (0) and
##     checks the final mode is exactly the declared one -- the old code
##     produced the declared mode only after a separate chmod, so this case
##     alone does not distinguish them; the two link cases do;
##   * positive control: a nested secret lands with its content and mode.
##
## No mocks: the real proc, real files and links.

import std/[os, unittest]
when defined(posix):
  import std/posix

import ../src/repro_deploy_agent/secrets

proc bytesOf(s: string): seq[byte] =
  for ch in s: result.add(byte(ch))

proc fresh(name: string): tuple[root, dest, outside: string] =
  let root = getTempDir() / ("secret-files-" & name & "-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root / "dest")
  createDir(root / "outside")
  (root, root / "dest", root / "outside")

suite "secret files are private from creation and never written through a link":
  test "a link planted at the staged name is refused":
    let t = fresh("staged")
    defer: removeDir(t.root)
    writeFile(t.outside / "victim", "original\n")
    createSymlink(t.outside / "victim", t.dest / "token.staged")
    expect SecretsError:
      discard materialiseSecrets(@[SecretFile(path: "token",
        content: bytesOf("s3cret"), mode: 0o400'u32)], t.dest)
    check readFile(t.outside / "victim") == "original\n"
    check not fileExists(t.dest / "token")

  test "a destination subdirectory that is a link to outside is refused":
    let t = fresh("dirlink")
    defer: removeDir(t.root)
    createSymlink(t.outside, t.dest / "svc")
    expect SecretsError:
      discard materialiseSecrets(@[SecretFile(path: "svc/token",
        content: bytesOf("s3cret"), mode: 0o400'u32)], t.dest)
    check not fileExists(t.outside / "token")
    check not fileExists(t.outside / "token.staged")

  test "positive control: a nested secret lands with exactly its declared mode":
    let t = fresh("ok")
    defer: removeDir(t.root)
    when defined(posix):
      let old = umask(0)
      defer: discard umask(old)
    let written = materialiseSecrets(@[SecretFile(path: "svc/token",
      content: bytesOf("s3cret"), mode: 0o400'u32)], t.dest)
    check written == @[t.dest / "svc/token"]
    check readFile(t.dest / "svc/token") == "s3cret"
    check getFilePermissions(t.dest / "svc/token") == {fpUserRead}
    check not fileExists(t.dest / "svc/token.staged")

## DSL-port M9.B acceptance — ``fs.symlink`` registration + on-disk
## materialisation.
##
## Pins:
##
##   1. ``fs.symlink(path, target)`` inside a ``package`` / ``build``
##      block records a ``DslSymlink`` with auto-filled ``packageName``,
##      verbatim ``path`` + ``target``, and a 16-char FNV-1a hash key.
##
##   2. ``consumeSymlink(packageName, path)`` materialises the recorded
##      symlink under ``<storeRoot>/<hashHex>/<relPath>``:
##        * ``hashHex`` is 64 lower-hex chars (sha256);
##        * ``relPath`` strips the leading ``/``;
##        * on Windows the materialised target is a regular file with a
##          ``# repro-symlink-intent`` header (admin/dev-mode is not a
##          test-fixture requirement); on POSIX it's a real symlink.
##
##   3. ``consumeSymlink`` is idempotent — a second call returns a
##      byte-identical handle.
##
##   4. Different target → different hashHex (cache-key discrimination).
##
## NOTE: the ``package`` macro emits ``export`` statements + other
## top-level-only Nim, so ``package <name>:`` must sit at module top
## level — not inside a ``test`` body. This test file follows the M8
## ``t_dsl_fs_configfile`` shape: register the declaration at module-init
## time, then assert on the registry from inside the ``suite``.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

# Package whose ``build:`` body registers a symlink WITHOUT supplying
# packageName — the M7 ``currentBuildPackage()`` accessor populates it.
package symPkg:
  build:
    fs.symlink("/etc/systemd/system/systemd-logind.service",
               "/lib/systemd/system/systemd-logind.service")

# Two packages registering the SAME symlink path but DIFFERENT targets,
# so the materialisation test can show hashHex discriminates on target.
package symA:
  build:
    fs.symlink("/etc/foo.link", "/lib/target-A")

package symB:
  build:
    fs.symlink("/etc/foo.link", "/lib/target-B")

suite "DSL-port M9.B — fs.symlink":

  test "fs.symlink auto-fills packageName from active build context":
    # The ``symPkg`` package above ran its ``build:`` body at module-init
    # time inside the M4-emitted ``beginBuildContext("symPkg", "")`` pair.
    # The fs.symlink call there passed an empty packageName, so the
    # auto-fill resolved to ``"symPkg"``. We do NOT call
    # ``resetDslPortFsExtState`` because the registration happened at
    # module-init and the runner can't re-run it from inside the test
    # block. This test runs FIRST.
    let entries = registeredSymlinks("symPkg")
    check entries.len == 1
    let entry = entries[0]
    check entry.path == "/etc/systemd/system/systemd-logind.service"
    check entry.target == "/lib/systemd/system/systemd-logind.service"
    check entry.packageName == "symPkg"
    check entry.hashHex.len == 16

  test "consumeSymlink materialises to <storeRoot>/<hashHex>/<relPath>":
    # State note: we keep the module-init registrations intact (they
    # already populated dslPortSymlinks). We only need to register a
    # storeRoot and clear the materialise side-table so a clean
    # consume runs.
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9b-sym-1"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("symPkg", storeRoot, dhaSha256)

    let mf = consumeSymlink("symPkg",
                            "/etc/systemd/system/systemd-logind.service")

    # sha256 emits exactly 64 lower-hex chars.
    check mf.hashHex.len == 64

    # relPath strips the leading "/".
    check mf.relPath == "etc/systemd/system/systemd-logind.service"

    # storePath is <storeRoot>/<hashHex>.
    check mf.storePath == storeRoot / mf.hashHex
    check dirExists(mf.storePath)

    # The symlink / fallback-file exists at the expected location. On
    # Windows the M9.B fallback writes a regular file with the
    # "# repro-symlink-intent" header; on POSIX it's a real OS-level
    # symlink. Either way, the path is present.
    check (fileExists(mf.storePath / mf.relPath) or
           symlinkExists(mf.storePath / mf.relPath))

    when defined(windows):
      # Windows: verify the fallback header + target line.
      let body = readFile(mf.storePath / mf.relPath)
      check body.contains("# repro-symlink-intent")
      check body.contains("/lib/systemd/system/systemd-logind.service")

    # Idempotency: a second call returns a byte-identical handle.
    let mf2 = consumeSymlink("symPkg",
                             "/etc/systemd/system/systemd-logind.service")
    check mf2.storePath == mf.storePath
    check mf2.relPath == mf.relPath
    check mf2.hashHex == mf.hashHex
    check mf2.packageName == mf.packageName
    check mf2.artifactName == mf.artifactName

  test "different target yields different hashHex":
    # Same path "/etc/foo.link", different targets (registered at
    # module-init for symA / symB), so the sha256 cache key must
    # discriminate on the target field.
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9b-sym-disc"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("symA", storeRoot, dhaSha256)
    registerStoreRoot("symB", storeRoot, dhaSha256)

    let mfA = consumeSymlink("symA", "/etc/foo.link")
    let mfB = consumeSymlink("symB", "/etc/foo.link")
    check mfA.hashHex != mfB.hashHex

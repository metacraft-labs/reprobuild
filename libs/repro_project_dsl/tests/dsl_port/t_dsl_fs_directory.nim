## DSL-port M9.B acceptance — ``fs.directory`` registration + on-disk
## materialisation.
##
## Pins:
##
##   1. ``fs.directory(path)`` inside a ``package`` / ``build`` block
##      records a ``DslDirectory`` with auto-filled ``packageName``,
##      verbatim ``path``, default ``mode = 0o755``, and a 16-char
##      FNV-1a hash key.
##
##   2. ``consumeDirectory(packageName, path)`` materialises an empty
##      directory under ``<storeRoot>/<hashHex>/<relPath>``:
##        * ``hashHex`` is 64 lower-hex chars (sha256);
##        * ``relPath`` strips the leading ``/``;
##        * the directory exists on disk after the call.
##
##   3. ``consumeDirectory`` is idempotent.
##
## NOTE: the ``package`` macro must sit at module top level — same
## constraint as ``t_dsl_fs_configfile`` / ``t_dsl_fs_symlink``.

import std/[os, unittest]

import repro_project_dsl
import repro_project_dsl/fs as fs

# Package whose ``build:`` body registers a directory WITHOUT supplying
# packageName — the M7 ``currentBuildPackage()`` accessor populates it.
package dirPkg:
  build:
    fs.directory("/var/lib/dbus")

suite "DSL-port M9.B — fs.directory":

  test "fs.directory auto-fills packageName from active build context":
    # ``dirPkg`` above registered at module-init time. We do NOT reset
    # the M9.B state here because the registration is non-recoverable
    # from inside the test block. This test runs FIRST.
    let entries = registeredDirectories("dirPkg")
    check entries.len == 1
    let entry = entries[0]
    check entry.path == "/var/lib/dbus"
    check entry.mode == 0o755
    check entry.packageName == "dirPkg"
    check entry.hashHex.len == 16

  test "consumeDirectory materialises <storeRoot>/<hashHex>/<relPath>":
    # Keep module-init registration intact; only clear the materialise
    # side-table so a clean consume runs.
    resetDslPortMaterialiseState()

    let storeRoot = getTempDir() / "dsl-m9b-dir-1"
    if dirExists(storeRoot):
      removeDir(storeRoot)
    createDir(storeRoot)

    registerStoreRoot("dirPkg", storeRoot, dhaSha256)

    let mf = consumeDirectory("dirPkg", "/var/lib/dbus")

    # sha256 emits exactly 64 lower-hex chars.
    check mf.hashHex.len == 64

    # relPath strips the leading "/".
    check mf.relPath == "var/lib/dbus"

    # storePath is <storeRoot>/<hashHex>.
    check mf.storePath == storeRoot / mf.hashHex

    # The materialised directory exists on disk at the expected
    # location.
    check dirExists(mf.storePath / mf.relPath)

    # Idempotency: a second call returns a byte-identical handle.
    let mf2 = consumeDirectory("dirPkg", "/var/lib/dbus")
    check mf2.storePath == mf.storePath
    check mf2.relPath == mf.relPath
    check mf2.hashHex == mf.hashHex

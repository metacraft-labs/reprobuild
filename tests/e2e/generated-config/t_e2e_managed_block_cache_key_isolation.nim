## M59 gate: `e2e_managed_block_cache_key_isolation`.
##
## Normative description:
##
##   Writes a managed block into a fixture .bashrc; the user edits the
##   surrounding file (outside the sentinels); the next apply hits the
##   cache and does NOT re-render the block. Then installs a second
##   independent managed block with a different blockId into the same
##   file; editing only the second block's input configurable rebuilds
##   only the second block, not the first. Verifies the cache key for
##   a fs.managedBlock action is derived only from the block content
##   bytes plus its resolved configurable inputs, not from the whole
##   host file.

import std/[os, strutils, unittest]

import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config
import repro_local_store

proc setupScope(tmpRoot: string): HomeScope =
  putEnv("REPRO_HOME_PROFILE_TARGET", tmpRoot)
  result = resolveHomeScope()

suite "M59 managed-block cache-key isolation gate":

  test "user edits to surrounding bytes do NOT invalidate the action":
    let tmpRoot = getTempDir() / "repro-m59-iso-1"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()
    let bashrc = scope.home / ".bashrc"
    writeFile(bashrc, "# initial\n")

    let inputs = @[ResolvedInput(name: "editor",
      value: cvString("nvim"))]
    let r1 = managedBlockAction(state, store, scope, "~/.bashrc",
      "envblock", "export EDITOR='nvim'", inputs)
    check r1.outcome == maInserted
    let keyAfterInsert = r1.cacheKeyHex

    # User scribbles into the file BEFORE and AFTER the sentinels.
    let withBlock = readFile(bashrc)
    let edited = "# USER PREPENDED LINE\n" & withBlock & "# USER APPENDED LINE\n"
    writeFile(bashrc, edited)

    # Re-apply with identical inputs. The cache key MUST be unchanged
    # (because the block content + inputs are unchanged), and the
    # action MUST register as a cache hit. The surrounding user edits
    # MUST survive.
    let r2 = managedBlockAction(state, store, scope, "~/.bashrc",
      "envblock", "export EDITOR='nvim'", inputs)
    check r2.outcome == maCacheHit
    check r2.cacheKeyHex == keyAfterInsert
    check not r2.rewroteHostFile
    let onDisk = readFile(bashrc)
    check "# USER PREPENDED LINE" in onDisk
    check "# USER APPENDED LINE" in onDisk
    check "export EDITOR='nvim'" in onDisk

  test "two independent blocks: editing input of one does not rebuild the other":
    let tmpRoot = getTempDir() / "repro-m59-iso-2"
    if dirExists(tmpRoot): removeDir(tmpRoot)
    createDir(tmpRoot)
    var scope = setupScope(tmpRoot)
    var store = openStore(tmpRoot / "store")
    var state = newApplyState()
    let bashrc = scope.home / ".bashrc"
    writeFile(bashrc, "# rc head\n")

    # First block: depends on `editor`.
    let editorIn = @[ResolvedInput(name: "editor",
      value: cvString("nvim"))]
    let blkA1 = managedBlockAction(state, store, scope, "~/.bashrc",
      "block-a", "export EDITOR='nvim'", editorIn)
    check blkA1.outcome == maInserted
    let keyA1 = blkA1.cacheKeyHex

    # Second block: depends on `pager`.
    let pagerIn1 = @[ResolvedInput(name: "pager",
      value: cvString("less"))]
    let blkB1 = managedBlockAction(state, store, scope, "~/.bashrc",
      "block-b", "export PAGER='less'", pagerIn1)
    check blkB1.outcome == maInserted
    let keyB1 = blkB1.cacheKeyHex

    # Sanity: both blocks present, independent ids.
    let both = readFile(bashrc)
    check ">>> repro:home:block-a >>>" in both
    check ">>> repro:home:block-b >>>" in both
    check keyA1 != keyB1

    # Re-apply block A unchanged -> cache hit, key stable.
    let blkA2 = managedBlockAction(state, store, scope, "~/.bashrc",
      "block-a", "export EDITOR='nvim'", editorIn)
    check blkA2.outcome == maCacheHit
    check blkA2.cacheKeyHex == keyA1

    # Now change block B's input (pager: less -> moar). Block B
    # rebuilds; block A's action MUST remain a cache hit.
    let pagerIn2 = @[ResolvedInput(name: "pager",
      value: cvString("moar"))]
    let blkB2 = managedBlockAction(state, store, scope, "~/.bashrc",
      "block-b", "export PAGER='moar'", pagerIn2)
    check blkB2.outcome == maUpdated
    check blkB2.cacheKeyHex != keyB1

    let blkA3 = managedBlockAction(state, store, scope, "~/.bashrc",
      "block-a", "export EDITOR='nvim'", editorIn)
    check blkA3.outcome == maCacheHit
    check blkA3.cacheKeyHex == keyA1

    # Verify both blocks coexist with the expected content.
    let final = readFile(bashrc)
    check "export EDITOR='nvim'" in final
    check "export PAGER='moar'" in final
    check "export PAGER='less'" notin final
    check ">>> repro:home:block-a >>>" in final
    check ">>> repro:home:block-b >>>" in final

  test "cache key is independent of host-file bytes":
    # Two distinct host files with the same block content + same inputs
    # MUST produce different cache keys (because the host path is part
    # of the key) — but their cache keys MUST NOT depend on anything
    # else in the surrounding file. Demonstrate that by computing the
    # raw cache key directly and asserting it is invariant under
    # surrounding edits.
    let inputs = @[ResolvedInput(name: "editor",
      value: cvString("vi"))]
    let blockContent = "export EDITOR='vi'"
    var blockBytes = newSeq[byte](blockContent.len)
    for i, ch in blockContent: blockBytes[i] = byte(ord(ch))

    let key1 = cacheKeyManagedBlock("envblock", "/home/x/.bashrc",
      blockBytes, inputs)
    let key2 = cacheKeyManagedBlock("envblock", "/home/x/.bashrc",
      blockBytes, inputs)
    check key1 == key2
    # Different host path -> different key (path participates).
    let key3 = cacheKeyManagedBlock("envblock", "/home/y/.bashrc",
      blockBytes, inputs)
    check key1 != key3
    # Different blockId -> different key.
    let key4 = cacheKeyManagedBlock("other", "/home/x/.bashrc",
      blockBytes, inputs)
    check key1 != key4
    # Different inputs -> different key.
    let key5 = cacheKeyManagedBlock("envblock", "/home/x/.bashrc",
      blockBytes,
      @[ResolvedInput(name: "editor", value: cvString("nvim"))])
    check key1 != key5

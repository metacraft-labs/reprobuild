## Slice 1 (Composable-Resource-Types.md Migration step 1): the native
## resource-type registry that replaced the closed `case kind` dispatch
## in the home-scope engine.
##
## Pins:
##   (a) importing the umbrella populates the registry with EVERY
##       built-in `ResourceKind` (typeId == $kind);
##   (b) `digestOfResource` for concrete resources is unchanged by the
##       refactor — it still equals the byte-level digest the former
##       `case` branch produced, and the digest relationships the old
##       code guaranteed still hold;
##   (c) `lookupResourceType` on an unknown id raises rather than
##       returning a zeroed default.

import std/[unittest]

import repro_home_resources

suite "slice 1: resource-type registry":

  test "import populates the registry with every built-in kind":
    # Every enum value must have a registered driver, keyed by its
    # stable string form.
    for kind in ResourceKind:
      check isResourceTypeRegistered($kind)
      let def = lookupResourceType($kind)
      check def.typeId == $kind
      # Slice 1 assigns every home-scope built-in the host-bound class.
      check def.determinism == rdHostBound
      # Both leaf callbacks are wired (non-nil).
      check def.driver.digest != nil
      check def.driver.observe != nil
    # And the registered set is exactly the enum (no extras, no gaps).
    var enumCount = 0
    for kind in ResourceKind:
      inc enumCount
    check registeredResourceTypeIds().len == enumCount

  test "digestOfResource: fs.managedBlock matches the byte-level digest":
    # The managed-block driver normalizes a non-empty body to end in a
    # single trailing '\n'. A body that already ends in '\n' and one
    # that does not therefore digest identically — the invariant the
    # former `case rkFsManagedBlock` branch guaranteed, now served
    # through the registry.
    let withNl = Resource(kind: rkFsManagedBlock, address: "mb:a",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/host", managedBlockId: "b1",
      managedBlockContent: "PATH=/foo\n")
    let withoutNl = Resource(kind: rkFsManagedBlock, address: "mb:b",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/host", managedBlockId: "b1",
      managedBlockContent: "PATH=/foo")
    check digestOfResource(withNl) == digestOfResource(withoutNl)
    # A genuinely different body digests differently.
    let other = Resource(kind: rkFsManagedBlock, address: "mb:c",
      lifecyclePolicy: lpDefault,
      hostFilePath: "/tmp/host", managedBlockId: "b1",
      managedBlockContent: "PATH=/bar")
    check digestOfResource(withNl) != digestOfResource(other)

  test "digestOfResource: fs.userFile digests content bytes verbatim":
    # A stable hardcoded relationship: literal content digests to the
    # raw content bytes (no normalization). Captured from the pre-
    # refactor code path.
    var r = Resource(kind: rkFsUserFile, address: "uf:reg",
      lifecyclePolicy: lpDefault,
      userFileHostPath: "/dev/null/ignored",
      userFileContent: "abc",
      userFileMode: "0644")
    check digestOfResource(r) == digestOfBytes(@[byte('a'), byte('b'),
      byte('c')])

  test "digestOfResource: windows.registryValue digests the payload bytes":
    var r = Resource(kind: rkWindowsRegistryValue, address: "reg:reg",
      lifecyclePolicy: lpDefault,
      registryKey: "HKCU\\Software\\X", registryName: "V")
    r.registryPayload.kind = rvkString
    r.registryPayload.bytes = encodeString("hello")
    check digestOfResource(r) == digestOfBytes(r.registryPayload.bytes)

  test "lookupResourceType: unknown id raises":
    expect KeyError:
      discard lookupResourceType("does.not.exist")
    expect KeyError:
      discard lookupResourceType("")
    check not isResourceTypeRegistered("vm_harness.container")

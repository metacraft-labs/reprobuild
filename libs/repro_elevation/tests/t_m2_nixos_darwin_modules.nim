## Library-local unit tests for the Dotfiles-Migration-Completion M2
## drivers: `linux.nixosSystemModule` and `macos.darwinSystemModule`.
## Covers the PLATFORM-PURE surface — closed-set validation, RBEB
## codec round-trip, kind <-> string helpers, requiresElevation. The
## actual file-write apply path is gated `when defined(linux)` /
## `when defined(macosx)` and exercised by the host integration tier
## (M4) — off-platform it raises `ENotImplementedPlatform`.

import std/[strutils, unittest]

import repro_core
import repro_elevation

suite "Dotfiles-Migration-Completion M2 — linux.nixosSystemModule":

  test "kind tag round-trips through the string helpers":
    check $pokLinuxNixosSystemModule == "linux.nixosSystemModule"
    check isKnownPrivilegedOperationKind("linux.nixosSystemModule")
    check privilegedOperationKindFromString("linux.nixosSystemModule") ==
      pokLinuxNixosSystemModule

  test "requiresElevation is true (system-scope)":
    check requiresElevation(pokLinuxNixosSystemModule)

  test "operationValidationError accepts a valid op":
    let ok = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "pipewire",
      nixosModuleName: "pipewire.nix",
      nixosModuleContent: "{ services.pipewire.enable = true; }")
    check operationValidationError(ok) == ""

  test "operationValidationError rejects an empty address":
    let bad = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "",
      nixosModuleName: "pipewire.nix",
      nixosModuleContent: "{ services.pipewire.enable = true; }")
    check "empty address" in operationValidationError(bad)

  test "operationValidationError rejects a basename without .nix":
    let bad = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "x",
      nixosModuleName: "pipewire.conf",
      nixosModuleContent: "{ }")
    let err = operationValidationError(bad)
    check err.len > 0
    check ".nix" in err

  test "operationValidationError rejects shell-metacharacter basename":
    let bad = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "x",
      nixosModuleName: "x;rm.nix",
      nixosModuleContent: "{ }")
    let err = operationValidationError(bad)
    check err.len > 0
    check "single-segment basename" in err

  test "operationValidationError rejects path-escape basename":
    let bad = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "x",
      nixosModuleName: "../etc/shadow.nix",
      nixosModuleContent: "{ }")
    let err = operationValidationError(bad)
    check err.len > 0

  test "operationValidationError rejects an empty basename":
    let bad = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "x",
      nixosModuleName: "",
      nixosModuleContent: "{ }")
    let err = operationValidationError(bad)
    check err.len > 0

  test "RBEB codec round-trips an apply op":
    let ok = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "hyprland",
      nixosModuleName: "hyprland.nix",
      nixosModuleContent: "{ programs.hyprland.enable = true; }",
      nixosModuleDestroy: false)
    let wired = WireOperation(operation: ok, baselineDigestHex: "abc")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.kind == pokLinuxNixosSystemModule
    check decoded.operation.address == "hyprland"
    check decoded.operation.nixosModuleName == "hyprland.nix"
    check decoded.operation.nixosModuleContent ==
      "{ programs.hyprland.enable = true; }"
    check decoded.operation.nixosModuleDestroy == false
    check decoded.baselineDigestHex == "abc"

  test "RBEB codec round-trips a destroy op":
    let dop = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule,
      address: "remove-pipewire",
      nixosModuleName: "pipewire.nix",
      nixosModuleContent: "",
      nixosModuleDestroy: true)
    let wired = WireOperation(operation: dop, baselineDigestHex: "")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.nixosModuleDestroy == true

  when not defined(linux):
    test "observe + apply raise ENotImplementedPlatform off-Linux":
      let op = PrivilegedOperation(
        kind: pokLinuxNixosSystemModule,
        address: "x",
        nixosModuleName: "x.nix",
        nixosModuleContent: "{ }")
      expect ENotImplementedPlatform:
        discard observeLinuxNixosSystemModule(op)
      expect ENotImplementedPlatform:
        discard applyLinuxNixosSystemModule(op)

suite "Dotfiles-Migration-Completion M2 — macos.darwinSystemModule":

  test "kind tag round-trips through the string helpers":
    check $pokMacosDarwinSystemModule == "macos.darwinSystemModule"
    check isKnownPrivilegedOperationKind("macos.darwinSystemModule")
    check privilegedOperationKindFromString("macos.darwinSystemModule") ==
      pokMacosDarwinSystemModule

  test "requiresElevation is true (system-scope)":
    check requiresElevation(pokMacosDarwinSystemModule)

  test "operationValidationError accepts a valid op":
    let ok = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule,
      address: "dock",
      darwinModuleName: "dock.nix",
      darwinModuleContent: "{ system.defaults.dock.autohide = true; }")
    check operationValidationError(ok) == ""

  test "operationValidationError rejects an empty address":
    let bad = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule,
      address: "",
      darwinModuleName: "dock.nix",
      darwinModuleContent: "{ }")
    check "empty address" in operationValidationError(bad)

  test "operationValidationError rejects a basename without .nix":
    let bad = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule,
      address: "x",
      darwinModuleName: "dock",
      darwinModuleContent: "{ }")
    let err = operationValidationError(bad)
    check err.len > 0
    check ".nix" in err

  test "operationValidationError rejects shell-metacharacter basename":
    let bad = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule,
      address: "x",
      darwinModuleName: "x;rm.nix",
      darwinModuleContent: "{ }")
    let err = operationValidationError(bad)
    check err.len > 0
    check "single-segment basename" in err

  test "RBEB codec round-trips an apply op":
    let ok = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule,
      address: "dock",
      darwinModuleName: "dock.nix",
      darwinModuleContent: "{ system.defaults.dock.autohide = true; }",
      darwinModuleDestroy: false)
    let wired = WireOperation(operation: ok, baselineDigestHex: "")
    let dec = decodeFrame(encodeOperation(wired))
    let decoded = decodeOperation(dec.body)
    check decoded.operation.kind == pokMacosDarwinSystemModule
    check decoded.operation.address == "dock"
    check decoded.operation.darwinModuleName == "dock.nix"
    check decoded.operation.darwinModuleContent ==
      "{ system.defaults.dock.autohide = true; }"

  when not defined(macosx):
    test "observe + apply raise ENotImplementedPlatform off-macOS":
      let op = PrivilegedOperation(
        kind: pokMacosDarwinSystemModule,
        address: "x",
        darwinModuleName: "x.nix",
        darwinModuleContent: "{ }")
      expect ENotImplementedPlatform:
        discard observeMacosDarwinSystemModule(op)
      expect ENotImplementedPlatform:
        discard applyMacosDarwinSystemModule(op)

suite "Dotfiles-Migration-Completion M2 — desired-digest computation":

  test "linux.nixosSystemModule desired digest covers content":
    let opA = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule, address: "x",
      nixosModuleName: "x.nix",
      nixosModuleContent: "{ a = true; }")
    let opB = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule, address: "x",
      nixosModuleName: "x.nix",
      nixosModuleContent: "{ a = false; }")
    let digA = posixSystemDesiredDigestHex(opA)
    let digB = posixSystemDesiredDigestHex(opB)
    check digA != digB
    check digA.len == 64
    # destroy op digests to the absent sentinel
    let opDestroy = PrivilegedOperation(
      kind: pokLinuxNixosSystemModule, address: "x",
      nixosModuleName: "x.nix",
      nixosModuleContent: "",
      nixosModuleDestroy: true)
    check posixSystemDesiredDigestHex(opDestroy) == ZeroDigestHex

  test "macos.darwinSystemModule desired digest covers content":
    let opA = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule, address: "x",
      darwinModuleName: "x.nix",
      darwinModuleContent: "{ a = true; }")
    let opB = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule, address: "x",
      darwinModuleName: "x.nix",
      darwinModuleContent: "{ a = false; }")
    let digA = posixSystemDesiredDigestHex(opA)
    let digB = posixSystemDesiredDigestHex(opB)
    check digA != digB
    let opDestroy = PrivilegedOperation(
      kind: pokMacosDarwinSystemModule, address: "x",
      darwinModuleName: "x.nix",
      darwinModuleContent: "",
      darwinModuleDestroy: true)
    check posixSystemDesiredDigestHex(opDestroy) == ZeroDigestHex

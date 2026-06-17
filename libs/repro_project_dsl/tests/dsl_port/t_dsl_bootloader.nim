## DSL-port M9.G acceptance — ``bootloader:`` block registry.
##
## Pins the M9.G ``bootloader:`` directive contract. NDEM1 (reproos-
## desktop) declares per-package GRUB metadata via a ``bootloader:``
## block whose body recognises three top-level setters
## (``generationEntry`` / ``timeout`` / ``defaultEntry``) plus zero or
## more nested ``menuEntry:`` blocks.
##
## Coverage:
##
##   * Test 1 — basic register: one block declaring ``generationEntry``,
##     ``timeout``, and a single ``menuEntry:`` body. The registry row
##     captures every field verbatim and exposes the menu-entry row in
##     declaration order.
##
##   * Test 2 — multi-menu-entry: one block declaring three distinct
##     ``menuEntry:`` bodies. The registry preserves source-declaration
##     order across the three rows; per-row title fields byte-match
##     the source-level spellings.

import std/[unittest]

import repro_project_dsl

package bootPkg:
  bootloader:
    generationEntry: true
    timeout: 5
    menuEntry:
      title "ReproOS gen-001"
      kernel "/boot/vmlinuz-001"
      initrd "/boot/initrd-001"
      cmdline "root=LABEL=ReproOS ro"

package bootMultiPkg:
  bootloader:
    generationEntry: true
    timeout: 3
    menuEntry:
      title "ReproOS gen-A"
      kernel "/boot/vmlinuz-A"
      initrd "/boot/initrd-A"
      cmdline "root=LABEL=ReproOS ro arm=a"
    menuEntry:
      title "ReproOS gen-B"
      kernel "/boot/vmlinuz-B"
      initrd "/boot/initrd-B"
      cmdline "root=LABEL=ReproOS ro arm=b"
    menuEntry:
      title "ReproOS gen-C"
      kernel "/boot/vmlinuz-C"
      initrd "/boot/initrd-C"
      cmdline "root=LABEL=ReproOS ro arm=c"

suite "DSL-port M9.G — bootloader: block registry":

  test "basic bootloader: generationEntry + timeout + menuEntry":
    let cfg = registeredBootloaderConfig("bootPkg")
    # Top-level setters captured verbatim.
    check cfg.packageName == "bootPkg"
    check cfg.generationEntry == true
    check cfg.timeout == 5
    # defaultEntry was never declared — stays at the unset default.
    check cfg.defaultEntry == ""
    # One menu-entry row.
    check cfg.menuEntries.len == 1
    check cfg.menuEntries[0].title == "ReproOS gen-001"
    check cfg.menuEntries[0].kernel == "/boot/vmlinuz-001"
    check cfg.menuEntries[0].initrd == "/boot/initrd-001"
    check cfg.menuEntries[0].cmdline == "root=LABEL=ReproOS ro"
    # The menu-entry row carries the parent package name so apply-phase
    # consumers can attribute the row even after a copy.
    check cfg.menuEntries[0].packageName == "bootPkg"

  test "multi-menu-entry preserves source-declaration order":
    let cfg = registeredBootloaderConfig("bootMultiPkg")
    # Three menu-entry rows.
    check cfg.menuEntries.len == 3
    # Order preserved across the three rows.
    check cfg.menuEntries[0].title == "ReproOS gen-A"
    check cfg.menuEntries[1].title == "ReproOS gen-B"
    check cfg.menuEntries[2].title == "ReproOS gen-C"
    # Per-row remaining fields round-trip exact.
    check cfg.menuEntries[0].kernel == "/boot/vmlinuz-A"
    check cfg.menuEntries[1].kernel == "/boot/vmlinuz-B"
    check cfg.menuEntries[2].kernel == "/boot/vmlinuz-C"
    check cfg.menuEntries[0].cmdline == "root=LABEL=ReproOS ro arm=a"
    check cfg.menuEntries[1].cmdline == "root=LABEL=ReproOS ro arm=b"
    check cfg.menuEntries[2].cmdline == "root=LABEL=ReproOS ro arm=c"
    # Top-level setters captured on the second package as well.
    check cfg.generationEntry == true
    check cfg.timeout == 3

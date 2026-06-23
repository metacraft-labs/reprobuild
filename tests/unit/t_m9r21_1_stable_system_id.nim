## M9.R.21.1 — stable system identifier composer.
##
## Spec: ``reprobuild-specs/ReproOS-Configuration-Architecture.md`` §3.2.
## The composer combines DMI fields (when usable) into a
## deterministic 26-char Crockford-base32 identifier; falls back to a
## persistent UUID at ``/etc/repro/machine-id`` when DMI is absent or
## obviously a BIOS placeholder.
##
## Five cases:
##   1. A populated DMI tree yields a 26-char ID and is deterministic.
##   2. A missing DMI tree triggers the UUID fallback path.
##   3. Same DMI fields → same ID across calls.
##   4. Different DMI fields → different IDs.
##   5. ``/etc/repro/machine-id`` persists across calls.

import std/[os, strutils, unittest]

import repro_profile

const TmpRoot = "build/m9r21_1_tmp"

proc resetTmp(sub: string): string =
  let dir = TmpRoot / sub
  if dirExists(dir): removeDir(dir)
  createDir(dir)
  dir

proc writeDmi(dir, name, content: string) =
  writeFile(dir / name, content)

proc isCrockford(s: string): bool =
  const Alphabet = {'0' .. '9', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H',
                    'J', 'K', 'M', 'N', 'P', 'Q', 'R', 'S', 'T', 'V',
                    'W', 'X', 'Y', 'Z'}
  for c in s:
    if c notin Alphabet: return false
  true

suite "M9.R.21.1: stable system-ID composer":

  test "Test#1: populated DMI tree → 26-char deterministic ID":
    let dmi = resetTmp("test1_dmi")
    writeDmi(dmi, "board_vendor",   "ASUSTeK COMPUTER INC.")
    writeDmi(dmi, "board_name",     "ROG STRIX X670E-F GAMING")
    writeDmi(dmi, "board_serial",   "SN-ABC123456789")
    writeDmi(dmi, "product_uuid",   "550e8400-e29b-41d4-a716-446655440000")
    writeDmi(dmi, "chassis_serial", "CH-XYZ987654321")
    let mid = resetTmp("test1_mid") / "machine-id"
    let id1 = composeStableSystemId(dmi, mid)
    let id2 = composeStableSystemId(dmi, mid)
    check id1.len == 26
    check id1 == id2
    check isCrockford(id1)
    # Without DMI the machine-id file should NOT have been created.
    check not fileExists(mid)

  test "Test#2: missing DMI → UUID fallback creates machine-id":
    let dmi = resetTmp("test2_dmi")        # empty DMI dir
    let mid = resetTmp("test2_mid") / "machine-id"
    let id = composeStableSystemId(dmi, mid)
    check id.len == 26
    check isCrockford(id)
    check fileExists(mid)
    let mc = readFile(mid).strip()
    check mc.len == 32  # 16-byte UUID encoded as 32 hex chars

  test "Test#3: same DMI fields → same ID across construction order":
    let dmiA = resetTmp("test3_a")
    let dmiB = resetTmp("test3_b")
    for d in [dmiA, dmiB]:
      writeDmi(d, "board_vendor",   "Dell Inc.")
      writeDmi(d, "board_name",     "XPS 13 9310")
      writeDmi(d, "board_serial",   "DELLSN-12345")
      writeDmi(d, "product_uuid",   "11111111-2222-3333-4444-555555555555")
      writeDmi(d, "chassis_serial", "DELL-CH-9999")
    let midA = resetTmp("test3_mida") / "mid"
    let midB = resetTmp("test3_midb") / "mid"
    check composeStableSystemId(dmiA, midA) ==
          composeStableSystemId(dmiB, midB)

  test "Test#4: different DMI fields → different IDs":
    let dmiA = resetTmp("test4_a")
    writeDmi(dmiA, "board_vendor", "MachineA")
    writeDmi(dmiA, "board_serial", "AAA-111")
    let dmiB = resetTmp("test4_b")
    writeDmi(dmiB, "board_vendor", "MachineB")
    writeDmi(dmiB, "board_serial", "BBB-222")
    let midA = resetTmp("test4_mida") / "mid"
    let midB = resetTmp("test4_midb") / "mid"
    let idA = composeStableSystemId(dmiA, midA)
    let idB = composeStableSystemId(dmiB, midB)
    check idA != idB
    check idA.len == 26
    check idB.len == 26

  test "Test#5: machine-id persists across runs":
    let dmi = resetTmp("test5_dmi")        # empty -> UUID path
    let mid = resetTmp("test5_mid") / "machine-id"
    let id1 = composeStableSystemId(dmi, mid)
    let firstContents = readFile(mid)
    let id2 = composeStableSystemId(dmi, mid)
    let secondContents = readFile(mid)
    check id1 == id2
    check firstContents == secondContents
    # And a placeholder DMI (well-known BIOS strings) is treated as
    # absent: ``Default string`` + all-zero product_uuid → still fall
    # back to the persisted UUID.
    writeDmi(dmi, "board_vendor", "Default string")
    writeDmi(dmi, "product_uuid", "00000000-0000-0000-0000-000000000000")
    let id3 = composeStableSystemId(dmi, mid)
    check id3 == id1

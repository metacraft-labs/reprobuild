# m7_native_c — native instruction-byte fixture

A tiny C program (`src/three_funcs.c`) with four functions used by the M7
native shallow-hash tests (`tests/t_native_hash.nim`). Native shallow hashing
identifies a function by its **compiled instruction bytes**, not its source text
(spec §16.7.1 "System languages (DWARF-based)").

## Functions

| function   | role                                   | leaf? |
|------------|----------------------------------------|-------|
| `used_a`   | on the test path (edited to test hash change) | yes |
| `used_b`   | on the test path; per-function-precision target | yes (pure leaf) |
| `unused_c` | NOT on the test path                   | yes   |
| `main`     | entry point; calls `used_a` + `used_b` | no    |

All non-`main` functions are `__attribute__((noinline))` so each keeps a
distinct symbol and its own block of machine code, and the leaves encode no
sibling address (so editing one does not change another's bytes).

## Building

The binary is **not committed**. The test builds it at test time into a temp
dir via `build.sh <source.c> <out>`, which runs the dev shell's `cc`:

```
cc -O0 -g -fno-stack-protector -fno-asynchronous-unwind-tables -o <out> <source.c>
```

Building twice (and building an edited copy) in temp dirs is what makes rebuild
determinism and per-function precision genuinely testable.

## Platform / tooling (this host: arm64 macOS → Mach-O)

`cc` emits a **Mach-O** binary. `nm --print-size` returns zero on Mach-O, so the
function table computes each function's size from the **delta to the next
symbol's address** (symbols address-sorted), bounding the last function by the
end of `__TEXT,__text`. Tools: `nm -n --defined-only` (symbols) + `otool -l`
(the `__TEXT,__text` `addr`/`offset`/`size`). The virtual-address → file-offset
mapping is `file_offset = sym.vmaddr − text.addr + text.offset`. See the module
doc-comment in `src/repro_ct_incremental/native_hash.nim` for the full
documentation, including the ELF (Linux) branch.

## Per-function precision under address shift — what holds, and the limitation

`nativeFunctionTable` locates each function independently by its own symbol and
hashes only that function's bytes, so an edit confined to one function never
leaks into a sibling's hash (`editing_one_native_function_leaves_anothers_hash_stable`).

Precision under *relocation* (a function's address physically moving) is more
subtle and is **not unconditional**:

- **Position-independent functions** (pure leaves: no calls, no pc-relative
  branches, no absolute address refs) emit byte-identical machine code wherever
  they land, so a relocated leaf keeps its hash. Demonstrated by
  `relocated_leaf_function_keeps_its_instruction_hash`.

- **Call-containing functions** encode a *pc-relative* offset to their callee
  (arm64 `bl`, x86 `call rel32`). If a layout change alters the caller→callee
  distance, those operand bytes change, so the function's hash **changes even
  with unchanged source**. Demonstrated by
  `relocated_call_containing_function_rehashes_safely` (empirically the `bl`
  word flips, e.g. `0x97fffff2 → 0x97ffffd5`).

  This is **SAFE**, never a correctness hole: a changed shallow hash drives the
  engine to a conservative **re-run**, never a false skip. It is a
  precision/usefulness limitation only — native skip decisions stay sound, just
  less aggressive for call-containing functions whose callee distance shifted.

Note the fixture's own `used_a` edit grows `used_a` toward *lower* addresses, so
`used_b`/`unused_c`/`main` keep their addresses and don't actually relocate in
that test — which is exactly why the `relocated_*` tests construct a layout
where unedited functions genuinely move.

# Hot-Reload Gate Drivers

These programs are helpers for the shell gates under `tests/integration`, not
standalone test-suite entries. The gates create their binary fixtures and supply
the command-line arguments. Keep new helper programs in this directory rather
than adding `test_*.nim` or `t_*.nim` files under `tests/integration`: those names
are reserved for independently runnable tests enrolled in `repro_tests.nim`.

From the repository root, run the relevant gate with its negative controls:

```sh
bash tests/integration/test_hax_m0_reverse_relocation_index_and_dead_patch_reachability.sh --include-falsifier
bash tests/integration/test_hax_m1_binary_type_layout_diff_detects_field_shifts.sh --include-falsifier
```

Passing the source-enrollment check does not execute these shell gates. They
must be run explicitly when their drivers or production components change.

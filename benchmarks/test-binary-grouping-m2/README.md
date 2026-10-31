# Test-Binary-Grouping M2 measurement harness

Reproduces the M2 measurements in `reprobuild-specs/spec/Test-Binary-Grouping.md`
("M2 results"). Run every step from the repository root inside `nix develop`.
Every compile uses the ENGINE'S OWN argv, read from `repro graph --format=json`.

1. Dump the two graphs (the grouped suite and the per-file baseline):

       ./build/bin/repro graph '.#test-builds' --tool-provisioning=path --format=json > build/m2-dry/graph-tb.json
       ./build/bin/repro graph '.#test-builds-per-file' --tool-provisioning=path --format=json > build/m2-dry/graph-perfile.json

2. Choose groups and prepare the jobs. `prepare_jobs.sh` writes each group
   module exactly as its `writeText` edge would (the edge's `builtinText`), one
   argv file per compile, and a job list that interleaves grouped and per-file
   compiles by a stable hash so both see the same host load:

       bash benchmarks/test-binary-grouping-m2/prepare_jobs.sh \
         build/m2-dry/graph-tb.json build/m2-dry/graph-perfile.json build/m2-jobs \
         t_group_tests_unit_g01 t_group_libs_repro_core_tests_g01 ...

3. Compile cold, at most 8 at a time (set `GNU_TIME` to a GNU `time`, e.g.
   from `nixpkgs#time`). `compile1.sh` removes the nimcache first and adds
   `--parallelBuild:1`, so N concurrent compiles mean N C compilers:

       xargs -P 8 -L 1 sh -c 'bash benchmarks/test-binary-grouping-m2/compile1.sh $1 $0' < build/m2-jobs/jobs.txt

   `build/m2-results/compile-results.tsv` gets one row per binary:
   `variant stem "wall user sys maxrssKB exit" rc start load1`.

4. Correctness: put the group binaries in one directory and their members'
   own binaries in another (hard links), and run the real suite runner over
   each, one directory at a time:

       ./build/bin/repro_test_runner --no-build --threads=4 --test-timeout=1800 \
         --bin-dir=<dir> --summary-json=<variant>.json --results-dir=<results>

   Compare `(source, qualified_name, status)` from the two summaries. The
   runner keys `source` on the member file, so the rows are directly
   comparable.

`runcases.sh` is the M1-style alternative to step 4 (each case in its own
process, without the runner).

`write_group_module.nim` renders `build/test-groups/<group>.nim` from
`repro_tests.nim` with the recipe's own `groupModuleText`, for when a group's
membership changed after the graph was dumped (byte-identical to the
`writeText` edge's text):

    nim c -o:build/m2-tools/write_group_module benchmarks/test-binary-grouping-m2/write_group_module.nim
    build/m2-tools/write_group_module t_group_libs_repro_cli_support_tests_g01

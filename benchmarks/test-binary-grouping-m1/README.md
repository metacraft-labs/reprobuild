# Test-Binary-Grouping M1 measurement harness

Reproduces the measurement in `reprobuild-specs/spec/Test-Binary-Grouping.md`,
section "M1 results". Run every step from the repository root, inside
`nix develop`. Output goes to `$M1_OUT` (default `build/m1-results`).

1. Generate group modules, one directory per G:

       nim c -o:build/m1-tools/gentg scripts/generate_test_groups.nim
       for g in 10 25 50; do
         build/m1-tools/gentg --dir=tests/unit --max=$g --out=build/test-groups/unit-g$g
       done

2. Compile cold (set `GNU_TIME` to a GNU `time` binary, e.g. from `nixpkgs#time`), at most 6 compiles at a time. `nimflags.txt` holds the
   `.#test-builds` argv for a default-option test (the flags between `nim c`
   and `--nimcache:`). The store paths in it are host-specific: refresh it
   from a live `.#test-builds` compile or from `repro graph '.#test-builds'`.
   Each line of the job list is `<variant> <source>`:

       xargs -P 6 -L 1 benchmarks/test-binary-grouping-m1/compile1.sh < jobs.txt

   `compile-results.tsv` gets one row per binary:
   `variant stem "wall user sys maxrssKB exit" rc start load1`.

3. Run every case in its own process, one variant at a time:

       ls build/m1/<variant>/* | xargs -P 6 -I{} benchmarks/test-binary-grouping-m1/runcases.sh {} "$M1_OUT/runs/<variant>"

4. Start-up probe: `startup.sh <binary> <reps> <case>`. An unknown case name
   (`'no such suite::no such test'`) measures module initialisation only.

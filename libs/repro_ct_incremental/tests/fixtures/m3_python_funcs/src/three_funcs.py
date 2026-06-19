# M3 Python fixture for trace-based incremental testing.
#
# Three functions live here. `main` calls `used_a` and `used_b`; `unused_c`
# is defined but never called. The hand-built trace (see ../trace) therefore
# has Call records only for main/used_a/used_b, so the executed-function set is
# exactly {main, used_a, used_b} and `unused_c` is absent.
#
# Python is indentation-delimited, so the `.py` extractor captures each body
# from the `def` line through the last line indented deeper than the `def`.
#
# Line numbers matter: the trace's Function records carry the definition lines
# below, and the engine extracts the function body from this source by line.
# Keep the `def` lines stable:
#   used_a   -> line 20
#   used_b   -> line 24
#   unused_c -> line 28
#   main     -> line 32


def used_a():
    return 1 + 1


def used_b():
    return 2 + 2


def unused_c():
    return 3 + 3


def main():
    used_a()
    used_b()


main()

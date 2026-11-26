# This program imports reprobuild's root `repro.nim` in the project DSL's thin
# mode (see the program's header). Reprobuild's `config.nims` defines
# `reproEvalMode` for every compile in the tree, which would compile the
# engine with it; Nim reads this file after that one, and only when this
# program is the main module, so every compile of it (`just build`, the
# `apps` graph edge, `nim check`) is thin.
switch("undef", "reproEvalMode")

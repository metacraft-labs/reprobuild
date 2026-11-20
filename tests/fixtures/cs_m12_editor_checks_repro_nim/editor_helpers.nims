# Nim reads this file only when editor_helpers.nim is the main file: it gives
# the helper the full DSL when an editor or `nim check` opens it on its own.
switch("define", "reproEvalMode")

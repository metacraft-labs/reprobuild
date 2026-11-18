# repro_nimble_reader

Reads a Nimble package's `.nimble` file as data, without evaluating it: no
NimScript VM, no `nimble`, no process, no file but the `.nimble` itself. The
Nimble package catalog uses it to record each version's requirements and
layout, so resolution never reads a `.nimble`; develop mode uses the same code
for a workspace sibling's working tree.

| Module | What it holds |
| --- | --- |
| `repro_nimble_reader.nim` | the public API: `readNimbleSource`, `readNimbleFile`, `findNimbleFile`, `readPackageDir`, `sourceDir` |
| `repro_nimble_reader/reader.nim` | the static reader of the declarative subset, the typed record (`NimbleFile`) and its class: plain, closed-when, feature, needs-override, needs-probe, unreadable |
| `repro_nimble_reader/requirements.nim` | Nimble requirement strings (`>=`, `&`, `^=`, `~=`, `#head`, `#<commit>`, URLs, `?subdir=`, forge aliases, feature lists) translated into the range grammar of `repro_solver/version_constraints`, and the `nimble:` identity |
| `repro_nimble_reader/conditions.nim` | `when` conditions over the closed set (`defined(<os>)`, `defined(<cpu>)`, `hostOS == "<os>"`, `hostCPU == "<cpu>"`, `and`, `or`, `not`) as typed data |
| `repro_nimble_reader/syntax.nim` | the statement structure and expressions of a Nim file, read by indentation |
| `repro_nimble_reader/lexer.nim` | the Nim tokenizer underneath |

Tests: `libs/repro_nimble_reader/tests/`.

# Prints Nimble's own answers to `<` and `==` for the version pairs of
# test_npc_m15_n_component_versions_order_as_nimble. Run with the source of
# Nimble 0.20.1 (tag v0.20.1, commit 9207e8b2bbdf66b5a4d1020214cff44d2d30df92)
# on the import path:
#   nim e --path:<nimble>/src nimble_answers.nims > nimble_answers.tsv
# Output columns: a, b, a < b, a == b, b < a.
import nimblepkg/version

const pairs = [
  ("1.2", "1.2.0.0"),
  ("0.6.0.3", "0.6.0.3.0"),
  ("0.6.0.3", "0.6.0.3.1"),
  ("0.7.0.8.0", "0.6.0.3.1"),
  ("1.10", "1.9.9.9"),
  ("0.6.0.3.0", "0.6.0.3.1"),
  ("0.6.0.4", "0.6.0.3.1"),
  ("0.7.0", "0.7.0.8.0"),
  ("1.0", "1.0.0.0.0.0.0.1"),
  ("2", "1.99.99.99.99"),
  ("1.2.3", "1.2.3"),
  ("0.0.0.1", "0.0.0"),
]
for (a, b) in pairs:
  let x = newVersion(a)
  let y = newVersion(b)
  echo a, "\t", b, "\t", x < y, "\t", x == y, "\t", y < x

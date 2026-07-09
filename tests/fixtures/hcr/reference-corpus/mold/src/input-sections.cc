// reprobuild.hcr.reference-corpus fixture: mold
// Models input-section metadata used by relocation and shrinking passes.
namespace mold_fixture {
struct InputSection {
  int id;
  int relocationCount;
};
int section_weight(InputSection section) {
  return section.id + section.relocationCount;
}
}

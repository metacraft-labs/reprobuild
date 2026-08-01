// reprobuild.hcr.reference-corpus fixture: mold
// Ensures the corpus has an explicit relocatable-object reference path.
namespace mold_fixture {
bool writes_relocatable_object(bool sharedLibraryMode) {
  return !sharedLibraryMode;
}
}

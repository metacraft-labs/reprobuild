/*
 * COMDAT / `SHT_GROUP` fixture for the HLX-M1 ELF object reader (design §7.5).
 *
 * Vague-linkage entities — template instantiations, vtables, typeinfo, and
 * inline functions whose address is taken — are the ordinary way a C++
 * translation unit produces `GRP_COMDAT` groups: every TU that needs them
 * emits its own copy, and the linker keeps one and discards the rest. That
 * matters to a patch plan, because bytes extracted from one object's copy are
 * not necessarily the copy that was linked — which is why the reader reports
 * COMDAT membership as a structured reason instead of ignoring it.
 *
 * Note on why the addresses are taken and the class is polymorphic: a first
 * version of this fixture used only a template and an inline member, and at
 * `-O2` GCC inlined both and emitted NO groups at all — the fixture described
 * a feature the object did not contain. Taking the address of an inline
 * function forces an out-of-line copy, and a polymorphic class forces a
 * COMDAT vtable and typeinfo, neither of which inlining can remove.
 *
 * This is not a synthetic concern. Measured on a real Godot build, one
 * translation unit (`scene/register_scene_types`) compiles to 9,660 sections
 * carrying 3,723 COMDAT groups.
 */

template <typename T>
struct HcrLxBox {
  T value;
  T doubled() const { return value + value; }
  static T twice(T input) { return input + input; }
};

struct HcrLxBase {
  virtual ~HcrLxBase();
  virtual int describe() const { return 1; }
};

struct HcrLxDerived : HcrLxBase {
  int describe() const override { return 2; }
};

inline int hcr_lx_shared_inline(int input) { return input * 3; }

/* Forces an out-of-line, COMDAT copy of the inline function. */
int (*hcr_lx_comdat_keep_alive)(int) = &hcr_lx_shared_inline;

HcrLxBase *hcr_lx_comdat_make() { return new HcrLxDerived(); }

int hcr_lx_comdat_use(int input) {
  HcrLxBox<int> box{input};
  HcrLxBox<long> wide{input};
  return box.doubled() + static_cast<int>(HcrLxBox<long>::twice(wide.value)) +
         HcrLxBox<int>::twice(input) + hcr_lx_comdat_make()->describe() +
         hcr_lx_comdat_keep_alive(input);
}

/*
 * HX-W-0 linked-image entry-geometry fixture.
 *
 * The verification gate builds this exact source with each Windows toolchain
 * and flag set in the decision matrix.  Exporting the victim gives the gate a
 * PE-native, linker-produced RVA to inspect; the address is never recovered
 * from an object file or guessed from disassembly text.
 */

#if defined(_MSC_VER)
#define HCR_EXPORT __declspec(dllexport)
#define HCR_NOINLINE __declspec(noinline)
#else
#define HCR_EXPORT __attribute__((dllexport))
#define HCR_NOINLINE __attribute__((noinline))
#endif

HCR_EXPORT HCR_NOINLINE int victim(int value) { return value + 11; }

int main(void) { return victim(1) == 12 ? 0 : 3; }

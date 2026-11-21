/* The service of the A16 image gate's fixture apt closure
 * (tests/e2e/addon/t_e2e_addon_zero_touch_image_synthesis_boots_converged.nim):
 * a static binary that waits forever. It is static because the unit's /usr is
 * the closure's own (BindReadOnlyPaths=<closure>/usr:/usr), which holds this
 * file and nothing else -- no shell, no libc. */
#include <unistd.h>

int main(void) {
  for (;;) pause();
}

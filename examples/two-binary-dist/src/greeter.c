/* Trivial component #1 of the M0 packaging-layer sample. Prints a
 * greeting, optionally honouring the TWO_BIN_DIST_GREETING env-default
 * the generated §5 wrapper seeds. */
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  const char *who = getenv("TWO_BIN_DIST_GREETING");
  printf("greeter: %s\n", who ? who : "hello from reprobuild packaging");
  return 0;
}

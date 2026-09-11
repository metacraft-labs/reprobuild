#include <stdio.h>
#include <stdlib.h>

int main(void) {
  if (getenv("LD_LIBRARY_PATH") != NULL ||
      getenv("DYLD_LIBRARY_PATH") != NULL ||
      getenv("DYLD_FALLBACK_LIBRARY_PATH") != NULL) {
    fputs("package loader path leaked into user action\n", stderr);
    return 86;
  }
  puts("reprobuild packaged runtime: hello");
  return 0;
}

#include <stdio.h>
const char *featlib_compiled_features(void);
int main(void) {
  printf("featlib=%s\n", featlib_compiled_features());
  return 0;
}

#ifndef _WIN32
#error This fixture is intended for Windows compiler environment tests.
#endif

#include <stdio.h>

int main(void) {
  puts("hello from a Windows compiler environment");
  return 0;
}

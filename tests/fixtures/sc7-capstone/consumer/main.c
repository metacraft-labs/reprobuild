#include <stdio.h>
#include <greeting.h>
int main(void) {
  FILE *f = fopen("build/consumed.txt", "w");
  if (!f) return 2;
  fputs(scprodlib_greeting(), f);
  fclose(f);
  return 0;
}

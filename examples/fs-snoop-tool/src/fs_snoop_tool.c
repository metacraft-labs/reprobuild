#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  FILE *in;
  FILE *out;
  char buffer[256];

  if (argc != 3) {
    fputs("usage: fs-snoop-tool <input> <output>\n", stderr);
    return 2;
  }

  in = fopen(argv[1], "r");
  if (in == NULL) {
    perror("open input");
    return 1;
  }

  out = fopen(argv[2], "w");
  if (out == NULL) {
    perror("open output");
    fclose(in);
    return 1;
  }

  while (fgets(buffer, sizeof(buffer), in) != NULL) {
    fputs(buffer, out);
  }

  fclose(out);
  fclose(in);
  return 0;
}

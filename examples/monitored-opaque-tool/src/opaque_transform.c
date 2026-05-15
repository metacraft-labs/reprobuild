#include <ctype.h>
#include <stdio.h>

int main(int argc, char **argv) {
  FILE *in;
  FILE *out;
  int ch;

  if (argc != 3) {
    fputs("usage: opaque-transform <input> <output>\n", stderr);
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

  while ((ch = fgetc(in)) != EOF) {
    fputc(toupper(ch), out);
  }

  fclose(out);
  fclose(in);
  return 0;
}

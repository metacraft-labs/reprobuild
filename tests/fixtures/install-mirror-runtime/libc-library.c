int puts(const char *message);

int repro_libc_probe(void) {
  return puts("shared libc probe") < 0;
}

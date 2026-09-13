int omp_get_max_threads(void);

int main(void) {
  return omp_get_max_threads() < 1;
}

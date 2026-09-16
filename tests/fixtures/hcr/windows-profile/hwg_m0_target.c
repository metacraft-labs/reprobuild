/*
 * HWG-M0 real MSVC/PDB profile target. No mocks are used: both private
 * functions must survive in the linked PE and resolve through its full PDB.
 */
#include <stdint.h>

__declspec(noinline) __declspec(dllexport) int victim(int value) {
  return value + 11;
}

__declspec(noinline) int second_private(int value) {
  volatile int retained = value + 17;
  return retained;
}

int main(void) {
  return victim(3) == 14 && second_private(3) == 20 ? 0 : 1;
}

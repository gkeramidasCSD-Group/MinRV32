#include <stdint.h>

#define SIGNATURE_BASE ((volatile uint32_t *)0x20000100)

__asm__ (
  ".section .init\n"
  ".globl _start\n"
  "_start:\n"
  "  la sp, __stack_top\n"
  "  jal ra, main\n"
  "1: j 1b\n"
);

static uint32_t mul_u32(uint32_t a, uint32_t b);

static uint32_t factorial(uint32_t n);

int main(void)
{
  volatile uint32_t *sig = SIGNATURE_BASE;

  uint32_t n = 6u;
  uint32_t res = 0;

  res = factorial(n);

  sig[0] = res;

  while (1) {
  }
}

static uint32_t mul_u32(uint32_t a, uint32_t b)
{
  uint32_t res = 0;
  while (b != 0u) {
    if ((b & 1u) != 0u) {
      res += a;
    }
    a <<= 1;
    b >>= 1;
  }
  return res;
}

static uint32_t factorial(uint32_t n)
{
  if (n <= 1u) {
    return 1u;
  }
  else {
    return mul_u32(n, factorial(n - 1u));
  }
}

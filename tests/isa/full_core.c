#include <stdint.h>

#define SIGNATURE_BASE ((volatile uint32_t *)0x20000100)

/* Placed in .rodata (text-region read): volatile prevents the compiler from
   constant-folding these at -Os, ensuring actual LW instructions are emitted
   that fetch from IMEM (where .rodata lives per the linker script). */
static const volatile uint32_t rodata_table[4] = {
  0xdeadc0deu, 0x12345678u, 0xabcdef01u, 0x0badcafeu
};

__asm__ (
  ".section .init\n"
  ".globl _start\n"
  "_start:\n"
  "  la sp, __stack_top\n"
  "  jal ra, main\n"
  "1: j 1b\n"
);

static uint32_t rotate_left(uint32_t val, unsigned sh)
{
  sh &= 31u;
  if (sh == 0u) {
    return val;
  }
  return (val << sh) | (val >> (32u - sh));
}

static uint32_t rotate_right(uint32_t val, unsigned sh)
{
  sh &= 31u;
  if (sh == 0u) {
    return val;
  }
  return (val >> sh) | (val << (32u - sh));
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

static int32_t mul_s32(int32_t a, int32_t b)
{
  uint32_t sign = 0;
  uint32_t ua = (uint32_t)a;
  uint32_t ub = (uint32_t)b;
  if (a < 0) {
    sign ^= 1u;
    ua = (~ua) + 1u;
  }
  if (b < 0) {
    sign ^= 1u;
    ub = (~ub) + 1u;
  }
  uint32_t mag = mul_u32(ua, ub);
  if (sign != 0u) {
    mag = (~mag) + 1u;
  }
  return (int32_t)mag;
}

static uint32_t helper(uint32_t base)
{
  uint32_t seed = 0xdeadbeefu ^ rotate_left(base, base & 7u);
  uint32_t mix = rotate_right(seed, base & 3u);
  return (mix + base) ^ (seed >> 5);
}

int main(void)
{
  volatile uint32_t *sig = SIGNATURE_BASE;

  uint32_t accum = 0;
  for (uint32_t i = 0; i < 32; ++i) {
    accum += (mul_u32(i, 3u)) ^ rotate_left(i, i & 7u);
  }

  int32_t signed_mix = 0;
  for (int32_t i = -8; i < 8; ++i) {
    if (i < 0) {
      signed_mix += mul_s32(i, 5);
    } else if (i == 0) {
      signed_mix ^= 0x13579bdf;
    } else {
      signed_mix -= mul_s32(i, 3);
    }
  }

  uint32_t logic = 0x12345678u;
  logic ^= 0x0f0f0f0fu;
  logic |= 0x00ff00ffu;
  logic &= 0xffff00ffu;
  logic = rotate_left(logic, 3);
  logic = rotate_right(logic, 5);

  uint8_t small_bytes[8] = {0x11u, 0x82u, 0xfcu, 0x7fu, 0x01u, 0x00u, 0x80u, 0xffu};
  uint16_t halfwords[4];
  for (uint32_t i = 0; i < 4; ++i) {
    uint32_t idx = i * 2u;
    halfwords[i] = (uint16_t)((uint16_t)small_bytes[idx] | ((uint16_t)small_bytes[idx + 1u] << 8));
  }

  int32_t signed_sum = 0;
  uint32_t unsigned_sum = 0;
  for (uint32_t i = 0; i < 4; ++i) {
    signed_sum += (int16_t)halfwords[i];
    unsigned_sum += halfwords[i];
  }

  uint32_t load_mix = 0;
  load_mix |= (uint32_t)small_bytes[1];
  load_mix <<= 8;
  load_mix |= (uint32_t)small_bytes[7];
  load_mix ^= (uint32_t)(uint16_t)halfwords[2];
  load_mix += (uint32_t)(uint16_t)halfwords[3];

  uint32_t store_buf[4] = {0};
  store_buf[0] = accum;
  ((uint16_t *)store_buf)[2] = (uint16_t)logic;
  ((uint8_t *)store_buf)[7] = (uint8_t)(logic >> 24);
  store_buf[2] = signed_sum;
  store_buf[3] = unsigned_sum;
  uint32_t store_hash = store_buf[0] ^ store_buf[1] ^ store_buf[2] ^ store_buf[3];

  uint32_t branch_acc = 0;
  for (uint32_t i = 1; i <= 12; ++i) {
    if ((i & 1u) == 0u) {
      branch_acc += mul_u32(i, i);
    } else if (i < 7u) {
      branch_acc ^= rotate_left(i, i);
    } else {
      branch_acc -= i;
    }
  }

  uint32_t helper_val = helper(branch_acc ^ accum);

  /* .rodata load: fold all four constant words into a single checksum.
     The compiler emits LW instructions that fetch from the text-region
     (.rodata lives in IMEM), exercising the read path through instruction
     memory for data loads. */
  uint32_t rodata_hash = 0;
  for (uint32_t i = 0; i < 4; ++i) {
    rodata_hash ^= rodata_table[i];
  }

  sig[0] = accum;
  sig[1] = (uint32_t)signed_mix;
  sig[2] = logic;
  sig[3] = (uint32_t)signed_sum;
  sig[4] = unsigned_sum;
  sig[5] = load_mix;
  sig[6] = store_hash;
  sig[7] = branch_acc;
  sig[8] = helper_val;
  sig[9] = rodata_hash;

  while (1) {
  }
}

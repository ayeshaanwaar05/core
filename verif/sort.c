// Copyright 2026 Maktab-e-Digital Systems Lahore.
// SPDX-License-Identifier: Apache-2.0
//
// sort.c -- sorting algorithms as a whole-core workload.
//
// Compiled with gcc -O2 -march=rv64i, so the core runs what a compiler emits:
// stack frames, recursion, calls and returns through ra, and every load and
// store width.  RV64I has no multiply or divide, so nothing here uses them
// (the data comes from xorshift, which is shifts and xors).
//
//   quicksort       int64_t,  recursive           ld / sd, signed compares
//   insertion sort  int64_t,  on a copy           ld / sd
//   shell sort      uint32_t                      lwu / sw, unsigned compares
//   bubble sort     int16_t                       lh / sh, sign extension
//   counting sort   uint8_t                       lbu / sb, histogram
//
// Each result is checked here (sorted, and the same multiset as the input via
// a checksum), and main() returns 0 only if every check holds; crt0.s turns
// that into the tohost write.  Independently, the testbench compares every
// retired instruction against spike, so a wrong answer is caught twice.

typedef long           int64_t;
typedef unsigned long  uint64_t;
typedef unsigned int   uint32_t;
typedef short          int16_t;
typedef unsigned char  uint8_t;

#define N 32

static int64_t  a64[N], b64[N];
static uint32_t a32[N];
static int16_t  a16[N];
static uint8_t  a8[N], c8[N];
static uint32_t hist[256];

static uint64_t rng = 0x9E3779B97F4A7C15ul;

static uint64_t xorshift(void) {
  rng ^= rng << 13;
  rng ^= rng >> 7;
  rng ^= rng << 17;
  return rng;
}

static void quicksort(int64_t *v, long lo, long hi) {
  while (lo < hi) {
    int64_t p = v[(lo + hi) >> 1];
    long i = lo, j = hi;
    while (i <= j) {
      while (v[i] < p) i++;
      while (v[j] > p) j--;
      if (i <= j) {
        int64_t t = v[i]; v[i] = v[j]; v[j] = t;
        i++; j--;
      }
    }
    // Recurse into the smaller half, loop on the larger: bounded stack.
    if (j - lo < hi - i) { quicksort(v, lo, j); lo = i; }
    else                 { quicksort(v, i, hi); hi = j; }
  }
}

static void insertion_sort(int64_t *v, long n) {
  for (long i = 1; i < n; i++) {
    int64_t x = v[i];
    long j = i - 1;
    while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; }
    v[j + 1] = x;
  }
}

static void shell_sort(uint32_t *v, long n) {
  for (long gap = n >> 1; gap > 0; gap >>= 1)
    for (long i = gap; i < n; i++) {
      uint32_t x = v[i];
      long j = i;
      while (j >= gap && v[j - gap] > x) { v[j] = v[j - gap]; j -= gap; }
      v[j] = x;
    }
}

static void bubble_sort(int16_t *v, long n) {
  for (long end = n - 1; end > 0; end--) {
    int swapped = 0;
    for (long i = 0; i < end; i++)
      if (v[i] > v[i + 1]) { int16_t t = v[i]; v[i] = v[i + 1]; v[i + 1] = t; swapped = 1; }
    if (!swapped) break;
  }
}

static void counting_sort(const uint8_t *in, uint8_t *out, long n) {
  for (long k = 0; k < 256; k++) hist[k] = 0;
  for (long i = 0; i < n; i++) hist[in[i]]++;
  long o = 0;
  for (long k = 0; k < 256; k++)
    for (uint32_t c = hist[k]; c != 0; c--) out[o++] = (uint8_t)k;
}

int main(void) {
  uint64_t s64 = 0, s32 = 0, s16 = 0, s8 = 0;
  for (long i = 0; i < N; i++) {
    uint64_t r = xorshift();
    // Narrow the range now and then so duplicates occur.
    a64[i] = (i & 3) == 0 ? (int64_t)(r & 7) - 4 : (int64_t)r;
    b64[i] = a64[i];
    a32[i] = (uint32_t)(r >> 17);
    a16[i] = (int16_t)(r >> 40);
    a8[i]  = (uint8_t)(r >> 3) & 0x3f;
    s64 += (uint64_t)a64[i];  s32 += a32[i];  s16 += (uint64_t)(long)a16[i];  s8 += a8[i];
  }

  quicksort(a64, 0, N - 1);
  insertion_sort(b64, N);
  shell_sort(a32, N);
  bubble_sort(a16, N);
  counting_sort(a8, c8, N);

  int bad = 0;
  uint64_t t64 = 0, t32 = 0, t16 = 0, t8 = 0;
  for (long i = 0; i < N; i++) {
    if (a64[i] != b64[i])                    bad |= 1;   // two algorithms agree
    if (i > 0 && a64[i - 1] > a64[i])        bad |= 2;
    if (i > 0 && a32[i - 1] > a32[i])        bad |= 4;
    if (i > 0 && a16[i - 1] > a16[i])        bad |= 8;
    if (i > 0 && c8[i - 1]  > c8[i])         bad |= 16;
    t64 += (uint64_t)a64[i];  t32 += a32[i];  t16 += (uint64_t)(long)a16[i];  t8 += c8[i];
  }
  if (t64 != s64 || t32 != s32 || t16 != s16 || t8 != s8) bad |= 32;  // nothing lost
  return bad;
}

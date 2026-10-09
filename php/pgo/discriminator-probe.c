/*
 * The probe behind php/pgo/discriminator-control.sh.
 *
 * php/build.sh proves a PGO build consumed its profile by looking for a .text.hot
 * section in the linked binary: clang only gives a function a hot/cold section
 * prefix when told it is hot, and with -ffunction-sections constant across every
 * build, an IR profile is the only thing that can. That claim is about the
 * toolchain, so it is measured on every build; this file is what it is measured
 * on.
 *
 * A profile only marks a function hot when it clears llvm's profile-summary
 * cutoff, so the probe needs one function that runs millions of times and a crowd
 * that never runs. Without the cold crowd only .text.unlikely appears and the
 * control would report a dead discriminator on a good toolchain.
 *
 * noinline throughout: an inlined function has no section of its own and the
 * probe would collapse into main.
 */
#include <stdio.h>
#include <stdlib.h>

static long acc = 0;

__attribute__((noinline)) long probe_hot(long x) { return (x * 3 + 1) ^ (x >> 2); }
__attribute__((noinline)) long probe_warm(long x) { return x + 7; }

#define PROBE_COLD(n) \
    __attribute__((noinline)) long probe_cold_##n(long x) { return x - (n); }
PROBE_COLD(0) PROBE_COLD(1) PROBE_COLD(2) PROBE_COLD(3) PROBE_COLD(4)
PROBE_COLD(5) PROBE_COLD(6) PROBE_COLD(7) PROBE_COLD(8) PROBE_COLD(9)

int main(int argc, char **argv)
{
    long n = (argc > 1) ? atol(argv[1]) : 2000000;
    for (long i = 0; i < n; i++) {
        acc += probe_hot(i);
    }
    acc += probe_warm(n);
    /* Unreachable in practice (argc is never 100). The calls keep the cold
     * functions from being dead-stripped, so the profile summary has something
     * to contrast the hot one against. */
    if (argc > 99) {
        acc += probe_cold_0(n) + probe_cold_1(n) + probe_cold_2(n)
             + probe_cold_3(n) + probe_cold_4(n) + probe_cold_5(n)
             + probe_cold_6(n) + probe_cold_7(n) + probe_cold_8(n)
             + probe_cold_9(n);
    }
    printf("%ld\n", acc);
    return 0;
}

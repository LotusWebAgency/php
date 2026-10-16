/* x86-64-v3 gate for the -v3 images' SAPI executables (php, php-fpm).
 *
 * A v3 build is compiled with -march=x86-64-v3 and dies with SIGILL, at some
 * arbitrary point, on a CPU without AVX2/BMI/FMA. This constructor runs before
 * main() and before any other constructor of the executable, checks the CPU,
 * and exits 127 with a message that names the fix instead.
 *
 * It does not rely on the loader: glibc's ld.so can refuse a binary through a
 * GNU property note, but gold and lld emit no PT_GNU_PROPERTY program header and
 * glibc 2.44 no longer reads the legacy PT_NOTE, so the note enforces nothing.
 *
 * This file is compiled WITHOUT the v3 -march (php/build.sh passes the baseline
 * flags), so the code that runs before the check is itself baseline code.
 * It is a separate native object linked into the program only, so neither PGO
 * nor LTO sees it: it cannot be inlined, specialized or dropped as unused, and
 * `used` keeps the symbol across a section GC. php/build.sh asserts the marker
 * string below is in every shipped v3 binary and in no baseline one;
 * tests/test-uarch.sh proves the refusal on an emulated CPU without AVX2.
 */
#include <unistd.h>

#define ISA_GATE_MESSAGE \
	"php: this build requires an x86-64-v3 CPU (AVX2, BMI1/2, FMA); this CPU does not support it. " \
	"Use the image tag without the -v3 suffix.\n"

__attribute__((constructor(101), used, noinline))
static void php_docker_isa_gate(void)
{
	/* libgcc's / compiler-rt's own priority-101 constructor may not have run yet. */
	__builtin_cpu_init();
	if (!__builtin_cpu_supports("x86-64-v3")) {
		static const char message[] = ISA_GATE_MESSAGE;
		ssize_t ignored = write(2, message, sizeof(message) - 1);
		(void)ignored;
		_exit(127);
	}
}

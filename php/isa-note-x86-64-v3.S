/* GNU property note: this executable needs x86-64-v3 (plus the baseline it
 * implies). glibc's ld.so reads GNU_PROPERTY_X86_ISA_1_NEEDED and refuses to
 * start the program on a CPU below that level ("CPU ISA level is lower than
 * required", exit 127) instead of letting it die later with SIGILL.
 *
 * Linked into the SAPI executables of the clang-built (ThinLTO) v3 images
 * only: neither clang nor lld can emit the note (lld ignores -z x86-64-v3 and
 * drops input .note.gnu.property sections, which is why this one carries a
 * different name). The gcc era gets it from -mneeded, see php/cflags.sh.
 *
 * lld emits no PT_GNU_PROPERTY program header for this section, so the
 * refusal depends on glibc's ld.so reading the property out of the legacy
 * PT_NOTE segment. trixie's glibc 2.41 does; a newer glibc may not, and then
 * runs the binary on any CPU. tests/test-uarch.sh proves the refusal at
 * runtime on the shipped image, which is what guards that.
 */
	.section .note.gnu.property.isa,"a",@note
	.p2align 3
	.long 4          /* namesz */
	.long 16         /* descsz */
	.long 5          /* NT_GNU_PROPERTY_TYPE_0 */
	.asciz "GNU"
	.p2align 3
	.long 0xc0008002 /* GNU_PROPERTY_X86_ISA_1_NEEDED */
	.long 4
	.long 0x5        /* x86-64-baseline | x86-64-v3 */
	.p2align 3

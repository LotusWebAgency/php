/*
 * chmod-sanitize: LD_PRELOAD shim that promotes chmod(path, 0) to a sane mode.
 *
 * Target: PrestaShop cache regeneration bug where invalidation chmod(file, 0000)
 * is not followed by a successful file replacement, leaving files unreadable
 * and causing 500 errors on every subsequent request.
 * Refs: PS GitHub issues #10998, #13050, #30786, #37666.
 *
 * Behavior: when any of chmod/fchmod/fchmodat is called with the permission
 * bits equal to 0, the call is rewritten to 0644 for regular files and 0755
 * for directories. Non-zero modes pass through untouched.
 *
 * This shim is only active when LD_PRELOAD points to the compiled .so.
 */

#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/types.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

#ifndef SANITIZE_FILE_MODE
#define SANITIZE_FILE_MODE 0644
#endif
#ifndef SANITIZE_DIR_MODE
#define SANITIZE_DIR_MODE 0755
#endif

#define PERM_MASK 07777

static int (*real_chmod)(const char *, mode_t) = NULL;
static int (*real_fchmod)(int, mode_t) = NULL;
static int (*real_fchmodat)(int, const char *, mode_t, int) = NULL;

static mode_t sanitize_path(const char *path)
{
    struct stat st;
    if (path && stat(path, &st) == 0 && S_ISDIR(st.st_mode)) {
        return SANITIZE_DIR_MODE;
    }
    return SANITIZE_FILE_MODE;
}

static mode_t sanitize_fd(int fd)
{
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISDIR(st.st_mode)) {
        return SANITIZE_DIR_MODE;
    }
    return SANITIZE_FILE_MODE;
}

int chmod(const char *path, mode_t mode)
{
    if (!real_chmod) real_chmod = dlsym(RTLD_NEXT, "chmod");
    if ((mode & PERM_MASK) == 0) mode = sanitize_path(path);
    return real_chmod(path, mode);
}

int fchmod(int fd, mode_t mode)
{
    if (!real_fchmod) real_fchmod = dlsym(RTLD_NEXT, "fchmod");
    if ((mode & PERM_MASK) == 0) mode = sanitize_fd(fd);
    return real_fchmod(fd, mode);
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    if (!real_fchmodat) real_fchmodat = dlsym(RTLD_NEXT, "fchmodat");
    if ((mode & PERM_MASK) == 0) {
        if (dirfd == AT_FDCWD) {
            mode = sanitize_path(path);
        } else {
            mode = SANITIZE_FILE_MODE;
        }
    }
    return real_fchmodat(dirfd, path, mode, flags);
}

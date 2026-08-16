// SPDX-License-Identifier: MIT
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

/*
 * Process-scoped discovery adapter for the tested fnOS Movies mediasrv 0.8.39.
 * It adapts only the synthetic GPU-P PCI/sysfs and DRM path discovery view.
 * It does not intercept CUDA, NVENC, dlsym, or capability results.
 *
 * Build with -DSRC_BDF and -DDST_BDF. The defaults are deliberately absent:
 * synthetic BDFs vary between Hyper-V guests and the destination identity must
 * be chosen after tracing the exact application version.
 */
#ifndef SRC_BDF
#error "compile with -DSRC_BDF=\"synthetic-bdf\""
#endif
#ifndef DST_BDF
#error "compile with -DDST_BDF=\"application-visible-bdf\""
#endif
#ifndef NVIDIA_DEVICE_ID
#error "compile with -DNVIDIA_DEVICE_ID=\"0x....\\n\""
#endif

#define SYS_SRC "/sys/bus/pci/devices/" SRC_BDF
#define SYS_DST "/sys/bus/pci/devices/" DST_BDF

static void audit(const char *fmt, ...) {
    char buffer[768];
    va_list args;
    va_start(args, fmt);
    int length = vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    if (length < 0) return;
    if (length > (int)sizeof(buffer) - 2) length = (int)sizeof(buffer) - 2;
    buffer[length++] = '\n';
    int fd = (int)syscall(SYS_openat, AT_FDCWD,
                          "/tmp/fnos-mediasrv-gpup-compat.log",
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                          0600);
    if (fd >= 0) {
        (void)syscall(SYS_write, fd, buffer, (size_t)length);
        (void)syscall(SYS_close, fd);
    }
}

static void *next_symbol(const char *name) {
    return dlvsym(RTLD_NEXT, name, "GLIBC_2.2.5");
}

static int is_pci_devices_dir(DIR *dir) {
    char link[64], path[256];
    (void)snprintf(link, sizeof(link), "/proc/self/fd/%d", dirfd(dir));
    ssize_t length = syscall(SYS_readlinkat, AT_FDCWD, link, path,
                             sizeof(path) - 1);
    if (length < 0) return 0;
    path[length] = 0;
    return strcmp(path, "/sys/bus/pci/devices") == 0;
}

struct dirent *readdir(DIR *dir) {
    static struct dirent *(*real_readdir)(DIR *);
    if (!real_readdir) real_readdir = next_symbol("readdir");
    struct dirent *entry = real_readdir(dir);
    if (entry && strcmp(entry->d_name, SRC_BDF) == 0 &&
        is_pci_devices_dir(dir)) {
        /* Build-time validation requires DST_BDF to be no longer than SRC_BDF,
         * so this in-place rename cannot enlarge libc's variable dirent record. */
        memcpy(entry->d_name, DST_BDF, sizeof(DST_BDF));
        audit("readdir %s -> %s", SRC_BDF, DST_BDF);
    }
    return entry;
}

struct dirent64 *readdir64(DIR *dir) {
    static struct dirent64 *(*real_readdir64)(DIR *);
    if (!real_readdir64) real_readdir64 = next_symbol("readdir64");
    struct dirent64 *entry = real_readdir64(dir);
    if (entry && strcmp(entry->d_name, SRC_BDF) == 0 &&
        is_pci_devices_dir(dir)) {
        memcpy(entry->d_name, DST_BDF, sizeof(DST_BDF));
        audit("readdir64 %s -> %s", SRC_BDF, DST_BDF);
    }
    return entry;
}

static int identity_fd(const char *path) {
    const char *value = NULL;
    if (strcmp(path, SYS_DST "/vendor") == 0) value = "0x10de\n";
    else if (strcmp(path, SYS_DST "/device") == 0) value = NVIDIA_DEVICE_ID;
    if (!value) return -1;
    int fd = (int)syscall(SYS_memfd_create, "fnos-mediasrv-pci",
                          MFD_CLOEXEC);
    if (fd < 0) return -1;
    (void)syscall(SYS_write, fd, value, strlen(value));
    (void)syscall(SYS_lseek, fd, 0, SEEK_SET);
    audit("identity %s", path);
    return fd;
}

static const char *redirect_sysfs(const char *path, char output[512]) {
    size_t prefix_length = sizeof(SYS_DST) - 1;
    if (strncmp(path, SYS_DST, prefix_length) != 0) return path;
    (void)snprintf(output, 512, "%s%s", SYS_SRC, path + prefix_length);
    return output;
}

static int open_common(const char *path, int flags, mode_t mode,
                       int use_open64) {
    static int (*real_open)(const char *, int, ...);
    static int (*real_open64)(const char *, int, ...);
    if (!real_open) real_open = next_symbol("open");
    if (!real_open64) real_open64 = next_symbol("open64");
    if ((flags & O_ACCMODE) == O_RDONLY) {
        int fd = identity_fd(path);
        if (fd >= 0) return fd;
    }
    char redirected[512];
    const char *effective = redirect_sysfs(path, redirected);
    if (flags & O_CREAT)
        return use_open64 ? real_open64(effective, flags, mode)
                          : real_open(effective, flags, mode);
    return use_open64 ? real_open64(effective, flags)
                      : real_open(effective, flags);
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    return open_common(path, flags, mode, 0);
}

int open64(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    return open_common(path, flags, mode, 1);
}

int access(const char *path, int mode) {
    static int (*real_access)(const char *, int);
    if (!real_access) real_access = next_symbol("access");
    if (mode == F_OK && strcmp(path, "/dev/dri") == 0) {
        audit("access /dev/dri -> present");
        return 0;
    }
    return real_access(path, mode);
}

char *realpath(const char *path, char *resolved) {
    static char *(*real_realpath)(const char *, char *);
    if (!real_realpath) real_realpath = next_symbol("realpath");
    if (resolved &&
        (strcmp(path, "/dev/dri/by-path/pci-" DST_BDF "-card") == 0 ||
         strcmp(path, "/dev/dri/by-path/pci-" DST_BDF "-render") == 0)) {
        strcpy(resolved, "/dev/dxg");
        audit("realpath %s -> /dev/dxg", path);
        return resolved;
    }
    return real_realpath(path, resolved);
}

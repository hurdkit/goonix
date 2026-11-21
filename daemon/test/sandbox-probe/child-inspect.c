/* GNU Guix --- Functional package management for GNU
   This file is part of GNU Guix.
   GNU Guix is free software: you can redistribute it and/or modify it under
   the terms of the GNU General Public License as published by the Free
   Software Foundation, either version 3 of the License, or (at your option)
   any later version. */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <unistd.h>

static void print_bytes(const char *label, const char *value)
{
    fputs(label, stdout);
    if (value != NULL) fwrite(value, 1, strlen(value), stdout);
    fputc('\n', stdout);
}

static void print_map(const char *name)
{
    char path[64];
    unsigned long inside, outside, length;
    int fd;
    snprintf(path, sizeof(path), "/proc/self/%s", name);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    {
        FILE *stream = fdopen(fd, "r");
        if (stream == NULL) {
            close(fd);
            return;
        }
        if (fscanf(stream, "%lu %lu %lu", &inside, &outside, &length) == 3)
            printf("%s=%lu %lu %lu\n", name, inside, outside, length);
        fclose(stream);
    }
}

int main(int argc, char **argv)
{
    char *cwd;
    int extra = 0;
    int fd;
    char input[128];
    ssize_t count;

    printf("argc=%d\n", argc);
    for (fd = 1; fd < argc; ++fd) {
        printf("arg%d=", fd);
        fwrite(argv[fd], 1, strlen(argv[fd]), stdout);
        fputc('\n', stdout);
    }
    print_bytes("env=", getenv("P2_VALUE"));
    cwd = getcwd(NULL, 0);
    if (cwd == NULL) return 2;
    print_bytes("cwd=", cwd);
    free(cwd);
    printf("uid=%lu euid=%lu gid=%lu egid=%lu\n",
           (unsigned long) getuid(), (unsigned long) geteuid(),
           (unsigned long) getgid(), (unsigned long) getegid());
    printf("session-is-leader=%d\n", getsid(0) == getpid());
    printf("no-new-privs=%d\n", prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0));
    for (fd = 3; fd < 64; ++fd)
        if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) ++extra;
    printf("extra-fds=%d\n", extra);
    count = read(STDIN_FILENO, input, sizeof(input) - 1);
    if (count < 0) return 3;
    input[count] = '\0';
    print_bytes("stdin=", input);
    print_map("uid_map");
    print_map("gid_map");
    puts("namespace-ready=1");
    return ferror(stdout) ? 4 : 0;
}

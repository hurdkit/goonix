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
#include <sched.h>
#include <spawn.h>
#include <unistd.h>

/* This wrapper is the entire spawn boundary used by the Haskell probe.
   posix_spawn performs the fork/exec mechanics; no Haskell action is passed
   to a child. */
int p2_posix_spawn(const char *path, char *const argv[], char *const envp[],
                   pid_t *pid, int inputFd, int outputFd, int errorFd)
{
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) return result;

    if (inputFd >= 0 && inputFd != STDIN_FILENO) {
        result = posix_spawn_file_actions_adddup2(&actions, inputFd, STDIN_FILENO);
        if (result == 0 && inputFd > STDERR_FILENO)
            result = posix_spawn_file_actions_addclose(&actions, inputFd);
    }
    if (result == 0 && outputFd >= 0 && outputFd != STDOUT_FILENO) {
        result = posix_spawn_file_actions_adddup2(&actions, outputFd, STDOUT_FILENO);
        if (result == 0 && outputFd > STDERR_FILENO)
            result = posix_spawn_file_actions_addclose(&actions, outputFd);
    }
    if (result == 0 && errorFd >= 0 && errorFd != STDERR_FILENO) {
        result = posix_spawn_file_actions_adddup2(&actions, errorFd, STDERR_FILENO);
        if (result == 0 && errorFd > STDERR_FILENO)
            result = posix_spawn_file_actions_addclose(&actions, errorFd);
    }
    if (result == 0)
        result = posix_spawn(pid, path, &actions, NULL, argv, envp);
    {
        int saved = errno;
        posix_spawn_file_actions_destroy(&actions);
        errno = saved;
    }
    return result;
}

/* Return errno instead of changing the process's error handling.  EINVAL is
   the expected result when this is called by a multithreaded process. */
int p2_unshare_user(void)
{
    if (unshare(CLONE_NEWUSER) == -1) return errno;
    return 0;
}

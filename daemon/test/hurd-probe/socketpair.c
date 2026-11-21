/* GNU Guix --- Functional package management for GNU
   This file is part of GNU Guix.
   GNU Guix is free software: you can redistribute it and/or modify it under
   the terms of the GNU General Public License as published by the Free
   Software Foundation, either version 3 of the License, or (at your option)
   any later version.  */

/* HS-9 probe helper: a Unix-domain socketpair for the poll-on-a-socket check.
   The Hurd supports AF_UNIX socketpair; this is the same socket family the
   daemon listens on.  */
#include <sys/socket.h>

int hs9_socketpair(int fds[2]) {
    return socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
}
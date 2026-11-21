/* GNU Guix --- Functional package management for GNU
   GPL-3.0-or-later; see COPYING. */

#include "archive.hh"
#include "serialise.hh"
#include <cstdio>
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: dump-nar PATH OUTPUT\n");
        return 2;
    }
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0444);
    if (fd == -1) {
        perror("creating vector");
        return 1;
    }
    try {
        nix::FdSink sink(fd);
        nix::dumpPath(argv[1], sink);
        sink.flush();
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s\n", e.what());
        close(fd);
        return 1;
    }
    return close(fd) == 0 ? 0 : 1;
}

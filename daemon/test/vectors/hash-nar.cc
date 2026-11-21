/* GNU Guix --- Functional package management for GNU
   GPL-3.0-or-later; see COPYING. */

#include "archive.hh"
#include "hash.hh"
#include "util.hh"
#include <cstdio>
#include <string>

int main(int argc, char **argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: hash-nar STORE OUTPUT\n");
        return 2;
    }
    try {
        std::string store(argv[1]);
        FILE *out = std::fopen(argv[2], "wbx");
        if (!out) {
            std::perror("creating NAR hash manifest");
            return 1;
        }
        for (auto &entry : nix::readDirectory(store)) {
            auto const &name = entry.name;
            if (name.size() < 34 || name.ends_with(".drv") ||
                name.ends_with(".lock") || name.ends_with(".chroot") ||
                std::string("0123456789abcdfghijklmnpqrsvwxyz").find(name[0]) == std::string::npos)
                continue;
            nix::HashSink sink(nix::htSHA256);
            nix::dumpPath(store + "/" + name, sink);
            auto result = sink.finish();
            std::fprintf(out, "%s\t%s\t%s\t%llu\n", name.c_str(),
                nix::printHash32(result.first).c_str(),
                nix::printHash(result.first).c_str(), result.second);
            if (std::ferror(out)) {
                std::fclose(out);
                return 1;
            }
        }
        return std::fclose(out) == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s\n", e.what());
        return 1;
    }
}

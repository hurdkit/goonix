/* GNU Guix --- Functional package management for GNU
   GPL-3.0-or-later; see COPYING. */

#include "util.hh"
#include <cstdio>
#include <map>
#include <string>
#include <sys/stat.h>

static void inspect(const std::string &path, std::map<std::string, std::string> &seen) {
    struct stat st;
    if (lstat(path.c_str(), &st)) return;
    if (S_ISREG(st.st_mode)) {
        auto kind = std::string(st.st_size == 0 ? "empty-file" :
            st.st_size > 32768 ? "large-file" :
            st.st_mode & S_IXUSR ? "executable" : "regular");
        seen.emplace(kind, path);
    } else if (S_ISLNK(st.st_mode)) {
        seen.emplace("symlink", path);
    } else if (S_ISDIR(st.st_mode)) {
        auto entries = nix::readDirectory(path);
        if (entries.empty()) seen.emplace("empty-directory", path);
        else seen.emplace("directory", path);
        for (auto const &entry : entries) {
            if (entry.name.find("~nix~case~hack~") != std::string::npos)
                seen.emplace("case-hack", entry.name);
            inspect(path + "/" + entry.name, seen);
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 3) {
        std::fprintf(stderr, "usage: inspect-item STORE OUTPUT\n");
        return 2;
    }
    try {
        std::string store(argv[1]);
        FILE *out = std::fopen(argv[2], "wbx");
        if (!out) return 1;
        std::map<std::string, std::string> seen;
        for (auto const &entry : nix::readDirectory(store)) {
            auto const &name = entry.name;
            if (name.size() < 34 || name.ends_with(".drv") ||
                name.ends_with(".lock") ||
                name.ends_with(".chroot") ||
                std::string("0123456789abcdfghijklmnpqrsvwxyz").find(name[0]) == std::string::npos)
                continue;
            std::map<std::string, std::string> itemSeen;
            inspect(store + "/" + name, itemSeen);
            for (auto const &[kind, path] : itemSeen)
                seen.emplace(kind, name + "\t" + path);
        }
        for (auto const &[kind, path] : seen)
            std::fprintf(out, "%s\t%s\n", kind.c_str(), path.c_str());
        return std::fclose(out) == 0 ? 0 : 1;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s\n", e.what());
        return 1;
    }
}

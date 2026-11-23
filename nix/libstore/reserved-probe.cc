// goonix: probe the REAL C++ reserved-placeholder scan (checkReservedTree /
// checkReservedFile), so the Haskell port can be compared against measured
// behaviour at the read-boundary cases, which are the subtle ones.
#include "ca.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <sys/stat.h>

namespace nix {
void checkReservedTreeForTest(const Path & path);
}

using namespace nix;

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: reserved-probe DIR\n"; return 2; }
    Path base = argv[1];
    // A reserved (token-alphabet) hash part: 32 chars from "eout", starting 'e'.
    std::string token = "e" + std::string(31, 't');
    // 't' is in the reserved alphabet, so this is a valid reserved hash part.
    std::string placeholder = token + "-name";

    auto report = [&](const char * label, const Path & dir) {
        std::string outcome = "ok";
        try { checkReservedTreeForTest(dir); }
        catch (std::exception & e) { outcome = "threw"; }
        std::cout << std::format("{} {}\n", label, outcome);
    };

    /* 1. Placeholder wholly inside one chunk. */
    {
        Path d = base + "/whole"; createDirs(d);
        writeFile(d + "/f", "prefix" + placeholder + "suffix");
        report("whole-chunk", d);
    }
    /* 2. Placeholder split across the 128KiB read boundary at every offset
          around it: the retained tail must catch all of them. */
    for (int split : {1, 16, 31, 32, 33}) {
        Path d = base + "/split" + std::to_string(split); createDirs(d);
        size_t pad = 128 * 1024 - (size_t) split;
        std::string contents(pad, 'x');
        contents += placeholder;
        writeFile(d + "/f", contents);
        report(("split-" + std::to_string(split)).c_str(), d);
    }
    /* 3. In a FILE NAME. */
    {
        Path d = base + "/name"; createDirs(d);
        writeFile(d + "/" + placeholder, "x");
        report("in-name", d);
    }
    /* 4. In a SYMLINK TARGET. */
    {
        Path d = base + "/link"; createDirs(d);
        createSymlink("/gnu/store/" + placeholder, d + "/l");
        report("in-symlink", d);
    }
    /* 5. A 32-char reserved run with NO trailing '-': not a placeholder. */
    {
        Path d = base + "/no-dash"; createDirs(d);
        writeFile(d + "/f", token + "x");
        report("no-dash", d);
    }
    /* 6. The nuke-refs marker (32 'e') is EXEMPT. */
    {
        Path d = base + "/nuke"; createDirs(d);
        writeFile(d + "/f", std::string(32, 'e') + "-name");
        report("nuke-marker", d);
    }
    /* 7. A base32 (non-reserved) hash: not scanned by this predicate. */
    {
        Path d = base + "/base32"; createDirs(d);
        writeFile(d + "/f", std::string(32, 'a') + "-name");
        report("base32-hash", d);
    }
    return 0;
}
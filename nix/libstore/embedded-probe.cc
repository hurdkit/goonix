// goonix: drive the REAL C++ materialiseGoonixFiles (build-ca.cc) over embedded
// builder-file NAMES, so the Haskell port's validation can be compared against
// measured behaviour rather than a model of std::getline.
//
// The interesting case is a TRAILING slash: getline does not yield a final empty
// field, so "a/" has components {"a"} and is ACCEPTED, while a split that keeps
// the trailing empty rejects it.
#include "build-ca.hh"
#include "derivations.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <vector>

using namespace nix;

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: embedded-probe DIR\n"; return 2; }
    Path dir = argv[1];
    createDirs(dir);

    const std::vector<std::string> names = {
        "a", "a/b", "a/", "a//b", "/a", "", "a/./b", "a/../b", "./a",
        "..", "a\\b", "a/b/", "a/.", "a/..", "/", "a///", ".hidden",
        "a/b/c", "x/", "a//", "//a"
    };

    for (const auto & name : names) {
        Derivation drv;
        drv.env["__files"] = name;
        // A value is present, so a rejection can only come from the NAME check.
        drv.env["__file:" + name] = "content";
        Strings args = { "$NIX_BUILD_TOP/" + name };
        Path host = dir + "/host-" + std::to_string(&name - &names[0]);
        Path sandbox = "/build";
        createDirs(host);
        std::string verdict;
        try {
            materialiseGoonixFiles(drv, args, host, sandbox);
            verdict = "OK";
        } catch (std::exception & e) {
            verdict = std::string("ERROR ") + e.what();
        }
        // Quote the name so an empty one is visible.
        std::cout << std::format("name=\"{}\" {}\n", name, verdict);
    }
    return 0;
}
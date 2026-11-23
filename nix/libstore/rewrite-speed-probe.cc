// goonix: time the C++ forward rewrite on ONE large regular file that holds no
// occurrence of FROM.  The Haskell side runs the same file through rewriteTree
// (daemon/test/rewrite-speed/Main.hs); the two times are quoted in the commit.
#include "ca.hh"
#include "globals.hh"
#include "util.hh"
#include <chrono>
#include <iostream>
#include <format>
#include <string>

namespace nix {
void checkRewriteForTest(const Path & path, const string & from, const string & to);
}

using namespace nix;

static const string FROM = "teouteouteouteouteouteouteouteot";
static const string TO = "0123456789abcdfghijklmnpqrsvwxyz";

int main(int argc, char ** argv)
{
    if (argc != 3) { std::cerr << "usage: rewrite-speed-probe DIR BYTES\n"; return 2; }
    Path base = argv[1];
    size_t size = std::stoul(argv[2]);
    createDirs(base);
    settings.nixStore = base;
    Path file = base + "/big";
    /* 'x' never appears in FROM, so there is no occurrence and no rejection:
       this measures the SEARCH cost, which is what the byte-by-byte loop pays. */
    writeFile(file, string(size, 'x'));
    auto start = std::chrono::steady_clock::now();
    checkRewriteForTest(file, FROM, TO);
    auto end = std::chrono::steady_clock::now();
    double seconds = std::chrono::duration<double>(end - start).count();
    std::cout << std::format("CXX_REWRITE_SECONDS {:.3f} bytes={}\n", seconds, size);
    return 0;
}
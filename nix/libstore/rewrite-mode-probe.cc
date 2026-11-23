// goonix: probe the REAL C++ rewriteRegularFile mode handling, so the Haskell
// port can be compared against measured C++ behaviour rather than a reading of
// the source.  Uses rewriteTreeForTest (nix/libstore/ca.cc), the same hook the
// --symlink-modes case uses.
//
// Prints one line per fixture: the input mode, the mode after the rewrite, and
// the outcome.  daemon/test/rewrite-mode.sh runs the same fixtures through the
// Haskell rewriteTree and diffs the two.
#include "ca.hh"
#include "local-store.hh"
#include "globals.hh"
#include <iostream>
#include <format>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

namespace nix {
void rewriteTreeForTest(const Path & path, const string & from, const string & to);
}

using namespace nix;

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: rewrite-mode-probe DIR\n"; return 2; }
    Path base = argv[1];
    std::string token(32, 't'), replacement(32, 'u');

    // Modes a build output can plausibly carry.  0200/0222/0000 have NO read
    // bit; 0755/0555 are executable; 0644/0444/0600 are the ordinary cases.
    for (mode_t m : {(mode_t)0200, (mode_t)0222, (mode_t)0000, (mode_t)0644,
                     (mode_t)0444, (mode_t)0755, (mode_t)0555, (mode_t)0600}) {
        Path dir = base + "/m" + std::to_string(m);
        createDirs(dir);
        Path file = dir + "/payload";
        writeFile(file, "/gnu/store/" + token + "-x/data\n");
        if (chmod(file.c_str(), m)) throw SysError("chmod fixture");
        struct stat before;
        lstat(file.c_str(), &before);
        std::string outcome = "ok";
        try {
            rewriteTreeForTest(dir, token, replacement);
        } catch (std::exception & e) {
            outcome = std::string("threw: ") + e.what();
        }
        struct stat after;
        mode_t afterMode = 0;
        bool present = lstat(file.c_str(), &after) == 0;
        if (present) afterMode = after.st_mode & 07777;
        chmod(dir.c_str(), 0755);
        if (present) chmod(file.c_str(), 0644);
        std::cout << std::format("mode={:04o} before={:04o} after={:04o} present={} {}\n",
            (unsigned) m, (unsigned) (before.st_mode & 07777),
            (unsigned) afterMode, present ? 1 : 0, outcome);
    }

    /* The case where the ORIGINAL inode's mode matters: a hard-linked twin
       OUTSIDE the rewritten tree (the store's .links dedup pool, or another
       store item).  rewriteRegularFile replaces the rewritten path with a NEW
       inode, so the twin keeps the ORIGINAL one - and whatever mode the rewrite
       left on it.  C++ only adds S_IRUSR when missing and never clears a bit; a
       port that chmods 0600 strips the twin's executable bit. */
    {
        Path dir = base + "/hardlink";
        Path outside = base + "/outside";
        createDirs(dir);
        createDirs(outside);
        Path file = dir + "/payload", twin = outside + "/twin";
        writeFile(file, "/gnu/store/" + token + "-x/data\n");
        chmod(file.c_str(), 0555);
        if (link(file.c_str(), twin.c_str())) throw SysError("linking twin");
        std::string outcome = "ok";
        try { rewriteTreeForTest(dir, token, replacement); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        struct stat t;
        lstat(twin.c_str(), &t);
        chmod(dir.c_str(), 0755); chmod(outside.c_str(), 0755);
        chmod(file.c_str(), 0644); chmod(twin.c_str(), 0644);
        std::cout << std::format("hardlink-twin after={:04o} {}\n",
            (unsigned) (t.st_mode & 07777), outcome);
    }

    /* The FAILURE path: an opaque fragment makes the rewrite throw.  The
       original file must be left as C++ leaves it - readable, no bit cleared -
       not clobbered to 0600. */
    {
        Path dir = base + "/refused";
        createDirs(dir);
        Path file = dir + "/payload";
        std::string contents(128 * 1024 - 31, 'x');
        contents += token.substr(0, 1);
        contents += token.substr(1, 7);
        contents += "tail";
        writeFile(file, contents);
        chmod(file.c_str(), 0555);
        std::string outcome = "ok";
        try { rewriteTreeForTest(dir, token, token); }
        catch (std::exception & e) { outcome = "threw"; }
        struct stat a;
        lstat(file.c_str(), &a);
        chmod(dir.c_str(), 0755); chmod(file.c_str(), 0644);
        std::cout << std::format("refused-original after={:04o} {}\n",
            (unsigned) (a.st_mode & 07777), outcome);
    }
    return 0;
}
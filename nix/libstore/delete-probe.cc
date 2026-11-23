// goonix: probe the REAL C++ deletePath, so the Haskell deleteTree can be
// compared against measured behaviour.  The observable that matters is what
// happens to a HARD-LINKED TWIN outside the deleted tree (the .links dedup
// pool), and to the parent directory's mode.
#include "util.hh"
#include "globals.hh"
#include <iostream>
#include <format>
#include <sys/stat.h>
#include <unistd.h>

using namespace nix;

static unsigned modeOf(const Path & p)
{
    struct stat st;
    if (lstat(p.c_str(), &st)) return 0xFFFF;
    return (unsigned) (st.st_mode & 07777);
}

static unsigned linksOf(const Path & p)
{
    struct stat st;
    if (lstat(p.c_str(), &st)) return 0xFFFF;
    return (unsigned) st.st_nlink;
}

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: delete-probe DIR\n"; return 2; }
    Path base = argv[1];

    /* 1. Deleting a tree whose files are hard-linked to a twin OUTSIDE it: the
          twin's MODE must be untouched (C++ never chmods the file it unlinks;
          see 00a5faa26db) and its link count drops by one. */
    {
        Path tree = base + "/tree1", outside = base + "/outside1";
        createDirs(tree); createDirs(outside);
        Path file = tree + "/f", twin = outside + "/twin";
        writeFile(file, std::string(9000, 'a'));
        chmod(file.c_str(), 0555);
        if (link(file.c_str(), twin.c_str())) throw SysError("link twin");
        chmod(tree.c_str(), 0555);
        chmod(outside.c_str(), 0555);
        std::string outcome = "ok";
        try { deletePath(tree); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("delete-hardlink twin-mode={:04o} twin-nlink={} tree-gone={} {}\n",
            modeOf(twin), linksOf(twin), pathExists(tree) ? 0 : 1, outcome);
        chmod(outside.c_str(), 0755);
    }

    /* 2. A read-only PARENT directory: C++ makes it writable to unlink, and
          does NOT restore the mode afterwards (the parent is left writable). */
    {
        Path parent = base + "/parent2";
        createDirs(parent);
        Path file = parent + "/f";
        writeFile(file, "x");
        chmod(file.c_str(), 0444);
        chmod(parent.c_str(), 0555);
        std::string outcome = "ok";
        try { deletePath(file); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("delete-readonly-parent parent-mode={:04o} file-gone={} {}\n",
            modeOf(parent), pathExists(file) ? 0 : 1, outcome);
        chmod(parent.c_str(), 0755);
    }

    /* 3. A read-only DIRECTORY tree with read-only subdirectories: the whole
          tree must go, and a twin outside keeps its mode. */
    {
        Path tree = base + "/tree3", outside = base + "/outside3";
        createDirs(tree + "/sub"); createDirs(outside);
        Path file = tree + "/sub/f", twin = outside + "/twin";
        writeFile(file, std::string(9000, 'b'));
        chmod(file.c_str(), 0444);
        if (link(file.c_str(), twin.c_str())) throw SysError("link twin 3");
        chmod((tree + "/sub").c_str(), 0555);
        chmod(tree.c_str(), 0555);
        chmod(outside.c_str(), 0555);
        std::string outcome = "ok";
        try { deletePath(tree); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("delete-nested twin-mode={:04o} twin-nlink={} tree-gone={} {}\n",
            modeOf(twin), linksOf(twin), pathExists(tree) ? 0 : 1, outcome);
        chmod(outside.c_str(), 0755);
    }

    /* 4. Deleting a SYMLINK must not follow it: the target survives with its
          mode intact. */
    {
        Path tree = base + "/tree4", outside = base + "/outside4";
        createDirs(tree); createDirs(outside);
        Path target = outside + "/target";
        writeFile(target, std::string(9000, 'c'));
        chmod(target.c_str(), 0555);
        createSymlink(target, tree + "/link");
        chmod(tree.c_str(), 0555);
        chmod(outside.c_str(), 0555);
        std::string outcome = "ok";
        try { deletePath(tree); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("delete-symlink target-mode={:04o} target-alive={} tree-gone={} {}\n",
            modeOf(target), pathExists(target) ? 1 : 0, pathExists(tree) ? 0 : 1, outcome);
        chmod(outside.c_str(), 0755);
    }
    return 0;
}
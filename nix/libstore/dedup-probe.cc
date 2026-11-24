// goonix: probe the REAL C++ dedup (.links pool) mutation path, so the Haskell
// port can be compared against measured behaviour.  Calls
// LocalStore::optimisePath, the same entry the daemon's auto-optimise uses.
//
// Prints one line per fixture.  daemon/test/dedup-mode.sh runs the identical
// fixtures through the Haskell deduplicateTree and diffs the two.
#include "local-store.hh"
#include "globals.hh"
#include "ca.hh"
#include <iostream>
#include <format>
#include <sys/stat.h>
#include <fcntl.h>
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

static ino_t inodeOf(const Path & p)
{
    struct stat st;
    if (lstat(p.c_str(), &st)) return 0;
    return st.st_ino;
}

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: dedup-probe DIR\n"; return 2; }
    Path base = argv[1];
    Path store = base + "/store";
    createDirs(store);
    chmod(store.c_str(), 0755);
    // As ca-test's configureIsolatedStore: every state path inside the scratch,
    // so LocalStore does not touch the host's /profiles or /var/guix.
    settings.nixStateDir = base + "/state";
    settings.nixStore = store;
    settings.nixDBPath = base + "/db";
    settings.nixConfDir = base + "/etc";
    settings.nixLogDir = base + "/log";
    settings.nixDaemonSocketFile = base + "/socket";
    settings.buildUsersGroup = "";
    settings.autoOptimiseStore = true;
    createDirs(settings.nixStateDir);
    createDirs(settings.nixConfDir);
    createDirs(settings.nixLogDir);
    Path links = store + "/.links";
    createDirs(links);

    // A payload big enough to exceed deduplicationMinSize (8192).
    std::string big(9000, 'a');
    std::string small(100, 'a');

    /* 1. Two identical large files in DIFFERENT store items: the second must
          become a hard link of the first, and the directory modes must be
          restored. */
    {
        Path a = store + "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-item-a";
        Path b = store + "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-item-b";
        createDirs(a); createDirs(b);
        writeFile(a + "/f", big); writeFile(b + "/f", big);
        chmod((a + "/f").c_str(), 0444); chmod((b + "/f").c_str(), 0444);
        chmod(a.c_str(), 0555); chmod(b.c_str(), 0555);
        LocalStore s(false);
        std::string outcome = "ok";
        try { s.optimisePath(a + "/f"); s.optimisePath(b + "/f"); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("dedup-pair same-inode={} b-mode={:04o} b-dir={:04o} b-nlink={} {}\n",
            inodeOf(a + "/f") == inodeOf(b + "/f") ? 1 : 0,
            modeOf(b + "/f"), modeOf(b), linksOf(b + "/f"), outcome);
        chmod(a.c_str(), 0755); chmod(b.c_str(), 0755);
    }

    /* 2. A WRITABLE file must be SKIPPED ("suspicious writable file"), not
          linked and not chmod'd. */
    {
        Path c = store + "/cccccccccccccccccccccccccccccccc-item-c";
        createDirs(c);
        writeFile(c + "/f", big);
        chmod((c + "/f").c_str(), 0644);
        chmod(c.c_str(), 0555);
        LocalStore s(false);
        std::string outcome = "ok";
        try { s.optimisePath(c + "/f"); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("writable-skip mode={:04o} nlink={} {}\n",
            modeOf(c + "/f"), linksOf(c + "/f"), outcome);
        chmod(c.c_str(), 0755);
    }

    /* 3. BELOW the size threshold: skipped entirely. */
    {
        Path d = store + "/dddddddddddddddddddddddddddddddd-item-d";
        createDirs(d);
        writeFile(d + "/f", small);
        chmod((d + "/f").c_str(), 0444);
        chmod(d.c_str(), 0555);
        LocalStore s(false);
        std::string outcome = "ok";
        try { s.optimisePath(d + "/f"); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("below-threshold nlink={} {}\n", linksOf(d + "/f"), outcome);
        chmod(d.c_str(), 0755);
    }

    /* 4. An EXECUTABLE large file: the NAR hash includes the exec bit, so it
          must NOT link with the non-executable payload of fixture 1. */
    {
        Path e = store + "/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-item-e";
        createDirs(e);
        writeFile(e + "/f", big);
        chmod((e + "/f").c_str(), 0555);
        chmod(e.c_str(), 0555);
        LocalStore s(false);
        std::string outcome = "ok";
        try { s.optimisePath(e + "/f"); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("exec-not-linked distinct-inode={} mode={:04o} {}\n",
            inodeOf(e + "/f") != inodeOf(store + "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-item-a/f") ? 1 : 0,
            modeOf(e + "/f"), outcome);
        chmod(e.c_str(), 0755);
    }

    /* 5. A CORRUPTED .links entry: same name, DIFFERENT size.  C++ removes the
          corrupted link and retries. */
    {
        Path f = store + "/ffffffffffffffffffffffffffffffff-item-f";
        createDirs(f);
        std::string other(9000, 'z');
        writeFile(f + "/f", other);
        chmod((f + "/f").c_str(), 0444);
        chmod(f.c_str(), 0555);
        LocalStore s(false);
        std::string outcome = "ok";
        try { s.optimisePath(f + "/f"); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("fresh-hash nlink={} {}\n", linksOf(f + "/f"), outcome);
        chmod(f.c_str(), 0755);
    }
    return 0;
}
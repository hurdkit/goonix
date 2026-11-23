// goonix: probe the REAL C++ addIndirectRoot (GC root naming + symlink), so the
// Haskell port can be compared against measured behaviour.  The root NAME is
// printHash32(SHA1(path)) - a truncation, not a fold - and the symlink is
// created atomically through a temporary.
#include "local-store.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <sys/stat.h>
#include <dirent.h>
#include <algorithm>
#include <vector>

using namespace nix;

int main(int argc, char ** argv)
{
    if (argc != 3) { std::cerr << "usage: gcroot-probe DIR STORE-PATH\n"; return 2; }
    /* The GC root NAME is SHA1 of the target PATH, so both lanes must name
       the SAME path string or the names cannot be compared.  The files
       live in this lane's scratch store; STORE-PATH is the shared name. */
    Path namedStore = argv[2];
    Path base = argv[1];
    settings.nixStateDir = base + "/state";
    settings.nixStore = base + "/store";
    settings.nixDBPath = base + "/db";
    settings.nixConfDir = base + "/etc";
    settings.nixLogDir = base + "/log";
    settings.nixDaemonSocketFile = base + "/socket";
    settings.buildUsersGroup = "";
    createDirs(settings.nixStore);
    createDirs(settings.nixStateDir);
    createDirs(settings.nixConfDir);
    createDirs(settings.nixLogDir);
    LocalStore store(false);

    Path target = namedStore + "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-item";
    Path targetFile = settings.nixStore + "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-item";
    std::string plantedName;
    writeFile(targetFile, "x");

    /* Sorted: readdir order is filesystem-dependent and the Haskell side sorts
       its listing.  The property under test is the SET of root names, not the
       order the directory happens to return them in. */
    auto listRoots = [&]() {
        Path autoDir = settings.nixStateDir + "/gcroots/auto";
        std::vector<std::string> names;
        if (auto dir = opendir(autoDir.c_str())) {
            while (auto e = readdir(dir)) {
                std::string n = e->d_name;
                if (n == "." || n == "..") continue;
                names.push_back(n);
            }
            closedir(dir);
        }
        std::sort(names.begin(), names.end());
        std::string out;
        for (auto & n : names) {
            if (!out.empty()) out += ",";
            out += n;
        }
        return out;
    };

    /* 1. The root NAME for a known path, and its target. */
    {
        std::string outcome = "ok";
        try { store.addIndirectRoot(target); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::string names = listRoots();
        std::string resolved;
        if (!names.empty()) {
            char buf[4096];
            ssize_t n = readlink((settings.nixStateDir + "/gcroots/auto/" + names).c_str(),
                buf, sizeof buf - 1);
            if (n > 0) { buf[n] = 0; resolved = buf; }
        }
        std::cout << std::format("root-name {} target-match={} {}\n",
            names, resolved == target ? 1 : 0, outcome);
    }

    /* 2. Adding the SAME root twice REPLACES it (atomic rename), leaving one
          entry and no leftover temporary. */
    {
        std::string outcome = "ok";
        try { store.addIndirectRoot(target); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("root-idempotent {} {}\n", listRoots(), outcome);
    }

    /* 3. A DIFFERENT path gets a different root name. */
    {
        Path other = namedStore + "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other";
        writeFile(settings.nixStore + "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other", "y");
        std::string outcome = "ok";
        try { store.addIndirectRoot(other); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::cout << std::format("two-roots {} {}\n", listRoots(), outcome);
    }

    /* 4. A STALE TEMPORARY at the fixed Haskell temp name must not block the
          replace.  C++ names its temporary .tmp-PID-RAND so it never collides
          with this; the observable requirement is that the root ends up
          pointing at the target and the operation succeeds. */
    {
        Path root = settings.nixStateDir + "/gcroots/auto/"
            + printHash32(hashString(htSHA1, target));
        /* Plant a stale temp in the OTHER implementation's naming: C++ uses
           .tmp-PID-RAND, Haskell .tmp-goonix.  Each side must still produce a
           correct root; what it does with a FOREIGN stale file is its own
           business, so case 6 excludes exactly this planted name. */
        plantedName = baseNameOf(root) + ".tmp-goonix";
        writeFile(root + ".tmp-goonix", "stale");
        std::string outcome = "ok";
        try { store.addIndirectRoot(target); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::string resolved;
        try { resolved = readLink(root); } catch (...) { resolved = ""; }
        std::cout << std::format("stale-temp target-match={} {}\n",
            resolved == target ? 1 : 0, outcome);
    }

    /* 5. Re-pointing an EXISTING root at its own target again still resolves. */
    {
        Path other = namedStore + "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other";
        Path root = settings.nixStateDir + "/gcroots/auto/"
            + printHash32(hashString(htSHA1, other));
        std::string outcome = "ok";
        try { store.addIndirectRoot(other); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        std::string resolved;
        try { resolved = readLink(root); } catch (...) { resolved = ""; }
        std::cout << std::format("repoint target-match={} {}\n",
            resolved == other ? 1 : 0, outcome);
    }

    /* 6. Neither side may touch a FOREIGN stale temp, and neither may leave a
          temp of its own.  With per-call temp names on both sides the planted
          .tmp-goonix survives untouched in BOTH, so the counts match with no
          exclusion (reviewer, 2026-11-23).  Reported as two properties so a
          failure says which one broke. */
    {
        Path autoDir = settings.nixStateDir + "/gcroots/auto";
        unsigned foreignKept = 0, ownTemps = 0;
        if (auto dir = opendir(autoDir.c_str())) {
            while (auto e = readdir(dir)) {
                std::string n = e->d_name;
                if (n == plantedName) ++foreignKept;
                else if (n.find(".tmp") != std::string::npos) ++ownTemps;
            }
            closedir(dir);
        }
        std::cout << std::format("foreign-temp-kept count={}\n", foreignKept);
        std::cout << std::format("no-leftover-temp count={}\n", ownTemps);
    }
    return 0;
}

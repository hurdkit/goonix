// goonix: probe the REAL C++ registration path (registerValidPath), so the
// Haskell registerPath can be compared against measured behaviour.
#include "local-store.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <sys/stat.h>

using namespace nix;

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: register-probe DIR\n"; return 2; }
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
    chmod(settings.nixStore.c_str(), 0755);
    LocalStore store(false);

    Path a = settings.nixStore + "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a";
    Path b = settings.nixStore + "/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b";
    writeFile(a, "aaa"); writeFile(b, "bbb");
    Hash h = hashString(htSHA256, "aaa");

    auto report = [&](const char * label, std::function<void()> action) {
        std::string outcome = "ok";
        try { action(); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        bool valid = store.isValidPath(a);
        std::cout << std::format("{} valid={} {}\n", label, valid ? 1 : 0, outcome);
    };

    /* 1. A SELF-reference: C++ registers it (the schema's DeleteSelfRefs trigger
          exists precisely because self-refs occur). */
    report("self-reference", [&] {
        ValidPathInfo info;
        info.path = a; info.hash = h; info.narSize = 3;
        info.references = PathSet{a};
        store.registerValidPath(info);
    });
    {
        auto info = store.queryPathInfo(a);
        std::cout << std::format("self-reference-kept count={}\n",
            info.references.size());
    }

    /* 2. Re-registering the SAME path with a different narSize/hash UPDATES the
          row rather than failing or duplicating. */
    report("re-register-updates", [&] {
        ValidPathInfo info;
        info.path = a; info.hash = hashString(htSHA256, "zzz"); info.narSize = 99;
        info.references = PathSet{a};
        store.registerValidPath(info);
    });
    {
        auto info = store.queryPathInfo(a);
        std::cout << std::format("re-register-narsize {}\n", info.narSize);
    }

    /* 3. A reference to an UNREGISTERED path: C++ queryValidPathId throws. */
    report("unknown-reference", [&] {
        ValidPathInfo info;
        info.path = b; info.hash = hashString(htSHA256, "bbb"); info.narSize = 3;
        info.references = PathSet{settings.nixStore + "/cccccccccccccccccccccccccccccccc-missing"};
        store.registerValidPath(info);
    });

    /* 4. narSize 0 is stored as NULL (C++ passes (narSize, narSize != 0)). */
    {
        Path z = settings.nixStore + "/dddddddddddddddddddddddddddddddd-zero";
        writeFile(z, "");
        ValidPathInfo info;
        info.path = z; info.hash = hashString(htSHA256, ""); info.narSize = 0;
        std::string outcome = "ok";
        try { store.registerValidPath(info); }
        catch (std::exception & e) { outcome = std::string("threw: ") + e.what(); }
        auto qi = store.queryPathInfo(z);
        std::cout << std::format("zero-narsize {} {}\n", qi.narSize, outcome);
    }
    return 0;
}
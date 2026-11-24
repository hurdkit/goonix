// goonix: probe the REAL C++ contentOutputOrder so the Haskell port can be
// compared order for order.  The subtle parts are the sibling traversal order
// (std::map iterates by PATH, not by output name), the post-order emission, the
// `visiting` cycle detection, and the fact that a reference is found by
// scanForReferences on the PHYSICAL path under the chroot root.
//
// contentOutputOrder is already declared in ca.hh, so this probe needs no new
// hook in the C++ implementation: it calls the shipped function directly.
#include "ca.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <map>
#include <set>
#include <sys/stat.h>

using namespace nix;

static Path storeDir;

static void put(const Path & p, const string & contents)
{
    createDirs(dirOf(p));
    writeFile(p, contents);
}

/* Render an order as "name=path-basename,..." so the two sides compare on the
   sequence of outputs, not on the scratch prefix. */
static string render(const std::vector<std::pair<string, Path>> & order)
{
    string out;
    for (auto & entry : order) {
        if (!out.empty()) out += ",";
        out += entry.first;
    }
    return out;
}

static void report(const char * label, const Derivation & drv,
                   const PathSet & allPaths, const Path & chroot)
{
    string out;
    try {
        auto order = contentOutputOrder(drv, allPaths, chroot);
        out = render(order);
    } catch (std::exception & e) {
        out = string("threw: ") + e.what();
    }
    std::cout << std::format("{} {}\n", label, out);
}

/* The output paths must be REAL base32 store paths, not reserved tokens.
   scanForReferences (nix/libstore/references.cc) rejects every byte outside
   nix's base32 alphabet, and the reserved token alphabet (e/o/u/t...) is not
   that alphabet - so a fixture built from tokenPath() creates NO reference
   edge at all and every order collapses to name order.  Measured: with tokens,
   out-uses-lib and lib-uses-out both returned "lib,out" and the cycle fixture
   returned an order instead of a refusal.  Use distinct base32 hash parts so
   the reference is actually seen. */
static Path realPath(const string & name, const string & hash)
{
    return storeDir + "/" + hash + "-multi-" + name;
}

static DerivationOutput output(const string & name, const string & hash)
{
    return DerivationOutput(realPath(name, hash), "", "");
}

/* Each fixture uses a fresh store: the output NAMES repeat across fixtures, so
   a shared store carries one fixture's reference files into the next and
   invents edges (measured: out/ held uses-lib, uses-both, self, link and
   uses-other at once, making the lib-uses-out fixture a real cycle). */
static void useFixture(const Path & base, const string & label)
{
    storeDir = base + "/" + label;
    settings.nixStore = storeDir;
    createDirs(storeDir);
}

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: order-probe DIR\n"; return 2; }
    Path base = argv[1];
    storeDir = base + "/store";
    settings.nixStore = storeDir;
    createDirs(storeDir);

    /* 1. One output, no references. */
    {
        useFixture(base, "f1");
        Derivation drv;
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path out = drv.outputs["out"].path;
        put(out + "/f", "hello");
        report("single", drv, PathSet{out}, "");
    }

    /* 2. out depends on lib: lib must be finalised FIRST. */
    {
        useFixture(base, "f2");
        Derivation drv;
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path lib = drv.outputs["lib"].path, out = drv.outputs["out"].path;
        put(lib + "/f", "lib-content");
        put(out + "/uses-lib", lib);
        report("out-uses-lib", drv, PathSet{out, lib}, "");
    }

    /* 3. The reverse: lib depends on out.  Names sort lib<out but the ORDER
          must follow the reference, not the name. */
    {
        useFixture(base, "f3");
        Derivation drv;
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path lib = drv.outputs["lib"].path, out = drv.outputs["out"].path;
        put(out + "/f", "out-content");
        put(lib + "/uses-out", out);
        report("lib-uses-out", drv, PathSet{out, lib}, "");
    }

    /* 4. A chain a->b->c across three outputs. */
    {
        useFixture(base, "f4");
        Derivation drv;
        drv.outputs["aaa"] = output("aaa", "xg3rib7557bir3gxdzk91vpmmpv19kzd");
        drv.outputs["bbb"] = output("bbb", "sc0nf842248fn0csawh6yqljjlqy6hwa");
        drv.outputs["ccc"] = output("ccc", "p9xkb51zz15bkx9p7rd3vmiggimv3dr7");
        Path a = drv.outputs["aaa"].path, b = drv.outputs["bbb"].path,
             c = drv.outputs["ccc"].path;
        put(c + "/f", "leaf");
        put(b + "/uses-c", c);
        put(a + "/uses-b", b);
        report("chain", drv, PathSet{a, b, c}, "");
    }

    /* 5. A diamond: out uses both lib and dev, dev uses lib. */
    {
        useFixture(base, "f5");
        Derivation drv;
        drv.outputs["dev"] = output("dev", "1k7xmgb99bgmx7k1i3pd5zvrrvz5dp3i");
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path dev = drv.outputs["dev"].path, lib = drv.outputs["lib"].path,
             out = drv.outputs["out"].path;
        put(lib + "/f", "leaf");
        put(dev + "/uses-lib", lib);
        put(out + "/uses-both", dev + " " + lib);
        report("diamond", drv, PathSet{out, lib, dev}, "");
    }

    /* 6. Independent outputs: nothing references anything. */
    {
        useFixture(base, "f6");
        Derivation drv;
        drv.outputs["aaa"] = output("aaa", "xg3rib7557bir3gxdzk91vpmmpv19kzd");
        drv.outputs["zzz"] = output("zzz", "j4qf60wssw06fq4j2l8ynhcaachny8l2");
        Path a = drv.outputs["aaa"].path, z = drv.outputs["zzz"].path;
        put(a + "/f", "a");
        put(z + "/f", "z");
        report("independent", drv, PathSet{a, z}, "");
    }

    /* 7. A cycle: out uses lib and lib uses out.  Must be refused. */
    {
        useFixture(base, "f7");
        Derivation drv;
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path lib = drv.outputs["lib"].path, out = drv.outputs["out"].path;
        put(lib + "/uses-out", out);
        put(out + "/uses-lib", lib);
        report("cycle", drv, PathSet{out, lib}, "");
    }

    /* 8. A self reference: an output holding its OWN token is not a cycle. */
    {
        useFixture(base, "f8");
        Derivation drv;
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path out = drv.outputs["out"].path;
        put(out + "/self", out);
        report("self-ref", drv, PathSet{out}, "");
    }

    /* 9. The chroot root is PREFIXED to the physical path: the same fixture
          under a chroot must give the same order. */
    {
        useFixture(base, "f9");
        Derivation drv;
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path lib = drv.outputs["lib"].path, out = drv.outputs["out"].path;
        Path chroot = base + "/chroot";
        put(chroot + lib + "/f", "lib-content");
        put(chroot + out + "/uses-lib", lib);
        report("chroot", drv, PathSet{out, lib}, chroot);
    }

    /* 10. A reference to a path that is NOT a sibling output is ignored. */
    {
        useFixture(base, "f10");
        Derivation drv;
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path out = drv.outputs["out"].path;
        Path other = storeDir + "/yh4sjc8668cjs4hyf0la2wqnnqw2al0f-unrelated";
        put(other + "/f", "other");
        put(out + "/uses-other", other);
        report("non-sibling-ref", drv, PathSet{out, other}, "");
    }

    /* 11. An output whose physical path is MISSING: scanForReferences cannot
           read it.  Record what the real code does rather than assuming. */
    {
        useFixture(base, "f11");
        Derivation drv;
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path lib = drv.outputs["lib"].path, out = drv.outputs["out"].path;
        put(lib + "/f", "lib-only");
        report("missing-out", drv, PathSet{out, lib}, "");
    }

    /* 12. A reference inside a symlink TARGET, and one inside a file NAME. */
    {
        useFixture(base, "f12");
        Derivation drv;
        drv.outputs["lib"] = output("lib", "9vg5xpkiikpx5gv9rbzmd731137dmzbr");
        drv.outputs["out"] = output("out", "8sf4wnjhhjnw4fs8qaylc620026clyaq");
        Path lib = drv.outputs["lib"].path, out = drv.outputs["out"].path;
        put(lib + "/f", "lib-content");
        createDirs(out);
        if (symlink(lib.c_str(), (out + "/link").c_str()) < 0)
            throw SysError("symlink");
        report("symlink-ref", drv, PathSet{out, lib}, "");
    }

    return 0;
}

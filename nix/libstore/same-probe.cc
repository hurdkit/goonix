// goonix: probe the REAL C++ sameContent VERDICT.  inverseTree is already
// probed (inverse-probe.cc); what sameContent adds is the hash-part extraction
// from the FINAL and TOKEN paths (baseNameOf(...).substr(0, 32)) and the
// equality against printHash(expected).  A wrong extraction or a wrong
// comparison direction turns a collision check into a no-op, so compare the
// boolean itself, including the cases that must be FALSE.
#include "ca.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <map>
#include <sys/stat.h>

namespace nix {
bool sameContentForTest(const Path & path, const string & final,
    const string & token, const Hash & expected,
    const std::map<Path, Path> & siblings);
string inverseTreeForTest(const Path & path, const string & finalHash,
    const string & tokenHash, const std::map<Path, Path> & siblings);
}

using namespace nix;

static Path storeDir;

static void useFixture(const Path & base, const string & label)
{
    storeDir = base + "/" + label;
    settings.nixStore = storeDir;
    createDirs(storeDir);
}

static void put(const Path & p, const string & contents)
{
    createDirs(dirOf(p));
    writeFile(p, contents);
}

/* A final/token path pair whose hash parts are the given 32-char strings. */
static Path named(const string & hash, const string & name)
{
    return storeDir + "/" + hash + "-" + name;
}

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: same-probe DIR\n"; return 2; }
    Path base = argv[1];
    std::string fin(32, 'f'), tok(32, 't');
    std::map<Path, Path> none;

    auto report = [&](const char * label, const Path & p, const string & finalP,
                      const string & tokenP, const Hash & expected,
                      const std::map<Path, Path> & sib) {
        std::string out;
        try {
            out = sameContentForTest(p, finalP, tokenP, expected, sib) ? "true" : "false";
        } catch (std::exception & e) {
            out = string("threw: ") + e.what();
        }
        std::cout << std::format("{} {}\n", label, out);
    };

    /* The expected hash for a tree, computed the way the daemon does: the
       inverse digest is a hex string, so parse it back into a Hash. */
    auto expectedOf = [&](const Path & p, const std::map<Path, Path> & sib) {
        string digest = inverseTreeForTest(p, fin, tok, sib);
        return parseHash(htSHA256, digest);
    };

    /* 1. A plain file whose inverse digest IS the expected hash: true. */
    {
        useFixture(base, "f1");
        Path d = named(fin, "item");
        put(d + "/f", "hello");
        report("match", d + "/f", d, named(tok, "item"), expectedOf(d + "/f", none), none);
    }

    /* 2. A DIFFERENT expected hash: must be false, not true. */
    {
        useFixture(base, "f2");
        Path d = named(fin, "item");
        put(d + "/f", "hello");
        Hash wrong = parseHash(htSHA256, string(64, '0'));
        report("mismatch", d + "/f", d, named(tok, "item"), wrong, none);
    }

    /* 3. The tree CONTAINS the token: the inverse replaces it with the final
          hash, so the expected hash must be the inverse digest, not the raw
          tree digest.  This is the case the whole check exists for. */
    {
        useFixture(base, "f3");
        Path d = named(fin, "item");
        put(d + "/self", named(tok, "item"));
        report("token-in-tree", d + "/self", d, named(tok, "item"),
            expectedOf(d + "/self", none), none);
    }

    /* 4. Same fixture, but the expected hash is the digest of the tree WITHOUT
          the inverse mapping: must be false.  inverseTree maps FINAL -> TOKEN,
          so the tree must hold the FINAL hash for the mapping to change
          anything.  Holding the token made both digests identical and the case
          vacuous (measured: true). */
    {
        useFixture(base, "f4");
        Path d = named(fin, "item");
        put(d + "/self", named(fin, "item"));
        /* the identity inverse (from == to) leaves the final hash in place */
        string raw = inverseTreeForTest(d + "/self", tok, tok, none);
        report("no-inverse-mismatch", d + "/self", d, named(tok, "item"),
            parseHash(htSHA256, raw), none);
    }

    /* 5. The hash part is taken from the BASENAME, not the whole path: a final
          path with a long directory prefix must still work. */
    {
        useFixture(base, "f5");
        Path d = named(fin, "item");
        put(d + "/f", "hello");
        Path deep = storeDir + "/nested/deep/" + fin + "-item";
        report("basename-extraction", d + "/f", deep, named(tok, "item"),
            expectedOf(d + "/f", none), none);
    }

    /* 6. A name shorter than 32 characters after the store prefix: substr must
          not run past the end.  Record what the real code does. */
    {
        useFixture(base, "f6");
        Path d = named(fin, "item");
        put(d + "/f", "hello");
        report("short-final", d + "/f", storeDir + "/short", named(tok, "item"),
            expectedOf(d + "/f", none), none);
    }

    /* 7. Siblings: the map reverses sibling finals back to tokens.  The
          sibling hash must clear the streaming retention tail: the boundary
          loop protects only prefixes of FINAL (keep = final.size()-1), so a
          sibling hash sitting in the last 31 bytes is split across chunks and
          never matches.  Measured with trailing padding: 0 and 1 bytes -> the
          map has NO effect; 31, 32 and 40 -> it does.  Both daemons share that
          limitation, so the fixture pads to exercise the reversal. */
    {
        useFixture(base, "f7");
        Path d = named(fin, "item");
        Path sibFinal = named(std::string(32, 's'), "sib");
        Path sibToken = named(std::string(32, 'u'), "sib");
        put(d + "/uses-sib", sibFinal + string(40, 'z'));
        std::map<Path, Path> sib{{sibToken, sibFinal}};
        report("siblings", d + "/uses-sib", d, named(tok, "item"),
            expectedOf(d + "/uses-sib", sib), sib);
    }

    /* 8. The same tree, but the expected digest is computed WITHOUT the
          sibling map: the reversal changes the bytes, so this must be false. */
    {
        useFixture(base, "f8");
        Path d = named(fin, "item");
        Path sibFinal = named(std::string(32, 's'), "sib");
        Path sibToken = named(std::string(32, 'u'), "sib");
        put(d + "/uses-sib", sibFinal + string(40, 'z'));
        std::map<Path, Path> sib{{sibToken, sibFinal}};
        report("siblings-unapplied", d + "/uses-sib", d, named(tok, "item"),
            expectedOf(d + "/uses-sib", none), sib);
    }

    /* 8b. The sibling hash INSIDE the retention tail must still be inverted.
           The expectation is computed INDEPENDENTLY (substitute in memory, then
           frame and hash) rather than through inverseTreeForTest, so a shared
           boundary bug cannot agree with itself. */
    {
        useFixture(base, "f8b");
        Path d = named(fin, "item");
        Path sibFinal = named(std::string(32, 's'), "sib");
        Path sibToken = named(std::string(32, 'u'), "sib");
        string contents = sibFinal;
        put(d + "/uses-sib", contents);
        std::map<Path, Path> sib{{sibToken, sibFinal}};
        /* substitute sibling final -> sibling token, then final -> token */
        string substituted = contents;
        string sf = baseNameOf(sibFinal).substr(0, 32);
        string st = baseNameOf(sibToken).substr(0, 32);
        for (size_t at = 0; (at = substituted.find(sf, at)) != string::npos; at += st.size())
            substituted.replace(at, sf.size(), st);
        /* The canonical regular-file framing, written out here rather than
           through a new hook: treeDomain is the fixed domain string
           "goonix-tree-v1\0" (ca.cc) and put64 is little-endian.  Keeping the
           expectation independent of inverseTree is the point - the shared
           boundary bug must not be able to agree with itself. */
        string header("goonix-tree-v1\0", 15);
        header.push_back(1);
        header.push_back(0);
        uint64_t size = substituted.size();
        for (unsigned i = 0; i < 8; ++i)
            header.push_back(char((size >> (8 * i)) & 0xff));
        Hash expected = hashString(htSHA256, header + substituted);
        report("sibling-in-tail", d + "/uses-sib", d, named(tok, "item"), expected, sib);
    }

    /* 9. An executable file: the execute bit is part of the NAR, so a digest
          taken from a non-executable twin must NOT match. */
    {
        useFixture(base, "f9");
        Path d = named(fin, "item");
        put(d + "/x", "script");
        Path plain = storeDir + "/" + string(32, 'p') + "-plain";
        put(plain + "/x", "script");
        chmod((plain + "/x").c_str(), 0444);
        chmod((d + "/x").c_str(), 0555);
        report("exec-bit", d + "/x", d, named(tok, "item"),
            expectedOf(plain + "/x", none), none);
    }

    /* 10. A missing path: the check must refuse rather than return true. */
    {
        useFixture(base, "f10");
        Path d = named(fin, "item");
        createDirs(d);
        report("missing", d + "/absent", d, named(tok, "item"),
            parseHash(htSHA256, string(64, '0')), none);
    }

    return 0;
}
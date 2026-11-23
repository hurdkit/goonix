// goonix: probe the REAL C++ inverseTree (the CA verification digest), so the
// Haskell port can be compared hash for hash.  The subtle parts are the
// streaming boundary retention, the sibling reversal ORDER, and the directory
// entry sort by INVERSE name.
#include "ca.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <map>
#include <sys/stat.h>

namespace nix {
string inverseTreeForTest(const Path & path, const string & finalHash,
    const string & tokenHash, const std::map<Path, Path> & siblings);
}

using namespace nix;

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: inverse-probe DIR\n"; return 2; }
    Path base = argv[1];
    std::string fin(32, 'f'), tok(32, 't');
    // 'f' is not in the reserved alphabet, but inverseTree only does textual
    // replacement, so any 32-char strings work as final/token here.
    std::map<Path, Path> none;

    auto report = [&](const char * label, const Path & p,
                      const std::map<Path, Path> & sib) {
        std::string out;
        try { out = inverseTreeForTest(p, fin, tok, sib); }
        catch (std::exception & e) { out = std::string("threw"); }
        std::cout << std::format("{} {}\n", label, out);
    };

    /* 1. A plain file with no reference. */
    { Path d = base + "/plain"; createDirs(d);
      writeFile(d + "/f", "hello");
      report("plain-file", d + "/f", none); }

    /* 2. An EXECUTABLE file: the header carries the exec bit. */
    { Path d = base + "/exec"; createDirs(d);
      writeFile(d + "/f", "hello"); chmod((d + "/f").c_str(), 0555);
      report("exec-file", d + "/f", none); }

    /* 3. The final hash at the very start, very end, and across the 128KiB
          read boundary at several offsets. */
    { Path d = base + "/start"; createDirs(d);
      writeFile(d + "/f", fin + "tail");
      report("final-at-start", d + "/f", none); }
    { Path d = base + "/end"; createDirs(d);
      writeFile(d + "/f", "head" + fin);
      report("final-at-end", d + "/f", none); }
    for (int split : {1, 16, 31, 32}) {
        Path d = base + "/split" + std::to_string(split); createDirs(d);
        std::string contents(128 * 1024 - (size_t) split, 'x');
        contents += fin;
        writeFile(d + "/f", contents);
        report(("final-split-" + std::to_string(split)).c_str(), d + "/f", none);
    }

    /* 4. A SYMLINK whose target carries the final hash. */
    { Path d = base + "/link"; createDirs(d);
      createSymlink("/gnu/store/" + fin + "-x", d + "/l");
      report("symlink-target", d + "/l", none); }

    /* 5. A DIRECTORY whose entry NAMES carry the final hash: the sort is by
          INVERSE name, so the order can differ from the raw name order. */
    { Path d = base + "/dir"; createDirs(d);
      writeFile(d + "/" + fin + "-a", "one");
      writeFile(d + "/" + tok + "-z", "two");
      writeFile(d + "/mmm", "three");
      report("dir-inverse-sort", d, none); }

    /* 6. SIBLINGS: two sibling mappings applied in REVERSE map order. */
    { Path d = base + "/sib"; createDirs(d);
      std::string s1t(32, 'a'), s1f(32, 'b'), s2t(32, 'c'), s2f(32, 'd');
      writeFile(d + "/f", s1f + "|" + s2f + "|" + fin);
      std::map<Path, Path> sib {
          {"/gnu/store/" + s1t + "-one", "/gnu/store/" + s1f + "-one"},
          {"/gnu/store/" + s2t + "-two", "/gnu/store/" + s2f + "-two"}};
      report("siblings", d + "/f", sib); }

    /* 7. An unsupported file type (fifo) must be refused. */
    { Path d = base + "/fifo"; createDirs(d);
      Path p = d + "/p";
      if (mkfifo(p.c_str(), 0600)) throw SysError("mkfifo");
      report("fifo-refused", p, none); }
    return 0;
}
// goonix: C++/HS parity of the FORWARD rewrite at the read boundaries.
//
// The invariant under test: rewriteRegularFile's streaming result must equal the
// WHOLE-FILE result, whatever offset a match sits at and however read() split
// the file.  Two defects were fixed on both sides (HS 73af00cd431, C++
// e222d92d6f4):
// (a) a COMPLETE plain self-reference ending exactly at the emit point, whose
//     token's last character equals its first, lost its last byte to a prefix
//     hold-back and was wrongly REJECTED by the 8-byte fragment check;
// (b) an opaque occurrence (UTF-32LE / UTF-16LE encoding of FROM, or an 8-byte
//     fragment) straddling the emit point was split across two rounds and
//     wrongly ACCEPTED.
//
// checkRewriteForTest drives the streaming loop; replaceWholeForTest is the
// whole-file oracle, a different code path.  Each case reports the verdict and,
// when accepted, a digest of the resulting bytes, so the two sides compare on
// behaviour rather than on error prose.
#include "ca.hh"
#include "globals.hh"
#include "util.hh"
#include <iostream>
#include <format>
#include <string>
#include <sys/stat.h>

namespace nix {
void checkRewriteForTest(const Path & path, const string & from, const string & to);
string replaceWholeForTest(const string & body, const string & from, const string & to);
}

using namespace nix;

/* A 32-character token whose LAST character equals its FIRST: the shape that
   makes a complete match look like a partial one to a prefix test. */
static const string FROM = "teouteouteouteouteouteouteouteot";
static const string TO = "0123456789abcdfghijklmnpqrsvwxyz";

static const size_t READ_SIZE = 128 * 1024;
static const size_t KEEP = FROM.size() * 4 - 1;

static string pad(size_t n, char c) { return string(n, c); }

static string utfEncode(unsigned width, const string & s)
{
    string out;
    for (unsigned char c : s) {
        out.push_back(char(c));
        for (unsigned j = 1; j < width; ++j) out.push_back(0);
    }
    return out;
}

/* The whole-file verdict: "rejected" or a digest of the rewritten bytes. */
/* A rejection is reported with its FULL message, offset included, so the two
   sides must agree on which byte of the FILE they name - not merely on the fact
   of rejection.  The path is normalised to <file> by the runner. */
static string oracle(const string & body)
{
    try {
        string rewritten = replaceWholeForTest(body, FROM, TO);
        return "accepted " + printHash(hashString(htSHA256, rewritten));
    } catch (std::exception & e) {
        return string("rejected: ") + e.what();
    }
}

/* The streaming verdict on a real file, reported the same way. */
static string streaming(const Path & path, const string & body)
{
    writeFile(path, body);
    try {
        checkRewriteForTest(path, FROM, TO);
    } catch (std::exception & e) {
        return string("rejected: ") + e.what();
    }
    try {
        return "accepted " + printHash(hashString(htSHA256, readFile(path)));
    } catch (std::exception & e) {
        return "unreadable";
    }
}

int main(int argc, char ** argv)
{
    if (argc != 2) { std::cerr << "usage: rewrite-boundary-probe DIR\n"; return 2; }
    Path base = argv[1];
    createDirs(base);
    settings.nixStore = base;

    struct Case { string label; string body; };
    std::vector<Case> cases;

    /* (a) A plain token ending exactly KEEP bytes before EOF, and exactly KEEP
           bytes before the first read's end.  Swept either side: the window is
           one byte wide, so a hand-picked offset proves nothing. */
    for (int d = -2; d <= 2; ++d) {
        if ((int)KEEP + d < 0) continue;
        cases.push_back({"plain-eof-" + std::to_string(d),
            pad(40, 'x') + FROM + pad(KEEP + d, 'z')});
    }
    for (int d = -2; d <= 2; ++d) {
        int lead = (int)READ_SIZE - (int)KEEP - (int)FROM.size() + d;
        if (lead < 0) continue;
        cases.push_back({"plain-read-" + std::to_string(d),
            pad(lead, 'x') + FROM + pad(200, 'z')});
    }

    /* (b) Opaque occurrences straddling the first read's emit point. */
    struct Pat { string name; string bytes; };
    std::vector<Pat> pats = {
        {"utf32", utfEncode(4, FROM)},
        {"utf16", utfEncode(2, FROM)},
        {"frag0", FROM.substr(0, 8)},
        {"frag12", FROM.substr(12, 8)},
    };
    size_t emit = READ_SIZE - KEEP;
    for (auto & p : pats)
        for (int d = -2; d <= 2; ++d) {
            int lead = (int)emit + d - (int)p.bytes.size() / 2;
            if (lead < 0) continue;
            cases.push_back({p.name + "-straddle-" + std::to_string(d),
                pad(lead, 'x') + p.bytes + pad(200, 'z')});
        }

    /* Controls: the same shapes wholly inside one chunk must still be rejected,
       and a plain reference must still be rewritten. */
    cases.push_back({"utf32-early", pad(10, 'x') + utfEncode(4, FROM) + pad(200, 'z')});
    cases.push_back({"utf16-early", pad(10, 'x') + utfEncode(2, FROM) + pad(200, 'z')});
    cases.push_back({"frag-early", pad(10, 'x') + FROM.substr(0, 8) + pad(200, 'z')});
    cases.push_back({"plain-only", pad(10, 'x') + FROM + pad(10, 'z')});
    cases.push_back({"no-reference", pad(500, 'x')});

    /* Rejections whose FILE offset is only correct if the consumed byte count is
       carried across rounds: one past two whole reads, and one in the final
       tail (the last `pending', which starts at `consumed', not at zero). */
    cases.push_back({"frag-third-read",
        pad(2 * READ_SIZE + 5000, 'x') + FROM.substr(0, 8) + pad(200, 'z')});
    cases.push_back({"utf32-third-read",
        pad(2 * READ_SIZE + 5000, 'x') + utfEncode(4, FROM) + pad(200, 'z')});
    cases.push_back({"frag-final-tail",
        pad(READ_SIZE, 'x') + FROM.substr(0, 8)});
    cases.push_back({"utf16-final-tail",
        pad(READ_SIZE, 'x') + utfEncode(2, FROM)});

    unsigned index = 0;
    for (auto & c : cases) {
        Path path = base + "/case" + std::to_string(index++);
        /* The oracle names <memory>, the streaming run names the real path.
           Normalise both to <file> so self-consistency compares the MESSAGE and
           the byte OFFSET, not the file name. */
        auto norm = [&path](string s) {
            for (const string & needle : {string("<memory>"), path}) {
                size_t at = 0;
                while ((at = s.find(needle, at)) != string::npos) {
                    s.replace(at, needle.size(), "<file>");
                    at += 6;
                }
            }
            return s;
        };
        string want = norm(oracle(c.body));
        string got = norm(streaming(path, c.body));
        /* Report the STREAMING verdict, and whether it agrees with the
           whole-file oracle, so a side that is internally inconsistent is
           visible even if both sides happen to agree with each other. */
        std::cout << std::format("{} {} self-consistent={}\n",
            c.label, got, want == got ? 1 : 0);
    }
    return 0;
}
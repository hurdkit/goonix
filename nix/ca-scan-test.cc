// goonix: black-box tests for the out-of-process CA scan helper.
#include "util.hh"
#include <cstdlib>
#include <iostream>
#include <format>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <vector>
#include <string>
using namespace nix;

static int run(const Path & helper, const Path & tree, const string & token)
{
    pid_t child = fork();
    if (child < 0) throw SysError("forking helper test");
    if (child == 0) {
        execl(helper.c_str(), helper.c_str(), tree.c_str(), token.c_str(), (char *) nullptr);
        _exit(127);
    }
    int status;
    if (waitpid(child, &status, 0) < 0) throw SysError("waiting for helper test");
    return status;
}

static unsigned failures = 0;

static void check(bool condition, const std::string & name)
{
    if (condition) std::cout << "PASS " << name << '\n';
    else { std::cerr << "FAIL " << name << '\n'; ++failures; }
}

/* Run the helper and capture its first stdout line, so a test can assert the
   reported KIND and OFFSET, not just the exit status. */
static string runCapture(const Path & helper, const Path & tree, const string & token)
{
    int fds[2];
    if (pipe(fds) != 0) throw SysError("pipe for helper output");
    pid_t child = fork();
    if (child < 0) throw SysError("forking helper test");
    if (child == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        execl(helper.c_str(), helper.c_str(), tree.c_str(), token.c_str(), (char *) nullptr);
        _exit(127);
    }
    close(fds[1]);
    string out;
    char buffer[4096];
    ssize_t n;
    while ((n = read(fds[0], buffer, sizeof(buffer))) > 0) out.append(buffer, n);
    close(fds[0]);
    int status;
    if (waitpid(child, &status, 0) < 0) throw SysError("waiting for helper test");
    /* First line, without the trailing file column. */
    auto nl = out.find('\n');
    string line = nl == string::npos ? out : out.substr(0, nl);
    auto tab1 = line.find('\t');
    if (tab1 == string::npos) return "";
    auto tab2 = line.find('\t', tab1 + 1);
    return tab2 == string::npos ? line : line.substr(0, tab2);
}

int main(int argc, char ** argv)
{
    if (argc != 2) {
        std::cerr << "usage: ca-scan-test HELPER\n";
        return 2;
    }
    Path helper = argv[1];
    string token = "ttteoeueuuottuuotutetetooueeoutu";
    for (auto format : {"gz", "xz", "bz2", "zip"}) {
        Path file = string("tests/fixtures/ca-self-token.") + format;
        int status = run(helper, file, token);
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 1) {
            std::cerr << "FAIL " << format << " found status " << status << '\n';
            ++failures;
        } else std::cout << "PASS " << format << " helper found token\n";
        status = run(helper, file, "oooooooooooooooooooooooooooooooo");
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            std::cerr << "FAIL " << format << " bare non-token reserved bytes are clean " << status << '\n';
            ++failures;
        } else std::cout << "PASS " << format << " bare non-token reserved bytes are clean\n";
    }
    int status = run(helper, "tests/fixtures/ca-placeholder-boundary.gz", token);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 1) {
        std::cerr << "FAIL decoded placeholder boundary " << status << '\n';
        ++failures;
    } else std::cout << "PASS decoded placeholder boundary is found\n";
    status = run(helper, "/does/not/exist", token);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 2) {
        std::cerr << "FAIL helper error status " << status << '\n';
        ++failures;
    } else std::cout << "PASS helper reports errors distinctly\n";

    string pattern = getEnv("TMPDIR", "/tmp") + "/ca-scan-malformed-XXXXXX";
    std::vector<char> temporaryTemplate(pattern.begin(), pattern.end());
    temporaryTemplate.push_back('\0');
    Path temporary = mkdtemp(temporaryTemplate.data());
    if (temporary.empty()) throw SysError("creating malformed helper test directory");
    struct Malformed { const char * name; string bytes; };
    std::vector<Malformed> cases = {
        {"bad.gz", string("\x1f\x8b\x08\0", 4) + string(64, '\xff')},
        {"bad.xz", string("\xfd" "7zXZ\0", 6) + string(64, '\xff')},
        {"bad.bz2", "BZh" + string(64, '\xff')},
        {"bad.zip", string("PK\003\004", 4) + string(64, '\xff')},
        {"truncated.gz", readFile("tests/fixtures/ca-self-token.gz").substr(0, 20)}
    };
    for (auto & item : cases) {
        Path file = temporary + "/" + item.name;
        writeFile(file, item.bytes);
        int status = run(helper, file, token);
        if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            std::cerr << "FAIL malformed " << item.name << " status " << status << '\n';
            ++failures;
        } else std::cout << "PASS malformed " << item.name << " is skipped\n";
    }
    Path mixed = temporary + "/mixed";
    createDirs(mixed);
    writeFile(mixed + "/bad.zip", cases[3].bytes);
    writeFile(mixed + "/good.gz", readFile("tests/fixtures/ca-self-token.gz"));
    status = run(helper, mixed, token);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 1) {
        std::cerr << "FAIL malformed member hides valid token " << status << '\n';
        ++failures;
    } else std::cout << "PASS malformed member does not hide a token in its sibling\n";
    /* goonix: sweep the READ SPLIT POINT against a whole-input oracle.

       The helper's consume() keeps overlapSize = 32 bytes between reads.  Its
       patterns are a 32-byte reserved hash, plus one more byte ('-') for an
       unknown placeholder in path shape, so the longest thing it must see whole
       is 33 bytes.  A 32-byte retention is enough because a candidate whose
       33rd byte is missing is simply not decided this round: its 32 hash bytes
       are all retained and the '-' arrives with the next read.  A known token
       needs no '-' at all.  These fixtures pin that, and the reported offset.

       `run' only returns a status, so this uses a variant that captures stdout:
       the offset is part of the contract ("a reported byte offset is the
       file's"), and a status-only test cannot see it.  The expectation is the
       offset the fixture was BUILT with, and the oracle is the same helper on a
       payload small enough to be read in one gzread. */
    {
        Path sweep = temporary + "/sweep";
        createDirs(sweep);
        const size_t readEnd = 128 * 1024;      /* gzread's buffer */
        string selfToken(31, 'e');
        selfToken.push_back('o');
        string unknown(31, 'o');
        unknown.push_back('u');

        struct Kind { const char * name; string hash, suffix, kind; };
        std::vector<Kind> kinds = {
            {"self", selfToken, "", "self-token"},
            {"unknown", unknown, "-x", "placeholder"},
        };
        for (auto & k : kinds) {
            /* Oracle: one small read. */
            Path od = sweep + "/oracle-" + k.name;
            createDirs(od);
            writeFile(od + "/plain", "AAA" + k.hash + k.suffix + "BBB");
            if (system(("gzip -c " + od + "/plain > " + od + "/f.gz").c_str()) != 0)
                throw SysError("gzip for the scan oracle");
            deletePath(od + "/plain");
            string oracle = runCapture(helper, od, selfToken);
            check(oracle == k.kind + "\t3",
                std::format("scan oracle {} reports kind and offset", k.name));

            /* Sweep the hash END across the read end and the second read end. */
            for (unsigned round : {1u, 2u}) {
                for (int delta = -2; delta <= 2; ++delta) {
                    size_t end = round * readEnd + delta;
                    size_t start = end - 32;
                    Path d = sweep + "/" + k.name + "-" + std::to_string(round)
                           + "-" + std::to_string(delta);
                    createDirs(d);
                    writeFile(d + "/plain",
                        string(start, 'A') + k.hash + k.suffix + string(8192, 'B'));
                    if (system(("gzip -c " + d + "/plain > " + d + "/f.gz").c_str()) != 0)
                        throw SysError("gzip for the scan sweep");
                    deletePath(d + "/plain");
                    string got = runCapture(helper, d, selfToken);
                    check(got == k.kind + "\t" + std::to_string(start),
                        std::format("{} hash end at read {} {:+d} reports the file offset {}",
                            k.name, round, delta, start));
                }
            }
        }
        deletePath(sweep);
    }

    deletePath(temporary);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}

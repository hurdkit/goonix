// goonix: black-box tests for the out-of-process CA scan helper.
#include "util.hh"
#include <cstdlib>
#include <iostream>
#include <format>
#include <sys/wait.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
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

int main(int argc, char ** argv)
{
    if (argc != 2) {
        std::cerr << "usage: ca-scan-test HELPER\n";
        return 2;
    }
    Path helper = argv[1];
    string token = "ttteoeueuuottuuotutetetooueeoutu";
    unsigned failures = 0;
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
    deletePath(temporary);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}

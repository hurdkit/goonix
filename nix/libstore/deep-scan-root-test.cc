// goonix: exercise the actual root-to-build-user transition in the scan runner.
#include "deep-scan.hh"
#include "globals.hh"
#include "util.hh"
#include <cstdlib>
#include <format>
#include <iostream>
#include <sys/stat.h>
#include <unistd.h>

using namespace nix;

int main(int argc, char ** argv)
{
    if (geteuid() != 0) {
        std::cout << "SKIP deep-scan privilege test requires root\n";
        return 77;
    }
    if (argc != 3) {
        std::cerr << "usage: ca-scan-root-test IDENTITY-HELPER ROOT\n";
        return 2;
    }
    uid_t uid = 65534;
    gid_t gid = 65534;
    createDirs(argv[2]);
    chmod(argv[2], 0755);
    settings.set("goonix-deep-scan", "true");
    settings.set("goonix-deep-scan-helper", absPath(argv[1]));
    bool identity = false;
    try {
        checkDeepOutput(argv[2], StringSet{}, uid, gid);
    } catch (const Error & error) {
        string expected = std::format("uid={} gid={} groups='", uid, gid);
        string message = error.what();
        identity = message.find(expected) != string::npos;
        std::cout << "helper identity: " << message << '\n';
        if (!identity) std::cerr << message << '\n';
    }
    bool refusedWithoutUser = false;
    try {
        checkDeepOutput(argv[2], StringSet{}, (uid_t) -1, (gid_t) -1);
    } catch (const Error & error) {
        refusedWithoutUser = string(error.what()).find("failed (status 2)") != string::npos;
    }
    if (!identity || !refusedWithoutUser) {
        std::cerr << "FAIL identity=" << identity
                  << " refusal-without-build-user=" << refusedWithoutUser << '\n';
        return 1;
    }
    std::cout << "PASS root daemon clears groups and switches uid/gid\n"
              << "PASS root daemon refuses deep scan without a build user\n";
    return 0;
}

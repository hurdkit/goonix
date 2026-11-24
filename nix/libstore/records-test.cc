// goonix: adversarial tests of record signing, selection and import.
#include "build-goonix-response.hh"
#include "records.hh"
#include "ca.hh"
#include "local-store.hh"
#include "globals.hh"
#include "util.hh"
#include <cstdlib>
#include <functional>
#include <iostream>
#include <format>
#include <sys/wait.h>

using namespace nix;

static int checkGraphResponses()
{
    Strings fields;
    unsigned int hints = 0;
    string error;
    if (!parseGoonixGraphResponse("goonix-records 1\n0\n0\n", true, 1024,
                                  fields, hints, error) || !fields.empty())
        return 1;
    if (parseGoonixGraphResponse("goonix-records 1\n1\n", false, 1024,
                                 fields, hints, error) || !error.empty())
        return 2;
    if (parseGoonixGraphResponse("goonix-records 1\n1\n", true, 1024,
                                 fields, hints, error) ||
        error.find("incomplete graph response at EOF") == string::npos)
        return 3;
    error.clear();
    if (parseGoonixGraphResponse(string(1025, 'x'), false, 1024,
                                 fields, hints, error) ||
        error.find("size limit") == string::npos)
        return 4;
    std::cout << "goonix graph response bounds: PASS\n";
    return 0;
}

static void configureTestStore(const Path & root, const Path & guix)
{
    settings.guixProgram = guix;
    settings.nixStateDir = root;
    settings.nixStore = root + "/store";
    settings.nixDBPath = root + "/db";
    settings.nixConfDir = root + "/etc";
    settings.nixLogDir = root + "/log";
    settings.nixDaemonSocketFile = root + "/socket";
    settings.buildUsersGroup = "";
}

static int checkUnauthorizedImport(int argc, char ** argv)
{
    configureTestStore(argv[1], argv[2]);
    createDirs(settings.nixConfDir);
    chmod(settings.nixConfDir.c_str(), 0700);
    const string originalEtc = getEnv("GUIX_CONFIGURATION_DIRECTORY",
        settings.nixConfDir);
    writeFile(settings.nixConfDir + "/signing-key.sec",
        readFile(originalEtc + "/signing-key.sec"));
    writeFile(settings.nixConfDir + "/signing-key.pub",
        readFile(originalEtc + "/signing-key.pub"));
    writeFile(settings.nixConfDir + "/acl", "(acl)");
    chmod((settings.nixConfDir + "/signing-key.sec").c_str(), 0400);
    LocalStore store(false);
    try {
        store.recordGoonixBuild(argv[4], argv[5], argv[6], argv[7],
            "unauthorized-import", false, getEnv("GOONIX_TEST_SIGNATURE"));
    } catch (const AuthenticationError & e) {
        if (string(e.what()).find("unauthorized public key") != string::npos &&
            store.queryGoonixBuildRecords(argv[7], argv[5]).empty()) {
            std::cout << "goonix unauthorized record import: PASS\n";
            store.chooseGoonixOutput(
                "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-a.drv",
                "out", argv[4]);
            if (store.chosenGoonixOutput(
                    "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-a.drv",
                    "out") != argv[4] ||
                !store.chosenGoonixOutput(
                    "/gnu/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-b.drv",
                    "out").empty()) {
                std::cerr << "goonix choice persistence: FAIL\n";
                return 1;
            }
            std::cout << "goonix record and choice persistence: PASS\n";
            return 0;
        }
        throw;
    }
    std::cerr << "goonix unauthorized record import: FAIL (accepted)\n";
    return 1;
}

int main(int argc, char ** argv)
{
    if (argc == 2 && string(argv[1]) == "--check-graph-responses")
        return checkGraphResponses();
    if (argc == 8 && string(argv[3]) == "--check-unauthorized-import")
        return checkUnauthorizedImport(argc, argv);
    if (argc != 3) {
        std::cerr << "usage: records-test DATABASE-DIRECTORY GUIX\n";
        return 2;
    }
    settings.guixProgram = argv[2];
    settings.nixStateDir = argv[1];
    settings.nixStore = settings.nixStateDir + "/store";
    settings.nixDBPath = settings.nixStateDir + "/db";
    settings.nixConfDir = settings.nixStateDir + "/etc";
    settings.nixLogDir = settings.nixStateDir + "/log";
    settings.nixDaemonSocketFile = settings.nixStateDir + "/socket";
    settings.buildUsersGroup = "";
    const string fixtureEtc = getEnv("GUIX_CONFIGURATION_DIRECTORY",
        settings.nixConfDir);
    createDirs(settings.nixConfDir);
    chmod(settings.nixConfDir.c_str(), 0700);
    writeFile(settings.nixConfDir + "/signing-key.sec",
        readFile(fixtureEtc + "/signing-key.sec"));
    writeFile(settings.nixConfDir + "/signing-key.pub",
        readFile(fixtureEtc + "/signing-key.pub"));
    chmod((settings.nixConfDir + "/signing-key.sec").c_str(), 0400);

    BuildRecord vector{"resolved", "derivation", "out", "path", "origin",
        true, "not-signed"};
    const string payload = canonicalBuildRecordPayload(vector);
    const string expectedPayload("goonix-record-v1\0"
        "\1\0\0\0\0\0\0\0"
        "\10\0\0\0\0\0\0\0" "resolved"
        "\12\0\0\0\0\0\0\0" "derivation"
        "\3\0\0\0\0\0\0\0" "out"
        "\4\0\0\0\0\0\0\0" "path"
        "\6\0\0\0\0\0\0\0" "origin"
        "\1\0\0\0\0\0\0\0", 104);
    if (payload != expectedPayload || printHash(hashString(htSHA256, payload)) !=
        "da6009a94a97ea3c50f7528283ec6cc5f0f8d35ff413e0f5b0b562fa561a5002") {
        std::cerr << "goonix canonical record payload vector: FAIL\n";
        return 1;
    }
    auto ambiguousA = vector;
    auto ambiguousB = vector;
    ambiguousA.output = "ou"; ambiguousA.path = "tpath";
    ambiguousB.output = "out"; ambiguousB.path = "path";
    if (canonicalBuildRecordPayload(ambiguousA) ==
        canonicalBuildRecordPayload(ambiguousB)) {
        std::cerr << "goonix canonical record field framing: FAIL\n";
        return 1;
    }
    std::cout << "goonix canonical record payload vectors: PASS\n";

    LocalStore store(false);
    store.initialiseGoonixRecords();

    /* The daemon recomputes output paths: the token path carries the
       derivation's name and the environment names it. */
    const Path token = tokenPath("out", "resolved");
    const string text = "Derive([(\"out\",\"" + token + "\",\"\",\"\")],[],[]," +
        "\"x86_64-linux\",\"/bin/sh\",[],[(\"goonixAddressing\",\"content\"),(" +
        "\"goonixResolved\",\"1\"),(\"out\",\"" + token + "\")])";
    Path drv = store.addTextToStore("resolved.drv", text, PathSet());
    const string hash = printHash(hashString(htSHA256, text));
    store.recordBuild(drv, "out", drv, "local-test", false);
    auto records = store.queryGoonixBuildRecords(hash, "out");
    if (records.size() != 1 || records.at(0).path != drv ||
        records.at(0).signature.empty()) {
        std::cerr << "goonix signing helper with forced stderr: FAIL\n";
        return 1;
    }
    store.recordGoonixBuild(drv, "out", drv, hash, "local-test", false,
        records.at(0).signature);
    if (store.queryGoonixBuildRecords(hash, "out").size() != 1) {
        std::cerr << "goonix authorized record import: FAIL\n";
        return 1;
    }
    std::cout << "goonix signing helper with forced stderr: PASS\n";

    auto replayed = records.at(0);
    replayed.path = store.addTextToStore("replayed-output", "replayed", PathSet());
    try {
        store.recordGoonixBuild(replayed.resolvedDerivation, replayed.output,
            replayed.path, replayed.resolvedHash, replayed.origin,
            replayed.relocationChecked, replayed.signature);
        std::cerr << "goonix record signature path replay: FAIL (accepted)\n";
        return 1;
    } catch (const AuthenticationError &) {
        std::cout << "goonix record signature path replay: PASS\n";
    }

    std::vector<std::function<void(BuildRecord &)>> mutations = {
             [](BuildRecord & r) { r.output = "lib"; },
             [](BuildRecord & r) { r.origin = "replayed-origin"; },
             [](BuildRecord & r) { r.relocationChecked = true; },
             [](BuildRecord & r) { r.resolvedHash = std::string(64, '0'); }};
    for (auto & mutate : mutations) {
        auto tampered = records.at(0);
        mutate(tampered);
        try {
            store.recordGoonixBuild(tampered.resolvedDerivation, tampered.output,
                tampered.path, tampered.resolvedHash, tampered.origin,
                tampered.relocationChecked, tampered.signature);
            std::cerr << "goonix record signature field binding: FAIL\n";
            return 1;
        } catch (const AuthenticationError &) { }
    }
    std::cout << "goonix record signature field binding: PASS\n";

    auto wrongResolved = records.at(0);
    wrongResolved.resolvedDerivation = store.addTextToStore(
        "wrong-resolved.drv", "Derive([],[],[],\"x86_64-linux\",\"/bin/sh\",[],[])", PathSet());
    try {
        store.recordGoonixBuild(wrongResolved.resolvedDerivation,
            wrongResolved.output, wrongResolved.path, wrongResolved.resolvedHash,
            wrongResolved.origin, wrongResolved.relocationChecked,
            wrongResolved.signature);
        std::cerr << "goonix resolved content binding: FAIL\n";
        return 1;
    } catch (const AuthenticationError &) {
        std::cout << "goonix resolved content binding: PASS\n";
        std::cout.flush();
    }

    /* Selection policy: a valid choice is kept, a collected choice is
       repaired from a fact, and an explicit adoption replaces it.  Use a
       fresh resolved derivation so earlier import tests do not add facts. */
    {
        Path outA = store.addTextToStore("sel-a", "result-a", PathSet());
        Path outB = store.addTextToStore("sel-b", "result-b", PathSet());
        const Path selToken = tokenPath("out", "selection");
        const string selText = "Derive([(\"out\",\"" + selToken +
            "\",\"\",\"\")],[],[]," +
            "\"x86_64-linux\",\"/bin/sh\",[],[(\"goonixAddressing\",\"content\"),(" +
            "\"goonixResolved\",\"1\"),(\"out\",\"" + selToken + "\")])";
        Path selDrv = store.addTextToStore("selection.drv", selText, PathSet());
        const string selHash = printHash(hashString(htSHA256, selText));
        const Path original = settings.nixStore +
            "/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-selection.drv";
        store.recordBuild(selDrv, "out", outA, "local-test", false);
        /* First selection picks the valid offered path. */
        Path chosen = store.selectGoonixOutput(original, "out", selHash, outA, false);
        if (chosen != outA) {
            std::cerr << "goonix selection first choice: FAIL\n";
            return 1;
        }
        /* A second, different fact is stored; the local choice is kept. */
        store.recordBuild(selDrv, "out", outB, "server-test", false);
        chosen = store.selectGoonixOutput(original, "out", selHash, outB, false);
        if (chosen != outA) {
            std::cerr << "goonix selection keeps local choice: FAIL\n";
            return 1;
        }
        if (store.queryGoonixBuildRecords(selHash, "out").size() != 2) {
            std::cerr << "goonix selection stores both facts: FAIL\n";
            return 1;
        }
        if (store.queryGoonixConflicts(selHash, "out").empty()) {
            std::cerr << "goonix selection records disagreement: FAIL\n";
            return 1;
        }
        /* Explicit adoption switches the choice. */
        chosen = store.selectGoonixOutput(original, "out", selHash, outB, true);
        if (chosen != outB || store.chosenGoonixOutput(original, "out") != outB) {
            std::cerr << "goonix selection adopt policy: FAIL\n";
            return 1;
        }
        std::cout << "goonix selection policy and conflicts: PASS\n";
        std::cout.flush();
    }

    /* A record must name a strict, non-reserved store path.  Sign the
       mutated fields so the path check (not the signature check) is what
       refuses the record. */
    {
        auto bad = records.at(0);
        bad.path = settings.nixStore +
            "/ttteoeueuuottuuotutetetooueeoutu-token";
        bad.signature = store.signBuildRecord(canonicalBuildRecordPayload(bad));
        try {
            store.recordGoonixBuild(bad.resolvedDerivation, bad.output,
                bad.path, bad.resolvedHash, bad.origin,
                bad.relocationChecked, bad.signature);
            std::cerr << "goonix record reserved path: FAIL (accepted)\n";
            return 1;
        } catch (const AuthenticationError &) {
            std::cout << "goonix record reserved path refused: PASS\n";
        }
        bad.path = "/etc/passwd";
        bad.signature = store.signBuildRecord(canonicalBuildRecordPayload(bad));
        try {
            store.recordGoonixBuild(bad.resolvedDerivation, bad.output,
                bad.path, bad.resolvedHash, bad.origin,
                bad.relocationChecked, bad.signature);
            std::cerr << "goonix record non-store path: FAIL (accepted)\n";
            return 1;
        } catch (const AuthenticationError &) {
            std::cout << "goonix record non-store path refused: PASS\n";
            std::cout.flush();
        }
    }

    settings.nixStateDir += "/unauthorized";
    settings.nixStore = settings.nixStateDir + "/store";
    settings.nixDBPath = settings.nixStateDir + "/db";
    settings.nixConfDir = settings.nixStateDir + "/etc";
    settings.nixLogDir = settings.nixStateDir + "/log";
    settings.nixDaemonSocketFile = settings.nixStateDir + "/socket";
    /* The authenticator caches its ACL for its process lifetime.  The child
       prepares an empty ACL before opening its store and helper. */
    const string unauthorized = settings.nixStateDir;
    Strings args = {argv[0], unauthorized, argv[2],
        "--check-unauthorized-import", drv, "out", drv, hash};
    auto argvChild = stringsToCharPtrs(args);
    setenv("GOONIX_TEST_SIGNATURE", records.at(0).signature.c_str(), 1);
    execv(argv[0], argvChild.data());
    throw SysError("executing unauthorized-import test");
}

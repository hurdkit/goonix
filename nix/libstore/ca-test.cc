// goonix: test vectors for tokens, placeholders and reserved paths.
#include "ca.hh"
#include "deep-scan.hh"
#include "references.hh"
#include "local-store.hh"
#include "globals.hh"
#include <cstdlib>
#include <iostream>
#include <format>
#include <variant>
#include <stdexcept>

#include <fcntl.h>
#include <sys/stat.h>

#include <sys/resource.h>
#include <poll.h>

using namespace nix;
namespace nix {
void checkRewriteForTest(const Path & path, const string & from, const string & to);
void rewriteTreeForTest(const Path & path, const string & from, const string & to);
string encodeReservedForTest(const Hash & digest, bool token);
}

static unsigned failures = 0;

static void check(bool condition, const std::string & name)
{
    if (condition) {
        std::cout << "PASS " << name << '\n';
    } else {
        std::cerr << "FAIL " << name << '\n';
        ++failures;
    }
}

template<class F> static bool throws(F && f)
{
    try { f(); return false; }
    catch (const Error &) { return true; }
}

static void configureIsolatedStore(const Path & root)
{
    settings.nixStateDir = root + "/state";
    settings.nixStore = root + "/store";
    settings.nixDBPath = root + "/db";
    settings.nixConfDir = root + "/etc";
    settings.nixLogDir = root + "/log";
    settings.nixDaemonSocketFile = root + "/socket";
    settings.buildUsersGroup = "";
}

/* A small, strict JSON reader for the shared vectors. It is test code only;
   the daemon itself does not acquire a JSON dependency. */
struct JSON;
using JSONArray = std::vector<JSON>;
using JSONObject = std::map<string, JSON>;
struct JSON : std::variant<std::nullptr_t, bool, uint64_t, string,
    JSONArray, JSONObject>
{
    using variant::variant;
    const JSON & at(const string & key) const
    {
        auto object = std::get_if<JSONObject>(this);
        if (!object) throw std::runtime_error("expected JSON object");
        auto found = object->find(key);
        if (found == object->end())
            throw std::runtime_error("missing JSON vector field: " + key);
        return found->second;
    }
    const string & text() const
    {
        auto value = std::get_if<string>(this);
        if (!value) throw std::runtime_error("expected JSON string");
        return *value;
    }
    uint64_t number() const
    {
        auto value = std::get_if<uint64_t>(this);
        if (!value) throw std::runtime_error("expected JSON integer");
        return *value;
    }
    const JSONArray & array() const
    {
        auto value = std::get_if<JSONArray>(this);
        if (!value) throw std::runtime_error("expected JSON array");
        return *value;
    }
};

class JSONParser
{
    const string input;
    size_t at = 0;
    void whitespace()
    {
        while (at < input.size() &&
            (input[at] == ' ' || input[at] == '\n' ||
             input[at] == '\r' || input[at] == '\t')) ++at;
    }
    bool consume(char c)
    {
        whitespace();
        if (at < input.size() && input[at] == c) { ++at; return true; }
        return false;
    }
    void literal(const char * text)
    {
        size_t length = strlen(text);
        if (input.compare(at, length, text) != 0)
            throw std::runtime_error("invalid JSON literal");
        at += length;
    }
    static void utf8(string & out, unsigned codepoint)
    {
        if (codepoint <= 0x7f) out.push_back(codepoint);
        else if (codepoint <= 0x7ff) {
            out.push_back(0xc0 | (codepoint >> 6));
            out.push_back(0x80 | (codepoint & 0x3f));
        } else {
            if (codepoint >= 0xd800 && codepoint <= 0xdfff)
                throw std::runtime_error("unpaired JSON surrogate");
            out.push_back(0xe0 | (codepoint >> 12));
            out.push_back(0x80 | ((codepoint >> 6) & 0x3f));
            out.push_back(0x80 | (codepoint & 0x3f));
        }
    }
    string parseString()
    {
        whitespace();
        if (at >= input.size() || input[at++] != '"')
            throw std::runtime_error("expected JSON string");
        string result;
        while (at < input.size()) {
            unsigned char c = input[at++];
            if (c == '"') return result;
            if (c < 0x20) throw std::runtime_error("control byte in JSON string");
            if (c != '\\') { result.push_back(c); continue; }
            if (at == input.size()) throw std::runtime_error("truncated JSON escape");
            char escape = input[at++];
            switch (escape) {
                case '"': case '\\': case '/': result.push_back(escape); break;
                case 'b': result.push_back('\b'); break;
                case 'f': result.push_back('\f'); break;
                case 'n': result.push_back('\n'); break;
                case 'r': result.push_back('\r'); break;
                case 't': result.push_back('\t'); break;
                case 'u': {
                    if (at + 4 > input.size())
                        throw std::runtime_error("truncated JSON Unicode escape");
                    unsigned value = 0;
                    for (unsigned i = 0; i < 4; ++i) {
                        char digit = input[at++];
                        value <<= 4;
                        if (digit >= '0' && digit <= '9') value += digit - '0';
                        else if (digit >= 'a' && digit <= 'f') value += digit - 'a' + 10;
                        else if (digit >= 'A' && digit <= 'F') value += digit - 'A' + 10;
                        else throw std::runtime_error("invalid JSON Unicode escape");
                    }
                    utf8(result, value);
                    break;
                }
                default: throw std::runtime_error("unknown JSON escape");
            }
        }
        throw std::runtime_error("unterminated JSON string");
    }
    JSON value()
    {
        whitespace();
        if (at == input.size()) throw std::runtime_error("missing JSON value");
        if (consume('{')) {
            JSONObject object;
            if (consume('}')) return object;
            while (true) {
                string key = parseString();
                if (!consume(':')) throw std::runtime_error("expected JSON colon");
                if (!object.emplace(key, value()).second)
                    throw std::runtime_error("duplicate JSON vector field: " + key);
                if (consume('}')) return object;
                if (!consume(',')) throw std::runtime_error("expected JSON comma");
            }
        }
        if (consume('[')) {
            JSONArray array;
            if (consume(']')) return array;
            while (true) {
                array.push_back(value());
                if (consume(']')) return array;
                if (!consume(',')) throw std::runtime_error("expected JSON comma");
            }
        }
        if (input[at] == '"') return parseString();
        if (input.compare(at, 4, "true") == 0) { literal("true"); return true; }
        if (input.compare(at, 5, "false") == 0) { literal("false"); return false; }
        if (input.compare(at, 4, "null") == 0) { literal("null"); return nullptr; }
        size_t start = at;
        while (at < input.size() && input[at] >= '0' && input[at] <= '9') ++at;
        if (start == at) throw std::runtime_error("invalid JSON number");
        return std::stoull(input.substr(start, at - start));
    }
public:
    explicit JSONParser(const Path & file) : input(readFile(file)) { }
    JSON parse()
    {
        JSON result = value();
        whitespace();
        if (at != input.size()) throw std::runtime_error("trailing JSON input");
        return result;
    }
};

static void checkOutputPathValidation(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    Hash hash = hashString(htSHA256, "attacker-controlled content");
    Derivation drv;
    drv.platform = "x86_64-linux";
    drv.builder = "/bin/sh";
    drv.env["goonixResolved"] = "1";
    drv.outputs["out"] = DerivationOutput(
        settings.nixStore + "/00000000000000000000000000000000-chosen",
        "r:sha256", printHash(hash));
    drv.env["out"] = drv.outputs["out"].path;
    bool accepted = true;
    try {
        store.addTextToStore("fixed.drv", unparseDerivation(drv), PathSet());
    } catch (const Error &) {
        accepted = false;
    }
    check(!accepted, "fixed output path is recomputed, not attacker chosen");

    drv.env.erase("goonixResolved");
    drv.outputs["out"] = DerivationOutput(
        settings.nixStore + "/00000000000000000000000000000001-chosen", "", "");
    drv.env["out"] = drv.outputs["out"].path;
    accepted = true;
    try { store.addTextToStore("unvalidated.drv", unparseDerivation(drv), PathSet()); }
    catch (const Error &) { accepted = false; }
    check(!accepted, "addressing marker cannot bypass output path validation");

    drv.env["goonixAddressing"] = "resolved";
    drv.env["goonixResolved"] = "1";
    drv.env["out"] = drv.outputs["out"].path;
    accepted = true;
    try { store.addTextToStore("resolved-chosen.drv", unparseDerivation(drv), PathSet()); }
    catch (const Error &) { accepted = false; }
    check(!accepted, "resolved-addressed path is recomputed from resolved bytes");

    drv.outputs["out"] = DerivationOutput(
        makePlaceholder(unparseDerivation(drv), "out", "placeholder"), "", "");
    drv.env["goonixResolved"] = "1";
    drv.env["out"] = drv.outputs["out"].path;
    accepted = true;
    try { store.addTextToStore("placeholder.drv", unparseDerivation(drv), PathSet()); }
    catch (const Error &) { accepted = false; }
    check(!accepted, "placeholder output path is bound to the unresolved derivation");
}

static void checkSymlinkModes(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    chmod(settings.nixStore.c_str(), 0755);
    Path output = tokenPath("out", "symlink-output");
    createSymlink(baseNameOf(output), output);
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    chmod(settings.nixStore.c_str(), 0755);
    Path final = finaliseContentOutput(store, output, "out", "symlink-output",
        PathSet{output}, references, narHash, narSize);
    struct stat st;
    if (stat(settings.nixStore.c_str(), &st))
        throw SysError("reading isolated store mode");
    check((st.st_mode & 07777) == 0755, "top-level symlink preserves store mode");
    Path directory = tokenPath("out", "symlink-directory");
    createDirs(directory);
    chmod(directory.c_str(), 0755);
    createSymlink(directory, directory + "/self");
    writeFile(directory + "/reference", directory);
    const timespec times[2] = {{0, UTIME_OMIT}, {1, 0}};
    if (utimensat(AT_FDCWD, (directory + "/self").c_str(), times, AT_SYMLINK_NOFOLLOW) ||
        utimensat(AT_FDCWD, (directory + "/reference").c_str(), times, 0) ||
        utimensat(AT_FDCWD, directory.c_str(), times, 0))
        throw SysError("canonicalising CA test timestamps");
    references.clear();
    final = finaliseContentOutput(store, directory, "out", "symlink-directory",
        PathSet{directory}, references, narHash, narSize);
    if (stat(final.c_str(), &st)) throw SysError("reading final directory mode");
    check((st.st_mode & 07777) == 0755, "nested symlink preserves parent mode");
    check(st.st_mtime == 1, "rewritten directory retains canonical timestamp");
    if (lstat((final + "/self").c_str(), &st)) throw SysError("reading rewritten symlink");
    check(st.st_mtime == 1, "rewritten symlink retains canonical timestamp");
    if (stat((final + "/reference").c_str(), &st)) throw SysError("reading rewritten file");
    check(st.st_mtime == 1, "rewritten file retains canonical timestamp");
}

static void checkStreamingFinalisation(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    Path output = tokenPath("out", "sparse-output");
    int fd = open(output.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) throw SysError("creating sparse CA test output");
    AutoCloseFD close = fd;
    const uint64_t size = 128 * 1024 * 1024;
    if (ftruncate(fd, size)) throw SysError("sizing sparse CA test output");
    const string self = output;
    if (pwrite(fd, self.data(), self.size(), size / 2) != (ssize_t) self.size())
        throw SysError("writing sparse CA self-reference");
    close.close();
    struct rlimit limit;
    if (getrlimit(RLIMIT_AS, &limit)) throw SysError("reading address-space limit");
    if (limit.rlim_cur > 96 * 1024 * 1024) limit.rlim_cur = 96 * 1024 * 1024;
    if (setrlimit(RLIMIT_AS, &limit)) throw SysError("setting CA test memory limit");
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    Path final = finaliseContentOutput(store, output, "out", "sparse-output",
        PathSet{output}, references, narHash, narSize);
    check(pathExists(final), "sparse output finalises within the memory limit");
}

static void checkExistingItemIsUntouched(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    Path token = tokenPath("out", "existing-output");
    createDirs(token);
    writeFile(token + "/reference", token);
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    bool created = false;
    Path final = finaliseContentOutput(store, token, "out", "existing-output",
        PathSet{token}, references, narHash, narSize, {}, "", &created);
    check(created, "a newly moved final tree is owned by its finaliser");
    ValidPathInfo valid;
    valid.path = final;
    valid.hash = narHash;
    valid.narSize = narSize;
    valid.references = references;
    store.registerValidPath(valid);
    Path witness = root + "/witness";
    createDirs(witness);
    writeFile(witness + "/reference", final);
    if (link((final + "/reference").c_str(), (witness + "/linked").c_str()))
        throw SysError("hard-linking early-cutoff witness");
    chmod(final.c_str(), 0555);
    Path againToken = tokenPath("out", "existing-output");
    createDirs(againToken);
    writeFile(againToken + "/reference", againToken);
    Path again = finaliseContentOutput(store, againToken, "out", "existing-output",
        PathSet{againToken}, references, narHash, narSize, {}, "", &created);
    check(!created, "an existing valid final tree is not caller-owned");
    check(again == final, "existing result is reused at the same address");
    check(readFile(final + "/reference") == final,
        "existing self-reference remains in final form");
    check(readFile(witness + "/linked") == final,
        "hard-linked content is not rewritten");

    /* Put a token-form tree at the valid final address.  The old inverse
       check hashes that tree on disk and accepts it; the fixed check must
       refuse it without touching the item or a hard link to its contents. */
    if (chmod((final + "/reference").c_str(), 0600) ||
        chmod((witness + "/linked").c_str(), 0600))
        throw SysError("preparing the same-address collision fixture");
    writeFile(final + "/reference", againToken);
    check(readFile(witness + "/linked") == againToken,
        "collision fixture changed the linked existing item");
    bool collision = throws([&] {
        PathSet ignoredReferences;
        Hash ignoredNAR;
        uint64_t ignoredSize = 0;
        finaliseContentOutput(store, againToken, "out", "existing-output",
            PathSet{againToken}, ignoredReferences, ignoredNAR, ignoredSize);
    });
    check(collision, "corrupt tree at a claimed content address is refused");
    check(readFile(witness + "/linked") == againToken,
        "failed early-cutoff comparison leaves the linked item untouched");
    check(readFile(final + "/reference") == againToken,
        "failed early-cutoff comparison leaves the existing item untouched");
}

static void checkInvalidLeftoverIsReplaced(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    Path token = tokenPath("out", "leftover-output");
    createDirs(token);
    writeFile(token + "/reference", token);
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    Path final = finaliseContentOutput(store, token, "out", "leftover-output",
        PathSet{token}, references, narHash, narSize);
    /* This simulates a daemon death after the rename but before registration.
       The final tree has the right content but is not valid. */
    check(!store.isValidPath(final), "leftover fixture is not registered");
    createDirs(token);
    writeFile(token + "/reference", token);
    bool created = false;
    Path recovered = finaliseContentOutput(store, token, "out", "leftover-output",
        PathSet{token}, references, narHash, narSize, {}, "", &created);
    check(recovered == final, "leftover is recovered at its content address");
    check(created, "recovered leftover belongs to this finalisation");
    check(readFile(final + "/reference") == final,
        "recovered leftover contains the final self reference");
}

static void checkSiblingOutputReferences(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    Path libToken = tokenPath("lib", "multi-lib");
    createDirs(libToken);
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    Path libFinal = finaliseContentOutput(store, libToken, "lib", "multi-lib",
        PathSet{libToken}, references, narHash, narSize);
    Path outToken = tokenPath("out", "multi-out");
    createDirs(outToken);
    writeFile(outToken + "/uses-lib", libToken);
    references.clear();
    Path outFinal = finaliseContentOutput(store, outToken, "out", "multi-out",
        PathSet{outToken, libToken, libFinal}, references, narHash, narSize,
        std::map<Path, Path>{{libToken, libFinal}});
    check(readFile(outFinal + "/uses-lib") == libFinal,
        "sibling token is replaced by its final output path");
    check(references.count(libFinal) == 1,
        "sibling output is registered as a reference");
}

static void checkFinalRootBeforeExistence(const Path & root)
{
    configureIsolatedStore(root);
    createDirs(settings.nixStore);
    Path token = tokenPath("out", "root-before-existence");
    createDirs(token);
    writeFile(token + "/reference", token);
    HashResult ignored;
    PathSet initialReferences = scanForReferences(token, PathSet{token}, ignored);
    initialReferences.erase(token);
    Path final = contentAddressedPath("out", "root-before-existence",
        treeHash(token), initialReferences);
    Pipe ready, proceed;
    ready.create();
    proceed.create();
    pid_t pid = fork();
    if (pid == -1) throw SysError("forking CA rooting test");
    if (pid == 0) {
        try {
            ready.readSide.close();
            proceed.writeSide.close();
            /* The store and its roots file belong to this child, not to the
               parent acting as the collector. This avoids inherited POSIX
               lock ownership. */
            LocalStore store(false);
            store.addTempRoot(token);
            Path roots = settings.nixStateDir + "/temproots/" +
                std::to_string(getpid());
            writeFull(ready.writeSide, roots + "\n");
            char byte;
            if (read(proceed.readSide, &byte, 1) != 1)
                throw Error("rooting test did not receive proceed signal");
            PathSet references;
            Hash narHash;
            uint64_t narSize = 0;
            Path result = finaliseContentOutput(store, token, "out",
                "root-before-existence", PathSet{token}, references,
                narHash, narSize);
            check(result == final, "rooting fixture selected expected final path");
            check(references.count(final) == 1,
                "rooting fixture includes its final self reference");
            _exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE);
        } catch (const std::exception & e) {
            try { std::cerr << "rooting child: " << e.what() << '\n'; } catch (...) { }
            _exit(EXIT_FAILURE);
        }
    }
    Pid child = pid;
    ready.writeSide.close();
    proceed.readSide.close();
    Path roots = readLine(ready.readSide);
    check(!roots.empty(), "rooting child created its temporary roots file");
    AutoCloseFD lock = openLockFile(roots, false);
    if (!lockFile(lock, ltRead, true)) throw Error("locking collector roots");
    writeFull(proceed.writeSide, "go\n");
    pollfd completion = {ready.readSide.borrow(), POLLIN | POLLHUP, 0};
    int readyResult = poll(&completion, 1, 1000);
    string contents = readFile(roots, true);
    bool rooted = false;
    size_t at = 0;
    while (at < contents.size()) {
        size_t end = contents.find('\0', at);
        if (end == string::npos) break;
        if (contents.substr(at, end - at) == final) rooted = true;
        at = end + 1;
    }
    check(readyResult == 0 && pathExists(token),
        "finalisation waits for the temporary-roots read lock");
    /* A collector holds this lock while taking its snapshot. addTempRoot
       excludes it before the final path can be checked, moved or reused. */
    check(!rooted,
        "final path cannot enter the store while the collector snapshot is blocked");
    lockFile(lock, ltNone, true);
    check(child.wait(true) == 0, "rooting child completes after collector lock releases");
    contents = readFile(roots, true);
    check(contents.find(final + '\0') != string::npos,
        "final path is rooted before the finaliser can complete");
    check(readFile(final + "/reference") == final,
        "rooted final tree is intact after the lock handoff");
}

static void checkSharedVectors(const Path & file, const Path & root)
{
    settings.nixStore = "/gnu/store";
    JSON vectors = JSONParser(file).parse();
    check(vectors.at("format").number() == 1, "shared vector format is 1");
    auto field = [&](const JSON & object, const string & name) {
        return object.at(name).text();
    };
    auto tokens = vectors.at("tokens");
    auto out = field(tokens, "out");
    auto lib = field(tokens, "lib");
    check(selfToken("out") == out, "shared self token vector");
    check(selfToken("lib") == lib, "shared lib token vector");
    check(tokenPath("out", "hello-1.0") ==
        "/gnu/store/" + out + "-hello-1.0", "shared token path vector");
    auto placeholder = vectors.at("placeholder");
    Path placeholderPath = makePlaceholder(field(placeholder, "derivationBytes"),
        field(placeholder, "output"), field(placeholder, "name"));
    check(placeholderPath == "/gnu/store/" + field(placeholder, "hash") + "-" +
        field(placeholder, "name"), "shared placeholder vector");

    if (pathExists(root)) deletePath(root);
    createDirs(root);
    auto trees = vectors.at("trees");
    for (auto & vector : trees.array()) {
        auto name = field(vector, "name");
        auto kind = field(vector, "kind");
        Path path = root + "/" + name;
        if (kind == "regular") {
            string bytes;
            for (auto & byte : vector.at("bytes").array())
                bytes.push_back((char) byte.number());
            writeFile(path, bytes);
            chmod(path.c_str(), vector.at("executable").number() ? 0555 : 0444);
        } else if (kind == "symlink")
            createSymlink(field(vector, "target"), path);
        else if (kind == "directory") {
            createDirs(path);
            for (auto & entry : vector.at("entries").array()) {
                string bytes;
                for (auto & byte : entry.at("bytes").array())
                    bytes.push_back((char) byte.number());
                Path child = path + "/" + field(entry, "name");
                writeFile(child, bytes);
                chmod(child.c_str(), 0444);
            }
        }
        else throw Error("unknown shared tree vector kind");
        check(printHash(treeHash(path)) == field(vector, "sha256"),
            "shared tree vector: " + name);
    }
    /* Create these in reverse lexical order: the expected digest must come
       from the specified byte ordering, not from directory insertion order. */
    Path ordered = root + "/ordered";
    createDirs(ordered);
    writeFile(ordered + "/z-last", "z");
    writeFile(ordered + "/a-first", "a");
    createSymlink("m-target", ordered + "/m-link");
    for (auto & file : {ordered + "/z-last", ordered + "/a-first"})
        chmod(file.c_str(), 0444);
    check(printHash(treeHash(ordered)) ==
        field(vectors.at("orderedDirectory"), "sha256"),
        "shared directory entry ordering vector");

    auto content = vectors.at("contentPaths");
    Hash empty = parseHash(htSHA256,
        field(trees.array().front(), "sha256"));
    PathSet references;
    for (auto & reference : content.at("references").array())
        references.insert(reference.text());
    check(contentAddressedPath("out", "hello", empty, {}) ==
        field(content, "withoutReferences"), "shared content path vector");
    check(contentAddressedPath("out", "hello", empty, references) ==
        field(content, "withReferences"),
        "shared content path with sorted references vector");

    auto resolved = vectors.at("resolvedDerivation");
    string bytes = field(resolved, "bytes");
    Derivation parsed = parseDerivationText(bytes);
    check(unparseDerivation(parsed) == bytes,
        "shared resolved derivation canonical bytes");
    check(resolvedAddressedPath("out", "hello", bytes) ==
        field(resolved, "resolvedPath"), "shared resolved-addressed path vector");
    check(resolvedAddressedPath("lib", "hello-lib", bytes) ==
        field(resolved, "resolvedLibPath"),
        "shared resolved-addressed sibling path vector");

    auto unresolved = vectors.at("unresolvedDerivation");
    string unresolvedBytes = field(unresolved, "bytes");
    Derivation unresolvedParsed = parseDerivationText(unresolvedBytes);
    check(unparseDerivation(unresolvedParsed) == unresolvedBytes,
        "shared unresolved derivation canonical bytes");
    check(unresolvedParsed.outputs.size() == 2 &&
        unresolvedParsed.inputDrvs.size() == 1,
        "shared unresolved derivation has two outputs and an input derivation");
    check(makePlaceholder(unresolvedBytes, field(unresolved, "output"),
            field(unresolved, "name")) == "/gnu/store/" +
            field(unresolved, "placeholderHash") + "-" + field(unresolved, "name"),
        "shared placeholder bytes match the unresolved derivation serializer");

    auto recordVector = vectors.at("record");
    BuildRecord record;
    record.resolvedHash = field(recordVector, "resolvedHash");
    record.resolvedDerivation = field(recordVector, "derivation");
    record.output = field(recordVector, "output");
    record.path = field(recordVector, "path");
    record.origin = field(recordVector, "origin");
    record.relocationChecked = recordVector.at("relocationChecked").number();
    string payload = canonicalBuildRecordPayload(record);
    string expectedPayload;
    for (auto & byte : recordVector.at("payload").array())
        expectedPayload.push_back((char) byte.number());
    check(payload == expectedPayload, "shared canonical record payload bytes");
    check(printHash(hashString(htSHA256, payload)) == field(recordVector, "sha256"),
        "shared canonical record payload hash");
}

static void checkStagedToken(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    Path token = tokenPath("out", "ca-relocation");
    Path staged = settings.nixStore + "/.goonix-tmp-test";
    createDirs(staged);
    writeFile(staged + "/reference", token);
    createSymlink(baseNameOf(token), staged + "/link");
    createDirs(staged + "/" + baseNameOf(token));
    writeFile(staged + "/executable", "#!/bin/sh\n");
    chmod((staged + "/executable").c_str(), 0555);
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    Path final = finaliseContentOutput(store, token, "out", "ca-relocation",
        PathSet{token}, references, narHash, narSize, {}, staged);
    check(readFile(final + "/reference") == final,
        "staged physical path retains the logical self token");
    check(readLink(final + "/link") == baseNameOf(final),
        "staged symlink is rewritten against the logical token");
}

static void checkSiblingOrder(const Path & root)
{
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    Derivation drv;
    drv.outputs["lib"] = DerivationOutput(tokenPath("lib", "multi-lib"), "", "");
    drv.outputs["out"] = DerivationOutput(tokenPath("out", "multi-out"), "", "");
    Path out = drv.outputs["out"].path;
    createDirs(out);
    writeFile(out + "/uses-lib", drv.outputs["lib"].path);
    createDirs(drv.outputs["lib"].path);
    auto order = contentOutputOrder(drv, PathSet{out, drv.outputs["lib"].path});
    check(order.size() == 2 && order.front().first == "lib",
        "referenced sibling is finalised before its dependent");
}

static void checkOpaqueUtf(const Path & root)
{
    configureIsolatedStore(root);
    string token = baseNameOf(tokenPath("out", "utf")).substr(0, 32);
    for (unsigned width : {2, 4}) {
        Path file = root + (width == 2 ? "/utf16" : "/utf32");
        string bytes;
        for (char c : token) {
            bytes.push_back(c);
            for (unsigned i = 1; i < width; ++i) bytes.push_back(0);
        }
        writeFile(file, bytes);
        string replacement(token.size(), 'x');
        check(throws([&] { checkRewriteForTest(file, token, replacement); }),
            width == 2 ? "UTF-16 self-reference is refused" :
                         "UTF-32 self-reference is refused");
    }
}

static void checkOpaqueFragmentBoundary(const Path & root)
{
    configureIsolatedStore(root);
    Path token = tokenPath("out", "fragment");
    Path file = root + "/fragment";
    string hash = baseNameOf(token).substr(0, 32);
    size_t split = 128 * 1024 - 31;
    string contents(split, 'x');
    contents += hash.substr(0, 1);
    contents += hash.substr(1, 7);
    contents += "tail";
    writeFile(file, contents);
    check(throws([&] { checkRewriteForTest(file, hash, hash); }),
        "opaque fragment split across a read boundary is refused");
}

static void checkInverseFragmentBoundary(const Path & root)
{
    configureIsolatedStore(root);
    Path file = root + "/inverse-fragment";
    string hash = baseNameOf(tokenPath("out", "inverse")).substr(0, 32);
    string contents(128 * 1024 - 31, 'x');
    contents += hash.substr(0, 1);
    contents += hash.substr(1, 7);
    contents += "tail";
    writeFile(file, contents);
    check(throws([&] { checkRewriteForTest(file, hash, hash); }),
        "inverse fragment split across a read boundary is refused");
}

static void checkDeepCompressedSelfToken(const Path & root)
{
    ::unsetenv("GOONIX_DEEP_SCAN_HELPER");
    settings.set("goonix-deep-scan-helper", "");
    Path installedHelper = deepScanHelperPath();
    check(!installedHelper.empty() && installedHelper[0] == '/' &&
        installedHelper.find('$') == string::npos,
        std::format("installed helper path is expanded: {}", installedHelper));
    configureIsolatedStore(root);
    LocalStore store(false);
    createDirs(settings.nixStore);
    chmod(settings.nixStore.c_str(), 0755);
    Path directory = settings.nixStore + "/" + baseNameOf(tokenPath("out", "deep-scan"));
    createDirs(directory);
    string token = baseNameOf(directory).substr(0, 32);
    Path archive = root + "/member.gz";
    writeFile(archive, readFile("tests/fixtures/ca-self-token.gz"));
    writeFile(directory + "/member.gz", readFile(archive));
    PathSet references;
    Hash narHash;
    uint64_t narSize = 0;
    settings.set("goonix-deep-scan", "false");
    Path final = finaliseContentOutput(store, directory, "out", "deep-scan",
        PathSet{directory}, references, narHash, narSize);
    check(!final.empty() && pathExists(final), "ordinary finalisation accepts a compressed self token");
    deletePath(final);

    /* The environment override is how a build-tree daemon finds its helper. */
    createDirs(directory);
    writeFile(directory + "/member.gz", readFile(archive));
    ::setenv("GOONIX_DEEP_SCAN_HELPER", (root + "/missing-from-environment").c_str(), 1);
    settings.set("goonix-deep-scan", "true");
    bool environmentMissing = false;
    try { checkDeepOutput(directory, StringSet{token}); }
    catch (const Error & error) {
        environmentMissing = string(error.what()).find("unavailable") != string::npos;
    }
    check(environmentMissing, "missing helper from the environment refuses deep scanning");
    settings.set("goonix-deep-scan", "false");
    references.clear();
    final = finaliseContentOutput(store, directory, "out", "deep-scan",
        PathSet{directory}, references, narHash, narSize);
    check(!final.empty() && pathExists(final),
        "missing helper does not affect ordinary finalisation");
    deletePath(final);
    ::unsetenv("GOONIX_DEEP_SCAN_HELPER");

    directory = settings.nixStore + "/" + baseNameOf(tokenPath("out", "deep-scan"));
    createDirs(directory);
    writeFile(directory + "/member.gz", readFile(archive));
    references.clear();
    settings.set("goonix-deep-scan", "true");
    if (getEnv("GOONIX_DEEP_SCAN_HELPER").empty())
        settings.set("goonix-deep-scan-helper", absPath("goonix-ca-scan"));
    bool rejected = false;
    try { checkDeepOutput(directory, StringSet{token}); }
    catch (const Error & error) {
        string message = error.what();
        rejected = message.find("decompressed") != string::npos &&
            message.find("member.gz") != string::npos;
    }
    check(rejected, "daemon rejects a found token from the helper");

    settings.set("goonix-deep-scan-helper", root + "/missing-helper");
    check(throws([&] { checkDeepOutput(directory, StringSet{token}); }),
        "missing helper refuses finalisation");
    Path crash = root + "/crash-helper";
    writeFile(crash, readFile("nix/ca-scan-crash"));
    chmod(crash.c_str(), 0755);
    settings.set("goonix-deep-scan-helper", crash);
    bool crashRefused = false;
    try { checkDeepOutput(directory, StringSet{token}); }
    catch (const Error & error) {
        crashRefused = string(error.what()).find("crashed") != string::npos;
    }
    check(crashRefused, "helper crash refuses finalisation");
    Path stall = root + "/stall-helper";
    writeFile(stall, readFile("nix/ca-scan-stall"));
    chmod(stall.c_str(), 0755);
    settings.set("goonix-deep-scan-helper", stall);
    settings.set("goonix-deep-scan-timeout", "1");
    bool timeoutRefused = false;
    try { checkDeepOutput(directory, StringSet{token}); }
    catch (const Error & error) {
        timeoutRefused = string(error.what()).find("exceeded") != string::npos;
    }
    check(timeoutRefused, "helper timeout refuses finalisation");

    unsigned cleanups = 0;
    auto countCleanup = [&] { ++cleanups; };
    settings.set("goonix-deep-scan-helper", absPath("goonix-ca-scan"));
    bool foundAgain = false;
    try {
        checkDeepOutput(directory, StringSet{token}, (uid_t) -1, (gid_t) -1,
            countCleanup);
    } catch (const Error &) { foundAgain = true; }
    check(foundAgain && cleanups == 1, "deep scan cleanup runs after a refusal");
    settings.set("goonix-deep-scan-helper", root + "/missing-helper");
    bool missingAgain = false;
    try {
        checkDeepOutput(directory, StringSet{token}, (uid_t) -1, (gid_t) -1,
            countCleanup);
    } catch (const Error &) { missingAgain = true; }
    check(missingAgain && cleanups == 2, "deep scan cleanup runs after helper failure");
    settings.set("goonix-deep-scan-helper", absPath("goonix-ca-scan"));
    bool originalError = false;
    try {
        checkDeepOutput(directory, StringSet{token}, (uid_t) -1, (gid_t) -1,
            [] { throw Error("cleanup failure"); });
    } catch (const Error & error) {
        originalError = string(error.what()).find("unresolved goonix self token") != string::npos;
    }
    check(originalError, "cleanup failure does not replace a scan refusal");
    settings.set("goonix-deep-scan", "false");
    checkDeepOutput(directory, StringSet{token}, (uid_t) -1, (gid_t) -1,
        countCleanup);
    check(cleanups == 2, "disabled deep scan does not run cleanup");
}

int main(int argc, char ** argv)
{
    if (argc == 3 && string(argv[1]) == "--opaque-utf") {
        checkOpaqueUtf(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--inverse-fragment") {
        checkInverseFragmentBoundary(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--fragment-boundary") {
        checkOpaqueFragmentBoundary(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--deep-scan") {
        checkDeepCompressedSelfToken(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--sibling-order") {
        checkSiblingOrder(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--staged") {
        checkStagedToken(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 4 && string(argv[1]) == "--shared-vectors") {
        checkSharedVectors(argv[2], argv[3]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--leftover") {
        checkInvalidLeftoverIsReplaced(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--final-root") {
        checkFinalRootBeforeExistence(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--siblings") {
        checkSiblingOutputReferences(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--existing-item") {
        checkExistingItemIsUntouched(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--streaming") {
        checkStreamingFinalisation(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--symlink-modes") {
        checkSymlinkModes(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && string(argv[1]) == "--path-validation") {
        checkOutputPathValidation(argv[2]);
        return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc != 1) {
        /* A check that does not exist must not pass as the vectors below. */
        std::cerr << "ca-test: unknown check `" << argv[1] << "'\n";
        return EXIT_FAILURE;
    }
    settings.nixStore = "/gnu/store";

    auto out = selfToken("out");
    check(out.size() == 32 && out[0] != 'e'
        && out.find_first_not_of("eout") == std::string::npos
        && out == selfToken("out"), "self token shape and determinism");
    check(out != selfToken("lib"), "self token depends on output");
    check(isTokenStorePath(tokenPath("out", "hello-1.0")),
        "token path has store shape");
    auto placeholder = makePlaceholder("drv bytes", "out", "hello-1.0");
    check(isPlaceholderPath(placeholder), "placeholder has store shape");
    check(!isPlaceholderPath(tokenPath("out", "hello-1.0")),
        "self token is not placeholder");
    check(validateTokenPath(out + "-hello-1.0") == out + "-hello-1.0",
        "token basename validates");
    check(throws([] { validateTokenPath("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-hello"); }),
        "unknown placeholder fails closed");
    check(throws([] { validateTokenPath("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello"); }),
        "ordinary base32 is not a token");

    /* Upstream's remove-store-references marker is 32 'e' characters.  It is
       ordinary upstream data, so it is NOT a reserved goonix name; and no
       goonix name may BE it, so encodeReserved bumps such a placeholder's
       last character to 'o'.  Vector: an ALL-ZERO digest encodes to a
       leading 'e', 30 more 'e's and a final 'o'.  Must match reserved-hash
       in guix/ca.scm, which is checked against the same vector there. */
    {
        std::string marker(32, 'e');
        Hash zero(htSHA256);
        memset(zero.hash, 0, zero.hashSize);
        check(encodeReservedForTest(zero, false)
                  == marker.substr(0, 31) + "o",
            "all-zero digest encodes to e...eo, never the nuke-refs marker");
        check(encodeReservedForTest(zero, true)[0] != 'e',
            "a self token never starts with 'e', even for an all-zero digest");
        check(!isReservedStorePath(settings.nixStore + "/" + marker + "-hello"),
            "upstream nuke-refs marker is not a reserved store path");
        check(!isPlaceholderPath(settings.nixStore + "/" + marker + "-hello"),
            "upstream nuke-refs marker is not a placeholder");
        check(isPlaceholderPath(settings.nixStore + "/" + marker.substr(0, 31)
                                + "o-hello"),
            "the bumped e...eo encoding is still a placeholder");
    }

    /* goonix: a hard-linked executable keeps its executable bit through the
       rewrite.  Measured on CA-8's binutils-mesboot0 and CA-6's gcc: the
       inverse mapping failed, and the kept trees showed 8 files in
       i686-unknown-linux-gnu/bin/ at 0444 whose twins in bin/ were 0555, with
       identical bytes.  Cause: rewriteRegularFile starts with
       chmod(path, 0600), and chmod changes the mode of the INODE, so every
       hard link of that file loses S_IXUSR at once.  rewriteTree stats each
       entry as it reaches it, so the twin visited later computes
       (st_mode & S_IXUSR) ? 0555 : 0444 from the already-cleared mode and is
       installed non-executable.  The tree hash covers the executable bit, so
       the inverse no longer matches and finalisation is refused.
       Proven separately with a two-link file: chmod(a, 0600) leaves b at 0600
       with S_IXUSR=0. */
    {
        Path root = createTempDir("", "goonix-hardlink-mode");
        AutoDelete delRoot(root, true);
        std::string token(32, 't'), replacement(32, 'u');
        Path bin = root + "/bin", twin = root + "/i686/bin";
        createDirs(bin);
        createDirs(twin);
        Path first = bin + "/ar", second = twin + "/ar";
        writeFile(first, "/gnu/store/" + token + "-binutils/bin/ar\n");
        chmod(first.c_str(), 0555);
        if (link(first.c_str(), second.c_str()))
            throw SysError("linking the test twin");
        struct stat before;
        lstat(second.c_str(), &before);
        check((before.st_mode & 07777) == 0555 && before.st_nlink == 2,
            "the test fixture really is a hard-linked executable pair");

        rewriteTreeForTest(root, token, replacement);

        struct stat a, b;
        lstat(first.c_str(), &a);
        lstat(second.c_str(), &b);
        check((a.st_mode & S_IXUSR) != 0,
            "the first hard-linked executable stays executable");
        check((b.st_mode & S_IXUSR) != 0,
            "the hard-linked twin keeps its executable bit through the rewrite");
        check((a.st_mode & 07777) == (b.st_mode & 07777),
            "both hard-linked twins end with the same mode");
    }

    /* goonix: the same property across SEVERAL rewrite passes over one tree.
       A multi-output derivation rewrites the tree once per sibling output and
       then once for its own token (finaliseContentOutput), so an executable
       must survive every pass, not just the first.

       This is a PROPERTY test, not the regression test for the chmod fix:
       measured, it passes on 460360f28bb as well, because that commit's
       per-pass capture already restored 0555 before the next pass stat'ed.
       It is kept because the property is worth pinning now that the capture
       map is gone and the mode comes straight from the inode. */
    {
        Path root = createTempDir("", "goonix-hardlink-passes");
        AutoDelete delRoot(root, true);
        std::string sibling(32, 's'), siblingTo(32, 'v');
        std::string self(32, 't'), selfTo(32, 'u');
        createDirs(root + "/bin");
        createDirs(root + "/triplet/bin");
        Path first = root + "/bin/ld", second = root + "/triplet/bin/ld";
        writeFile(first, "/gnu/store/" + sibling + "-gcc/lib /gnu/store/"
                  + self + "-gcc/bin\n");
        chmod(first.c_str(), 0555);
        if (link(first.c_str(), second.c_str()))
            throw SysError("linking the test twin");

        /* Two passes, as a two-output derivation does. */
        rewriteTreeForTest(root, sibling, siblingTo);
        rewriteTreeForTest(root, self, selfTo);

        struct stat a, b;
        lstat(first.c_str(), &a);
        lstat(second.c_str(), &b);
        check((a.st_mode & S_IXUSR) != 0,
            "an executable stays executable across two rewrite passes");
        check((b.st_mode & S_IXUSR) != 0,
            "its hard-linked twin stays executable across two rewrite passes");
    }

    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

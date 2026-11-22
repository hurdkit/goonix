#include "ca.hh"
#include "deep-scan.hh"
#include "local-store.hh"
#include "archive.hh"
#include "globals.hh"
#include "references.hh"
#include "misc.hh"
#include <algorithm>
#include <array>
#include <cstring>
#include <format>
#include <map>
#include <set>
#include <functional>
#include <vector>
#include <fstream>
#include <iostream>
#include <cstdio>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nix {

static const string alphabet = "eout";
static const string treeDomain("goonix-tree-v1\0", 15);
static const string contentDomain("goonix-content-v1\0", 18);

/* Upstream's remove-store-references (guix/build/utils.scm) writes 32 'e'
   characters followed by '-' as its nuke-refs marker, into every file it
   processes and into every output that ships Guix's build modules.  That
   string must never be a goonix name, so it is not reserved.  To keep the
   exemption sound rather than fail-open, encodeReserved bumps a
   placeholder's last character to 'o' when all 31 encoded characters would
   be 'e': no placeholder can then be that string.  The cost is that one
   digest shares its name with the digest encoding to e...eo, a 2^-62
   collision - the same order as the collision 62 bits already allow between
   any two placeholders.  Tokens start with 'o', 'u' or 't' and are
   unaffected.  Keep in step with reserved-hash in guix/ca.scm. */
static const string nukeMarker(32, 'e');

static string encodeReserved(const Hash & digest, bool token)
{
    string result(32, 'e');
    result[0] = token ? alphabet[1 + digest.hash[0] % 3] : 'e';
    for (unsigned i = 1; i < 32; ++i) {
        unsigned bit = 2 + 2 * (i - 1);
        result[i] = alphabet[(digest.hash[bit / 8] >> (6 - bit % 8)) & 3];
    }
    if (!token && result == nukeMarker)
        result[31] = 'o';
    return result;
}

static void checkOutputName(const string & name)
{
    if (name.empty() || name.find('/') != string::npos || name.starts_with('.'))
        throw Error(std::format("invalid CA output name `{}'", name));
    for (char c : name)
        if (!(isalnum((unsigned char) c) || strchr("+-._?=", c)))
            throw Error(std::format("invalid CA output name `{}'", name));
}

string selfToken(const string & output)
{
    checkOutputName(output);
    return encodeReserved(hashString(htSHA256, "goonix:self-token:v1:" + output), true);
}

Path tokenPath(const string & output, const string & name)
{
    return settings.nixStore + "/" + selfToken(output) + "-" + name;
}

Path makePlaceholder(const string & unresolvedBytes, const string & output,
    const string & name)
{
    checkOutputName(output);
    string prefix = "goonix:placeholder:v1:" + std::to_string(unresolvedBytes.size())
        + ":" + output + ":";
    return settings.nixStore + "/" +
        encodeReserved(hashString(htSHA256, prefix + unresolvedBytes), false)
        + "-" + name;
}

/* The one shared predicate: a reserved hash part is 32 characters of the
   reserved alphabet, EXCEPT upstream's nuke-refs marker (see nukeMarker
   above), which is ordinary upstream data and never a goonix name. */
static bool reservedHashPart(std::string_view part)
{
    return part.size() == 32
        && part.find_first_not_of(alphabet) == string::npos
        && part != nukeMarker;
}

static bool reservedPath(const Path & path)
{
    if (!isStorePath(path) || path.size() < settings.nixStore.size() + 35)
        return false;
    auto base = baseNameOf(path);
    if (base.size() < 34 || base[32] != '-') return false;
    return reservedHashPart(base.substr(0, 32));
}

bool isReservedStorePath(const Path & path) { return reservedPath(path); }
bool isPlaceholderPath(const Path & path)
{
    return reservedPath(path) && baseNameOf(path)[0] == 'e';
}
bool isTokenStorePath(const Path & path)
{
    return reservedPath(path) && baseNameOf(path)[0] != 'e';
}
void assertNotReserved(const Path & path)
{
    if (reservedPath(path))
        throw Error(std::format("refusing unresolved goonix token or placeholder `{}'", path));
}
string validateTokenPath(const string & path)
{
    if (!isTokenStorePath(path) && !isTokenStorePath(settings.nixStore + "/" + path))
        throw Error(std::format("invalid goonix self token `{}'", path));
    return path;
}

Addressing addressingOf(const Derivation & drv)
{
    auto it = drv.env.find("goonixAddressing");
    if (it == drv.env.end()) return Addressing::input;
    if (it->second == "content") return Addressing::content;
    if (it->second == "resolved") return Addressing::resolved;
    throw Error(std::format("unknown goonix addressing `{}'", it->second));
}
bool goonixAddressed(const Derivation & drv)
{
    return addressingOf(drv) != Addressing::input;
}
bool resolvedDerivation(const Derivation & drv)
{
    auto it = drv.env.find("goonixResolved");
    return it != drv.env.end() && it->second == "1";
}

/* CA-4 mixed policy (plan 3.1): an input-addressed derivation has only
   input-addressed and fixed-output inputs.  A direct content/resolved input
   would make its output path unknowable before the build, so refuse it
   loudly rather than silently producing an unbuildable derivation. */
void checkInputAddressedPolicy(LocalStore & store, const Derivation & drv)
{
    if (goonixAddressed(drv)) return;
    for (auto & input : drv.inputDrvs) {
        /* Only judge inputs we can actually read; an absent input is caught
           by the normal validity machinery, not by the addressing policy. */
        if (!store.isValidPath(input.first)) continue;
        auto inDrv = derivationFromPath(store, input.first);
        if (goonixAddressed(inDrv))
            throw Error(std::format(
                "input-addressed derivation depends on content/resolved-addressed `{0}'; "
                "mark the dependent as content-addressed too (goonix mixed policy)",
                input.first));
    }
}

/* A resolved derivation is a pure function of the machine's choices: every
   input is a realised store path, outputs are self tokens (content) or final
   paths (resolved/fixed), and the environment names each output. */
void checkResolvedDerivation(const Derivation & drv)
{
    if (!resolvedDerivation(drv))
        throw Error("goonix: derivation is not marked resolved");
    if (!drv.inputDrvs.empty())
        throw Error("goonix: resolved derivation still has floating inputs");
    Addressing addressing = addressingOf(drv);
    for (auto & output : drv.outputs) {
        const Path & path = output.second.path;
        bool fixed = !output.second.hash.empty();
        if (fixed) {
            if (!isStorePathStrict(path))
                throw Error(std::format("goonix: invalid fixed output `{0}'", path));
        } else if (addressing == Addressing::content) {
            if (!isTokenStorePath(path))
                throw Error(std::format(
                    "goonix: content output `{0}' is not a self token", path));
        } else if (addressing == Addressing::resolved) {
            if (!isStorePathStrict(path))
                throw Error(std::format(
                    "goonix: resolved output `{0}' is not a final store path", path));
        } else
            throw Error("goonix: resolved derivation has input addressing");
        /* If an environment entry names this output it must agree; the
           builder environment is synchronised to the chosen paths at build
           time, so a stored resolved derivation may omit it. */
        auto env = drv.env.find(output.first);
        if (env != drv.env.end() && env->second != path)
            throw Error(std::format(
                "goonix: resolved output `{0}' disagrees with its environment",
                output.first));
    }
    /* No placeholder may survive resolution, anywhere it could leak. */
    const string storePrefix = settings.nixStore + "/";
    auto scan = [&](const string & value) {
        size_t at = 0;
        while ((at = value.find(storePrefix, at)) != string::npos) {
            size_t end = at + storePrefix.size();
            while (end < value.size() && value[end] != '/' &&
                   value[end] != '"' && value[end] != '\'' &&
                   value[end] != ' ' && value[end] != '\n' &&
                   value[end] != '\t' && value[end] != ')' &&
                   value[end] != '(' && value[end] != ',')
                ++end;
            Path candidate = value.substr(at, end - at);
            if (isPlaceholderPath(candidate))
                throw Error(std::format(
                    "goonix: unresolved placeholder `{0}' in resolved derivation",
                    candidate));
            at = end;
        }
    };
    scan(drv.builder);
    for (auto & arg : drv.args) scan(arg);
    for (auto & entry : drv.env) scan(entry.second);
}

/* Return content outputs in dependency order: an output that refers to a
   sibling's token is finalised after that sibling.  Cycles are refused. */
std::vector<std::pair<string, Path>> contentOutputOrder(
    const Derivation & drv, const PathSet & allPaths,
    const Path & chrootRootDir)
{
    std::vector<std::pair<string, Path>> result;
    std::map<Path, string> outputs;
    for (auto & output : drv.outputs)
        outputs[output.second.path] = output.first;
    std::set<Path> visiting, done;
    std::function<void(const Path &)> visit = [&](const Path & path) {
        if (done.count(path)) return;
        if (!visiting.insert(path).second)
            throw BuildError("cycle between content-addressed sibling outputs");
        Path physical = chrootRootDir + path;
        HashResult ignored;
        PathSet references = scanForReferences(physical, allPaths, ignored);
        for (auto & sibling : outputs) {
            if (sibling.first == path) continue;
            if (references.count(sibling.first))
                visit(sibling.first);
        }
        visiting.erase(path);
        done.insert(path);
        result.push_back({outputs.at(path), path});
    };
    for (auto & output : drv.outputs) visit(output.second.path);
    return result;
}

void checkGoonixRegistration(const Path & path, const Derivation & drv)
{
    /* Placeholders and resolved/token paths are intentionally not
       historical output:ID paths.  Validate their shape during resolution. */
    bool ca = drv.env.find("goonixAddressing") != drv.env.end();
    bool resolved = resolvedDerivation(drv);
    if (ca && !resolved) {
        for (auto & output : drv.outputs) {
            if (!isReservedStorePath(output.second.path))
                throw Error(std::format("unresolved CA output `{}' is not a placeholder",
                    output.second.path));
            if (drv.env.at(output.first) != output.second.path)
                throw Error(std::format("CA output `{}' disagrees with its environment",
                    output.first));
        }
    } else if (resolved) {
        checkResolvedDerivation(drv);
    }
}

void checkGoonixBatchRegistration(LocalStore & store, const Path & path,
    const Derivation & drv)
{
    if (drv.env.find("goonixAddressing") != drv.env.end())
        checkGoonixDerivationOutputs(path, drv);
    else if (resolvedDerivation(drv))
        throw Error(std::format(
            "goonix: derivation `{0}' is marked resolved without an addressing",
            path));
    else
        checkInputAddressedPolicy(store, drv);
}

void checkGoonixDerivationOutputs(const Path & drvPath, const Derivation & drv)
{
    string name = storePathToName(drvPath);
    if (name.ends_with(drvExtension)) name.resize(name.size() - drvExtension.size());
    Derivation blank = drv;
    for (auto & output : blank.outputs) {
        output.second.path = "";
        blank.env[output.first] = "";
    }
    const string bytes = unparseDerivation(blank);
    Derivation resolved = drv;
    resolved.env.erase("goonixResolved");
    for (auto & output : resolved.outputs) {
        if (!output.second.hash.empty()) continue;
        string outputName = storePathToName(output.second.path);
        output.second.path = tokenPath(output.first, outputName);
        resolved.env[output.first] = output.second.path;
    }
    /* The resolver hashes the token-form resolved derivation before adding
       goonixResolved; the marker is stripped from builder environments. */
    const string provisionalBytes = unparseDerivation(resolved);
    for (auto & output : drv.outputs) {
        bool recursive;
        HashType hashType;
        Hash hash;
        Path expected;
        if (!output.second.hash.empty()) {
            output.second.parseHashInfo(recursive, hashType, hash);
            expected = makeFixedOutputPath(recursive, hashType, hash,
                name + (output.first == "out" ? "" : "-" + output.first));
        } else if (addressingOf(drv) == Addressing::content) {
            expected = tokenPath(output.first,
                name + (output.first == "out" ? "" : "-" + output.first));
            if (!resolvedDerivation(drv))
                expected = makePlaceholder(bytes, output.first,
                    name + (output.first == "out" ? "" : "-" + output.first));
        } else if (addressingOf(drv) == Addressing::resolved) {
            expected = resolvedDerivation(drv)
                ? resolvedAddressedPath(output.first,
                    name + (output.first == "out" ? "" : "-" + output.first),
                    provisionalBytes)
                : makePlaceholder(bytes, output.first,
                    name + (output.first == "out" ? "" : "-" + output.first));
        } else {
            /* Registration routes input-addressed derivations through the
               ordinary path check, and refuses a resolved mark without an
               explicit addressing.  This branch is therefore unreachable. */
            throw Error(std::format(
                "goonix: input-addressed output `{0}' reached CA validation",
                output.first));
        }
        if (output.second.path != expected)
            throw Error(std::format(
                "goonix: output `{0}' has incorrect path `{1}', expected `{2}'",
                output.first, output.second.path, expected));
        Path expectedEnvironment = expected;
        if (goonixAddressed(drv) && !resolvedDerivation(drv) &&
            output.second.hash.empty())
            expectedEnvironment = tokenPath(output.first,
                name + (output.first == "out" ? "" : "-" + output.first));
        auto env = drv.env.find(output.first);
        if (env == drv.env.end() || env->second != expectedEnvironment)
            throw Error(std::format(
                "goonix: output `{0}' has an incorrect environment path", output.first));
    }
}

static void put64(string & out, uint64_t value)
{
    for (unsigned i = 0; i < 8; ++i) out.push_back((value >> (i * 8)) & 0xff);
}
static void putBytes(string & out, const string & bytes)
{
    put64(out, bytes.size());
    out += bytes;
}
static void putBytes(string & out, const unsigned char * bytes, size_t size)
{
    put64(out, size);
    out.append((const char *) bytes, size);
}

static Hash hashTree(const Path & path, unsigned depth)
{
    if (depth > 1024) throw Error("CA tree nesting exceeds 1024 directories");
    struct stat st;
    if (lstat(path.c_str(), &st))
        throw SysError(std::format("reading CA tree `{}'", path));
    if (S_ISREG(st.st_mode)) {
        string header = treeDomain;
        header.push_back(1);
        /* Match the NAR writer's canonical executable marker. */
        header.push_back(st.st_mode & S_IXUSR ? 1 : 0);
        int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
        if (fd == -1) throw SysError(std::format("opening `{}' for CA hash", path));
        AutoCloseFD close = fd;
        std::vector<unsigned char> buffer(128 * 1024);
        /* The file's length and bytes are one framed field. */
        put64(header, st.st_size);
        HashSink sink(htSHA256);
        sink((const unsigned char *) header.data(), header.size());
        while (true) {
            ssize_t n = read(fd, buffer.data(), buffer.size());
            if (n < 0) { if (errno == EINTR) continue;
                throw SysError(std::format("reading `{}' for CA hash", path)); }
            if (n == 0) break;
            sink(buffer.data(), n);
        }
        return sink.finish().first;
    }
    string encoding = treeDomain;
    if (S_ISLNK(st.st_mode)) {
        encoding.push_back(2);
        putBytes(encoding, readLink(path));
        return hashString(htSHA256, encoding);
    }
    if (S_ISDIR(st.st_mode)) {
        encoding.push_back(3);
        auto entries = readDirectory(path);
        std::sort(entries.begin(), entries.end(), [](const DirEntry & a, const DirEntry & b) {
            return std::lexicographical_compare(a.name.begin(), a.name.end(),
                b.name.begin(), b.name.end(), [](unsigned char x, unsigned char y) { return x < y; });
        });
        put64(encoding, entries.size());
        for (auto & entry : entries) {
            putBytes(encoding, entry.name);
            auto child = printHash(hashTree(path + "/" + entry.name, depth + 1));
            putBytes(encoding, child);
        }
        return hashString(htSHA256, encoding);
    }
    throw Error(std::format("unsupported file type in CA tree `{}'", path));
}
Hash treeHash(const Path & path) { return hashTree(path, 0); }

Path contentAddressedPath(const string & output, const string & name,
    const Hash & tree, const PathSet & references)
{
    string bytes = contentDomain;
    putBytes(bytes, tree.hash, tree.hashSize);
    put64(bytes, references.size());
    for (auto & reference : references) putBytes(bytes, reference);
    return makeStorePath("goonix-content:" + output,
        hashString(htSHA256, bytes), name);
}

Path resolvedAddressedPath(const string & output, const string & name,
    const string & resolvedBytes)
{
    return makeStorePath("goonix-resolved:" + output,
        hashString(htSHA256, resolvedBytes), name);
}

static string replaceWhole(string input, const string & from, const string & to,
    const string & file, bool rejectOpaque = true)
{
    if (from.size() != to.size()) throw Error("internal CA token length mismatch");
    size_t at = 0;
    while ((at = input.find(from, at)) != string::npos) {
        input.replace(at, from.size(), to);
        at += to.size();
    }
    if (!rejectOpaque) return input;
    /* Compiler-emitted fragments and UTF encodings are opaque, not rewritable.
       Name the file and the byte offset of the offending fragment (plan 4.2). */
    for (size_t i = 0; i + 8 <= from.size(); ++i) {
        auto fragment = from.substr(i, 8);
        auto at = input.find(fragment);
        if (at != string::npos)
            throw BuildError(std::format(
                "opaque self-reference fragment `{0}' in `{1}' at byte {2}",
                fragment, file, at));
    }
    for (unsigned width : {2, 4}) {
        string encoded;
        for (char c : from) {
            encoded.push_back(c);
            for (unsigned j = 1; j < width; ++j) encoded.push_back(0);
        }
        auto at = input.find(encoded);
        if (at != string::npos)
            throw BuildError(std::format("UTF-{} self-reference in `{}' at byte {}",
                width * 8, file, at));
    }
    return input;
}

/* goonix: rewrite in bounded chunks.  Retaining the previous token's tail
   catches matches spanning a read boundary; no output-sized string is made. */
static void rewriteRegularFile(const Path & path, const string & from,
    const string & to, mode_t mode)
{
    /* goonix: make the original READABLE if it is not, and never clear a bit. */
    struct stat original;
    if (lstat(path.c_str(), &original))
        throw SysError(std::format("reading `{}' for CA rewrite", path));
    if (!(original.st_mode & S_IRUSR)
        && chmod(path.c_str(), (original.st_mode & 07777) | S_IRUSR))
        throw SysError(std::format("making `{}' readable for CA rewrite", path));
    Path temporary = path + ".goonix-rewrite";
    if (pathExists(temporary))
        throw BuildError(std::format("CA temporary file `{0}' already exists", temporary));
    AutoDelete cleanup(temporary, false);
    int input = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (input < 0) throw SysError(std::format("opening `{}' for CA rewrite", path));
    AutoCloseFD inputFD = input;
    int output = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (output < 0) throw SysError(std::format("creating `{}'", temporary));
    AutoCloseFD outputFD = output;
    std::vector<unsigned char> buffer(128 * 1024);
    string pending;
    while (true) {
        ssize_t n = read(inputFD, buffer.data(), buffer.size());
        if (n < 0) { if (errno == EINTR) continue;
            throw SysError(std::format("reading `{}' for CA rewrite", path)); }
        if (n == 0) break;
        pending.append((const char *) buffer.data(), n);
        /* Keep enough bytes for a UTF-32LE token that crosses the read
           boundary, not merely a plain token. */
        size_t keep = from.size() * 4 - 1;
        size_t process = pending.size() > keep ? pending.size() - keep : 0;
        /* A prefix of FROM at the end is a potential whole match crossing
           the next read, not an opaque fragment at this boundary. */
        for (size_t length = std::min(process, from.size() - 1); length > 0; --length)
            if (pending.compare(process - length, length, from, 0, length) == 0) {
                process -= length;
                break;
            }
        string rewritten = replaceWhole(pending.substr(0, process), from, to, path);
        writeFull(outputFD, rewritten);
        pending.erase(0, process);
    }
    writeFull(outputFD, replaceWhole(pending, from, to, path));
    if (fchmod(outputFD, mode)) throw SysError(std::format("restoring `{}'", path));
    if (futimens(outputFD, (const timespec[2]) {{0, UTIME_OMIT}, {1, 0}}))
        throw SysError(std::format("restoring timestamp of `{}'", path));
    outputFD.close();
    if (rename(temporary.c_str(), path.c_str()))
        throw SysError(std::format("installing rewritten `{}'", path));
    cleanup.cancel();
}

void checkRewriteForTest(const Path & path, const string & from, const string & to)
{
    rewriteRegularFile(path, from, to, 0444);
}

/* goonix: expose the whole-tree rewrite so a test can pin the mode of every
   entry, including hard-linked twins.  Defined after rewriteTree itself. */
void rewriteTreeForTest(const Path & path, const string & from, const string & to);

string encodeReservedForTest(const Hash & digest, bool token)
{
    return encodeReserved(digest, token);
}

static void checkReserved(const Path & path, const string & bytes)
{
    /* The normal reference scanner only knows base32 hashes.  Reserved
       paths deliberately use the other alphabet, so scan for them here.
       The shared predicate exempts upstream's nuke-refs marker. */
    for (size_t offset = 0; offset + 33 <= bytes.size(); ++offset) {
        if (bytes[offset] != 'e') continue;
        if (!reservedHashPart(std::string_view(bytes).substr(offset, 32)))
            continue;
        if (bytes[offset + 32] != '-') continue;
        throw BuildError(std::format("unresolved goonix placeholder in `{}' at byte {}",
            path, offset));
    }
}

static void checkReservedFile(const Path & path)
{
    int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (fd < 0) throw SysError(std::format("scanning `{}'", path));
    AutoCloseFD input = fd;
    std::vector<unsigned char> buffer(128 * 1024);
    string pending;
    while (true) {
        ssize_t n = read(input, buffer.data(), buffer.size());
        if (n < 0) { if (errno == EINTR) continue;
            throw SysError(std::format("reading `{}' for CA scan", path)); }
        if (n == 0) break;
        pending.append((const char *) buffer.data(), n);
        if (pending.size() > 32) {
            checkReserved(path, pending);
            /* goonix: retain the reserved pattern's 32 bytes, not 31:
               its trailing '-' may be in the next read. */
            pending.erase(0, pending.size() - 32);
        }
    }
    checkReserved(path, pending);
}

static void checkReservedTree(const Path & path, unsigned depth = 0,
    const string & logicalName = "")
{
    if (depth > 1024) throw BuildError("CA tree nesting exceeds limit");
    struct stat st;
    if (lstat(path.c_str(), &st)) throw SysError(std::format("scanning `{}'", path));
    checkReserved(path, depth == 0 && !logicalName.empty() ?
        logicalName : baseNameOf(path));
    if (S_ISDIR(st.st_mode)) {
        for (auto & entry : readDirectory(path))
            checkReservedTree(path + "/" + entry.name, depth + 1);
    } else if (S_ISREG(st.st_mode)) {
        checkReservedFile(path);
    } else if (S_ISLNK(st.st_mode)) {
        checkReserved(path, readLink(path));
    } else throw BuildError(std::format("unsupported CA output file `{}'", path));
}

static void rewriteTree(const Path & path, const string & from, const string & to,
    unsigned depth = 0, bool outputRoot = true)
{
    if (depth > 1024) throw BuildError("CA tree nesting exceeds limit");
    struct stat st;
    if (lstat(path.c_str(), &st)) throw SysError(std::format("reading `{}' for CA rewrite", path));
    if (S_ISDIR(st.st_mode)) {
        mode_t originalMode = st.st_mode & 07777;
        if (chmod(path.c_str(), 0700))
            throw SysError(std::format("making CA directory `{}' writable", path));
        try {
            auto entries = readDirectory(path);
            for (auto & entry : entries)
                rewriteTree(path + "/" + entry.name, from, to, depth + 1, false);
            for (auto & entry : entries) {
                auto name = replaceWhole(entry.name, from, to, path + "/" + entry.name);
                if (name != entry.name) {
                    if (name.empty() || name == "." || name == ".." || name.find('/') != string::npos)
                        throw BuildError(std::format("invalid CA file name in `{}'", path));
                    if (rename((path + "/" + entry.name).c_str(), (path + "/" + name).c_str()))
                        throw SysError(std::format("renaming `{}' for CA", path + "/" + entry.name));
                }
            }
            const timespec times[2] = {{0, UTIME_OMIT}, {1, 0}};
            if (utimensat(AT_FDCWD, path.c_str(), times, 0))
                throw SysError(std::format("restoring timestamp of `{}'", path));
            if (chmod(path.c_str(), originalMode))
                throw SysError(std::format("restoring mode of `{}'", path));
        } catch (...) {
            chmod(path.c_str(), originalMode);
            throw;
        }
        /* The parent may need renaming after its contents, not before. */
    } else if (S_ISREG(st.st_mode)) {
        rewriteRegularFile(path, from, to,
            (st.st_mode & S_IFMT) | ((st.st_mode & S_IXUSR) ? 0555 : 0444));
    } else if (S_ISLNK(st.st_mode)) {
        string target = replaceWhole(readLink(path), from, to, path);
        if (target != readLink(path)) {
            Path parent = dirOf(path);
            struct stat parentStat;
            if (lstat(parent.c_str(), &parentStat))
                throw SysError(std::format("reading parent of `{}'", path));
            /* The output root's parent is the store.  Never change its
               mode: it is outside the output tree and already writable. */
            bool insideOutput = !outputRoot;
            if (insideOutput && chmod(parent.c_str(), 0700))
                throw SysError(std::format("making parent of `{}' writable", path));
            /* goonix: restore the parent's mode, never the symlink's 0777. */
            try {
                Path replacement = path + ".goonix-new-link";
                if (pathExists(replacement))
                    throw BuildError(std::format("CA temporary symlink `{0}' already exists", replacement));
                createSymlink(target, replacement);
                if (rename(replacement.c_str(), path.c_str()))
                    throw SysError(std::format("replacing symlink `{}'", path));
                const timespec times[2] = {{0, UTIME_OMIT}, {1, 0}};
                if (utimensat(AT_FDCWD, path.c_str(), times, AT_SYMLINK_NOFOLLOW))
                    throw SysError(std::format("restoring timestamp of `{}'", path));
                if (chmod(parent.c_str(), parentStat.st_mode & 07777))
                    throw SysError(std::format("restoring parent mode of `{}'", path));
            } catch (...) {
                chmod(parent.c_str(), parentStat.st_mode & 07777);
                throw;
            }
        }
    } else throw BuildError(std::format("unsupported CA output file `{}'", path));
}

void rewriteTreeForTest(const Path & path, const string & from, const string & to)
{
    rewriteTree(path, from, to);
}

static string inverseTree(const Path & path, const string & final,
    const string & token, const std::map<Path, Path> & siblings = {}, unsigned depth = 0)
{
    if (depth > 1024) throw Error("CA tree nesting exceeds 1024 directories");
    struct stat st;
    if (lstat(path.c_str(), &st))
        throw SysError(std::format("reading CA tree `{}'", path));
    auto inverse = [&](string value) {
        value = replaceWhole(value, final, token, path, false);
        for (auto it = siblings.rbegin(); it != siblings.rend(); ++it)
            value = replaceWhole(value, baseNameOf(it->second).substr(0, 32),
                baseNameOf(it->first).substr(0, 32), path, false);
        return value;
    };
    if (S_ISREG(st.st_mode)) {
        string header = treeDomain;
        header.push_back(1);
        header.push_back(st.st_mode & S_IXUSR ? 1 : 0);
        int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
        if (fd < 0) throw SysError(std::format("opening `{}' for CA verification", path));
        AutoCloseFD input = fd;
        std::vector<unsigned char> buffer(128 * 1024);
        string pending;
        put64(header, st.st_size);
        HashSink sink(htSHA256);
        sink((const unsigned char *) header.data(), header.size());
        auto write = [&](const string & part) {
            sink((const unsigned char *) part.data(), part.size());
        };
        while (true) {
            ssize_t n = read(input, buffer.data(), buffer.size());
            if (n < 0) { if (errno == EINTR) continue;
                throw SysError(std::format("reading `{}' for CA verification", path)); }
            if (n == 0) break;
            pending.append((const char *) buffer.data(), n);
            size_t keep = final.size() - 1;
            size_t process = pending.size() > keep ? pending.size() - keep : 0;
            for (size_t length = std::min(process, final.size() - 1); length > 0; --length)
                if (pending.compare(process - length, length, final, 0, length) == 0) {
                    process -= length;
                    break;
                }
            write(inverse(pending.substr(0, process)));
            pending.erase(0, process);
        }
        write(inverse(pending));
        return printHash(sink.finish().first);
    }
    string encoding = treeDomain;
    if (S_ISLNK(st.st_mode)) {
        encoding.push_back(2);
        putBytes(encoding, inverse(readLink(path)));
        return printHash(hashString(htSHA256, encoding));
    }
    if (S_ISDIR(st.st_mode)) {
        encoding.push_back(3);
        auto entries = readDirectory(path);
        std::sort(entries.begin(), entries.end(), [&](const DirEntry & a, const DirEntry & b) {
            return inverse(a.name) < inverse(b.name);
        });
        put64(encoding, entries.size());
        for (auto & entry : entries) {
            string name = inverse(entry.name);
            putBytes(encoding, name);
            putBytes(encoding, inverseTree(path + "/" + entry.name,
                final, token, siblings, depth + 1));
        }
        return printHash(hashString(htSHA256, encoding));
    }
    throw Error(std::format("unsupported file type in CA tree `{}'", path));
}

/* goonix: compare the inverse tree without writing to an existing store item. */
static bool sameContent(const Path & path, const string & final,
    const string & token, const Hash & expected,
    const std::map<Path, Path> & siblings = {})
{
    return inverseTree(path, baseNameOf(final).substr(0, 32),
        baseNameOf(token).substr(0, 32), siblings) == printHash(expected);
}

Path finaliseContentOutput(LocalStore & store, const Path & token,
    const string & output, const string & name, const PathSet & allPaths,
    PathSet & references, Hash & narHash, uint64_t & narSize,
    const std::map<Path, Path> & finalOutputs, const Path & actualTokenPath,
    bool * created)
{
    if (created) *created = false;
    const Path physical = actualTokenPath.empty() ? token : actualTokenPath;
    PathSet referencePaths = allPaths;
    for (auto & sibling : finalOutputs)
        referencePaths.insert(sibling.second);
    checkReservedTree(physical, 0, baseNameOf(token));
    for (auto & sibling : finalOutputs)
        if (sibling.first != token)
            rewriteTree(physical, baseNameOf(sibling.first).substr(0, 32),
                baseNameOf(sibling.second).substr(0, 32));
    HashResult initial;
    PathSet initialReferences = scanForReferences(physical, referencePaths, initial);
    Hash built = treeHash(physical);
    PathSet namingReferences = initialReferences;
    namingReferences.erase(token);
    Path final = contentAddressedPath(output, name, built, namingReferences);
    /* Root before any existence check or scan.  A collector holding the
       temporary-roots lock must finish before we reuse or publish this path. */
    store.addTempRoot(final);
    referencePaths.insert(final);
    string oldHash = baseNameOf(token).substr(0, 32);
    string newHash = baseNameOf(final).substr(0, 32);

    /* An existing store item is never overwritten (plan: finalisation).
       A content address names its content, so an identical result is the
       same item: verify the round trip against it and reuse it.  A
       different tree at the same address is a collision or corruption and
       is refused rather than clobbered. */
    if (pathExists(final)) {
        /* A final path produced by an earlier output of this same build is
           not registered until the whole output set is checked. */
        bool stagedSibling = false;
        for (auto & sibling : finalOutputs)
            stagedSibling = stagedSibling || sibling.second == final ||
                (physical == sibling.first && final == sibling.second);
        if (!store.isValidPath(final) && !stagedSibling) {
            /* A daemon that died between the rename and registration leaves
               an unregistered tree here.  The token lock prevents another
               build of this output from concurrently creating it.  The new
               token tree has independently selected this content address;
               replace the leftover and prove the inverse mapping below. */
            deletePath(final);
        }
        if (pathExists(final) && stagedSibling && !store.isValidPath(final)) {
            /* A previous output of this build already produced this path.
               Verify it and leave registration to the output-set commit. */
            bool same = sameContent(final, final, token, built, finalOutputs);
            if (!same)
                throw BuildError(std::format(
                    "CA content address collision at `{0}': existing item differs", final));
            deletePath(physical);
            HashResult existingNAR;
            references = scanForReferences(final, referencePaths, existingNAR);
            auto result = hashPath(htSHA256, final);
            narHash = result.first;
            narSize = result.second;
            return final;
        }
        if (pathExists(final)) {
            bool same = sameContent(final, final, token, built, finalOutputs);
            if (!same)
                throw BuildError(std::format(
                    "CA content address collision at `{0}': existing item differs", final));
            deletePath(physical);
            HashResult existingNAR;
            references = scanForReferences(final, referencePaths, existingNAR);
            auto result = hashPath(htSHA256, final);
            narHash = result.first;
            narSize = result.second;
            return final;
        }
    }

    rewriteTree(physical, oldHash, newHash);
    /* Renaming self references necessarily changes this tree's hash.
       Verification is the inverse mapping performed below. */
    if (rename(physical.c_str(), final.c_str()))
        throw SysError(std::format("moving CA output `{}' to `{}'", physical, final));
    if (created) *created = true;
    /* goonix: the inverse mapping is verified without touching the final tree. */
    bool good = sameContent(final, final, token, built, finalOutputs);
    if (!good) {
        deletePath(final);
        throw BuildError(std::format("CA inverse mapping failed for `{}'", final));
    }
    HashResult finalNAR;
    references = scanForReferences(final, referencePaths, finalNAR);
    auto result = hashPath(htSHA256, final);
    narHash = result.first;
    narSize = result.second;
    return final;
}

Derivation resolveDerivation(LocalStore & store, const Path & unresolvedPath,
    const Derivation & unresolved,
    std::function<Path(const Path &, const Derivation &, const string &)> realised)
{
    Derivation resolved = unresolved;
    std::map<string, string> replacements;
    for (auto & input : unresolved.inputDrvs) {
        auto inDrv = derivationFromPath(store, input.first);
        for (auto & output : input.second) {
            Path chosen = realised(input.first, inDrv, output);
            replacements[inDrv.outputs.at(output).path] = chosen;
            resolved.inputSrcs.insert(chosen);
        }
    }
    auto substitute = [&](string value) {
        for (auto & replacement : replacements) {
            size_t at = 0;
            while ((at = value.find(replacement.first, at)) != string::npos) {
                value.replace(at, replacement.first.size(), replacement.second);
                at += replacement.second.size();
            }
        }
        return value;
    };
    resolved.builder = substitute(resolved.builder);
    for (auto & arg : resolved.args)
        arg = substitute(arg);
    for (auto & entry : resolved.env) entry.second = substitute(entry.second);
    resolved.inputDrvs.clear();
    for (auto & output : resolved.outputs) {
        /* First remove every unresolved placeholder.  Content outputs stay
           at their token paths; resolved outputs are assigned below. */
        if (!output.second.hash.empty()) continue;
        string name = storePathToName(output.second.path);
        output.second.path = tokenPath(output.first, name);
        resolved.env[output.first] = output.second.path;
    }
    resolved.env["goonixResolved"] = "1";
    resolved.env.erase("goonixResolved");
    const string pathBytes = unparseDerivation(resolved);
    resolved.env["goonixResolved"] = "1";
    for (auto & output : resolved.outputs) {
        if (!output.second.hash.empty() ||
            addressingOf(unresolved) != Addressing::resolved) continue;
        string name = storePathToName(unresolved.outputs.at(output.first).path);
        output.second.path = resolvedAddressedPath(output.first, name, pathBytes);
    }
    /* Every output's environment entry names its resolved path, not just
       `out'; multi-output derivations must stay consistent. */
    for (auto & output : resolved.outputs)
        resolved.env[output.first] = output.second.path;
    checkResolvedDerivation(resolved);
    return resolved;
}

Derivation resolveDerivation(LocalStore & store, const Path & unresolvedPath,
    const Derivation & unresolved)
{
    return resolveDerivation(store, unresolvedPath, unresolved,
        [&](const Path & path, const Derivation & drv, const string & output) {
            return store.realisedOutputPath(path, drv, output);
        });
}

Path writeResolvedDerivation(LocalStore & store, const Path & originalPath,
    const Derivation & resolved)
{
    checkResolvedDerivation(resolved);
    /* The original name already ends in `.drv'; writeDerivation appends
       that suffix itself.  Keep exactly one to preserve output names. */
    string name = storePathToName(originalPath);
    if (name.ends_with(drvExtension)) name.resize(name.size() - drvExtension.size());
    return writeDerivation(store, resolved, name);
}

}

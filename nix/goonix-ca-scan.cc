// goonix: decompress and inspect CA outputs outside the daemon's process.
// Exit values are part of the daemon protocol: 0 clean, 1 found, 2 error.
#include "archive.hh"
#include "util.hh"
#include <archive.h>
#include <archive_entry.h>
#include <zlib.h>
#include <algorithm>
#include <cstring>
#include <format>
#include <iostream>
#include <memory>
#include <set>
#include <string>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace nix;

static const string reservedAlphabet = "eout";
/* Upstream's remove-store-references marker: 32 'e' characters.  It is
   ordinary upstream data, never a goonix name (encodeReserved bumps a
   placeholder that would encode to it), so this scanner exempts it exactly
   as reservedHashPart in nix/libstore/ca.cc does. */
static const string nukeRefsMarker(32, 'e');
static const size_t overlapSize = 32;

static string decoderError(const char * message)
{
    return message ? message : "unknown error";
}

struct GzipCloser {
    void operator()(gzFile input) { if (input) gzclose(input); }
};
using Gzip = std::unique_ptr<gzFile_s, GzipCloser>;

struct ArchiveCloser {
    void operator()(archive * reader) { archive_read_free(reader); }
};
using Archive = std::unique_ptr<archive, ArchiveCloser>;

struct Scanner {
    Path root;
    StringSet tokens;

    [[noreturn]] void fail(const string & message)
    {
        throw Error(message);
    }

    void inspect(const Path & file, const string & pending, uint64_t base)
    {
        for (size_t offset = 0; offset + 32 <= pending.size(); ++offset) {
            if (reservedAlphabet.find(pending[offset]) == string::npos) continue;
            string candidate = pending.substr(offset, 32);
            if (candidate.find_first_not_of(reservedAlphabet) != string::npos)
                continue;
            if (candidate == nukeRefsMarker) continue;
            string hash = candidate;
            bool self = tokens.count(hash);
            /* A known output token is itself a leftover, even when it is not
               a full store path.  An unknown reserved hash is a placeholder
               only in path shape, with the following '-'. */
            if (!self && (offset + 33 > pending.size() || pending[offset + 32] != '-'))
                continue;
            string kind = self ? "self-token" : "placeholder";
            std::cout << kind << "\t" << base + offset << "\t" << file << '\n' << std::flush;
            _exit(1);
        }
    }

    void consume(const Path & file, string & pending, const char * bytes,
        size_t length, uint64_t & total)
    {
        pending.append(bytes, length);
        total += length;
        inspect(file, pending, total - pending.size());
        /* A complete token is 32 bytes; an unknown reserved hash needs '-'
           too.  Retain exactly 32 bytes across reads. */
        if (pending.size() > overlapSize) pending.erase(0, pending.size() - overlapSize);
    }

    void gzip(const Path & file)
    {
        Gzip input(gzopen(file.c_str(), "rb"));
        if (!input) fail(std::format("opening deep CA gzip `{}'", file));
        std::vector<char> buffer(128 * 1024);
        string pending;
        uint64_t total = 0;
        while (true) {
            int length = gzread(input.get(), buffer.data(), buffer.size());
            if (length < 0) {
                int code = Z_OK;
                string message = decoderError(gzerror(input.get(), &code));
                std::cerr << "skipped\t" << file << "\t" << message << '\n';
                return;
            }
            if (!length) break;
            consume(file, pending, buffer.data(), length, total);
        }
        /* The owner closes only after we release it: exactly one close. */
        int result = gzclose(input.release());
        if (result != Z_OK)
            std::cerr << "skipped\t" << file << "\tclosing gzip: " << result << '\n';
    }

    void archive(const Path & file, bool xz, bool bzip2, bool zip)
    {
        Archive reader(archive_read_new());
        if (!reader) fail(std::format("allocating deep CA reader `{}'", file));
        if (xz) archive_read_support_filter_xz(reader.get());
        if (bzip2) archive_read_support_filter_bzip2(reader.get());
        if (zip) archive_read_support_format_zip(reader.get());
        if (!zip) archive_read_support_format_raw(reader.get());
        if (archive_read_open_filename(reader.get(), file.c_str(), 128 * 1024) != ARCHIVE_OK) {
            std::cerr << "skipped\t" << file << "\t"
                      << decoderError(archive_error_string(reader.get())) << '\n';
            return;
        }
        archive_entry * entry = nullptr;
        int result;
        while ((result = archive_read_next_header(reader.get(), &entry)) == ARCHIVE_OK) {
            if (archive_entry_filetype(entry) != AE_IFREG) continue;
            std::vector<char> buffer(128 * 1024);
            string pending;
            uint64_t total = 0;
            while (true) {
                ssize_t length = archive_read_data(reader.get(), buffer.data(), buffer.size());
                if (length < 0) {
                    std::cerr << "skipped\t" << file << "\t"
                              << decoderError(archive_error_string(reader.get())) << '\n';
                    return;
                }
                if (!length) break;
                consume(file, pending, buffer.data(), length, total);
            }
        }
        if (result != ARCHIVE_EOF)
            std::cerr << "skipped\t" << file << "\t"
                      << decoderError(archive_error_string(reader.get())) << '\n';
        if (archive_read_close(reader.get()) != ARCHIVE_OK)
            std::cerr << "skipped\t" << file << "\t"
                      << decoderError(archive_error_string(reader.get())) << '\n';
    }

    void file(const Path & path)
    {
        int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW);
        if (fd < 0) throw SysError(std::format("opening deep CA input `{}'", path));
        AutoCloseFD input = fd;
        unsigned char magic[6];
        ssize_t count = read(input, magic, sizeof(magic));
        if (count < 0) throw SysError(std::format("reading deep CA input `{}'", path));
        if (count >= 2 && magic[0] == 0x1f && magic[1] == 0x8b) gzip(path);
        else if (count == 6 && memcmp(magic, "\xfd" "7zXZ\0", 6) == 0)
            archive(path, true, false, false);
        else if (count >= 3 && memcmp(magic, "BZh", 3) == 0)
            archive(path, false, true, false);
        else if (count >= 4 && memcmp(magic, "PK\003\004", 4) == 0)
            archive(path, false, false, true);
    }

    void tree(const Path & path, unsigned depth = 0)
    {
        if (depth > 1024) fail("deep CA tree nesting exceeds 1024 directories");
        struct stat st;
        if (lstat(path.c_str(), &st)) throw SysError(std::format("scanning `{}'", path));
        if (S_ISDIR(st.st_mode)) {
            for (auto & entry : readDirectory(path)) tree(path + "/" + entry.name, depth + 1);
        } else if (S_ISREG(st.st_mode)) file(path);
        else if (!S_ISLNK(st.st_mode))
            fail(std::format("unsupported deep CA output file `{}'", path));
    }
};

int main(int argc, char ** argv)
{
    if (argc < 3) {
        std::cerr << "usage: goonix-ca-scan TREE TOKEN...\n";
        return 2;
    }
    try {
        Scanner scanner;
        scanner.root = argv[1];
        for (int i = 2; i < argc; ++i) scanner.tokens.insert(argv[i]);
        scanner.tree(scanner.root);
        return 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 2;
    } catch (...) {
        std::cerr << "unknown deep CA scanner error\n";
        return 2;
    }
}

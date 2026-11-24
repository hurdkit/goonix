// goonix: launch the deep CA decoder with no daemon privileges.
#include "deep-scan.hh"
#include "store-api.hh"
#include "globals.hh"
#include "util.hh"
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <format>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>

namespace nix {

Path deepScanHelperPath()
{
    Path override = getEnv("GOONIX_DEEP_SCAN_HELPER",
        settings.get("goonix-deep-scan-helper", string()));
    return override.empty() ? string(GOONIX_LIBEXEC_DIR) + "/goonix-ca-scan" : override;
}

static void runDeepScanHelper(const Path & tree, const StringSet & tokens,
    uid_t buildUID, gid_t buildGID)
{
    if (!settings.get("goonix-deep-scan", false)) return;
    Path helper = deepScanHelperPath();
    struct stat st;
    if (stat(helper.c_str(), &st) != 0 || !S_ISREG(st.st_mode) || access(helper.c_str(), X_OK) != 0)
        throw BuildError(std::format("deep CA scan helper is unavailable: `{}'", helper));

    Pipe output;
    output.create();
    closeOnExec(output.readSide);
    closeOnExec(output.writeSide);
    Pid child = startProcess([&]() {
        if (setsid() < 0) _exit(2);
        output.readSide.close();
        int nullFD = open("/dev/null", O_RDWR);
        if (nullFD < 0 ||
            dup2(nullFD, STDIN_FILENO) < 0 ||
            dup2(output.writeSide, STDOUT_FILENO) < 0 ||
            dup2(output.writeSide, STDERR_FILENO) < 0)
            _exit(2);
        if (nullFD > STDERR_FILENO) close(nullFD);
        output.writeSide.close();
        closeMostFDs({STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO});

        if (geteuid() == 0) {
            if (buildUID == (uid_t) -1 || buildGID == (gid_t) -1 || buildUID == 0) {
                printMsg(lvlError, "deep CA scan requires an unprivileged build user");
                _exit(2);
            }
            if (setgroups(0, nullptr) != 0 || setgid(buildGID) != 0 || setuid(buildUID) != 0) {
                printMsg(lvlError, std::format("dropping privileges for deep CA scan: {}", strerror(errno)));
                _exit(2);
            }
        } else if (buildUID != (uid_t) -1 && buildUID != geteuid()) {
            /* An unprivileged daemon cannot assume the build user's identity.
               It must not pretend to have performed that privilege drop. */
            printMsg(lvlError, "deep CA scan cannot switch to the build user");
            _exit(2);
        }
        if (geteuid() == 0) _exit(2);

        Strings args = {helper, tree};
        for (auto & token : tokens) args.push_back(token);
        char * emptyEnvironment[] = {nullptr};
        execve(helper.c_str(), stringsToCharPtrs(args).data(), emptyEnvironment);
        _exit(errno == ENOENT ? 127 : 126);
    }, true, "goonix deep CA scan setup: ", false);
    child.setSeparatePG(true);
    output.writeSide.close();

    string diagnostic;
    std::vector<char> buffer(4096);
    bool completed = false;
    int status = 0;
    auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(settings.get("goonix-deep-scan-timeout", 3600));
    int timeout = settings.get("goonix-deep-scan-timeout", 3600);
    while (!completed) {
        struct pollfd pfd{output.readSide, POLLIN, 0};
        int ready = poll(&pfd, 1, 100);
        if (ready < 0) {
            if (errno == EINTR) continue;
            child.kill();
            throw SysError("waiting for deep CA scan output");
        }
        if (ready > 0 && (pfd.revents & (POLLIN | POLLHUP))) {
            ssize_t count = read(output.readSide, buffer.data(), buffer.size());
            if (count < 0 && errno != EINTR) {
                child.kill();
                throw SysError("reading deep CA scan output");
            }
            if (count > 0) {
                if (diagnostic.size() < 65536)
                    diagnostic.append(buffer.data(), std::min<size_t>(count, 65536 - diagnostic.size()));
            } else if (count == 0) output.readSide.close();
        }
        int current = child.wait(false);
        if (current >= 0) { status = current; completed = true; }
        if (!completed && std::chrono::steady_clock::now() >= deadline) {
            child.kill();
            throw BuildError(std::format("deep CA scan helper exceeded its {} second limit", timeout));
        }
    }
    /* Drain any final diagnostic after the child exits. */
    if (output.readSide.isOpen()) {
        while (true) {
            ssize_t count = read(output.readSide, buffer.data(), buffer.size());
            if (count > 0 && diagnostic.size() < 65536)
                diagnostic.append(buffer.data(), std::min<size_t>(count, 65536 - diagnostic.size()));
            else if (count == 0 || (count < 0 && errno != EINTR)) break;
        }
    }
    output.readSide.close();
    if (!WIFEXITED(status))
        throw BuildError(std::format("deep CA scan helper crashed: {}", statusToString(status)));
    int code = WEXITSTATUS(status);
    if (code == 0) {
        if (!diagnostic.empty()) printMsg(lvlInfo, diagnostic);
        return;
    }
    if (code == 1) {
        auto first = diagnostic.find('\t');
        auto second = first == string::npos ? string::npos : diagnostic.find('\t', first + 1);
        if (first == string::npos || second == string::npos)
            throw BuildError(std::format("deep CA scan helper returned malformed found data: {}", diagnostic));
        string kind = diagnostic.substr(0, first);
        string offset = diagnostic.substr(first + 1, second - first - 1);
        string file = diagnostic.substr(second + 1);
        while (!file.empty() && (file.back() == '\n' || file.back() == '\r')) file.pop_back();
        if (kind != "placeholder" && kind != "self-token")
            throw BuildError(std::format("deep CA scan helper returned an unknown finding: {}", kind));
        string description = kind == "placeholder" ? "placeholder" : "self token";
        throw BuildError(std::format("unresolved goonix {0} in decompressed `{1}' at byte {2}",
            description, file, offset));
    }
    if (code == 127)
        throw BuildError(std::format("deep CA scan helper could not be executed: `{}'", helper));
    throw BuildError(std::format("deep CA scan helper failed (status {}): {}", code, diagnostic));
}

void checkDeepOutput(const Path & tree, const StringSet & tokens,
    uid_t buildUID, gid_t buildGID, std::function<void()> cleanup)
{
    if (!settings.get("goonix-deep-scan", false)) return;
    try {
        runDeepScanHelper(tree, tokens, buildUID, buildGID);
    } catch (...) {
        if (cleanup) {
            try { cleanup(); } catch (...) { ignoreException(); }
        }
        throw;
    }
    if (cleanup) cleanup();
}

}

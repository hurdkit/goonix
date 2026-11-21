/* GNU Guix --- Functional package management for GNU
   Copyright (C) 2025 Caleb Ristvedt <reepca@russelstein.xyz>

   This file is part of GNU Guix.

   GNU Guix is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 3 of the License, or (at
   your option) any later version.

   GNU Guix is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.  */

/* Initial standalone plan interpreter derived from nix/libutil/spawn.cc.
   See README.md for the intentionally narrow scope and source relation.  */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifndef __linux__
#error "the initial user namespace helper requires Linux"
#endif

#include <algorithm>
#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <exception>
#include <fcntl.h>
#include <grp.h>
#include <sched.h>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/statvfs.h>
#include <net/if.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <net/route.h>
#include <linux/if_tun.h>
#include <linux/ipv6.h>
#include <linux/audit.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {

using Bytes = std::string;

constexpr size_t maxPlanSize = 1024 * 1024;
constexpr uint32_t noFd = UINT32_MAX;

constexpr uint32_t setIdsFlag = 1;
constexpr uint32_t setSidFlag = 2;
constexpr uint32_t closeFdsFlag = 4;
constexpr uint32_t newUserNsFlag = 8;
constexpr uint32_t inheritEnvFlag = 16;
constexpr uint32_t chdirFlag = 32;
constexpr uint32_t stdinFileFlag = 64;
constexpr uint32_t stdinFdFlag = 128;
constexpr uint32_t clearGroupsFlag = 256;
constexpr uint32_t noNewPrivsFlag = 512;
constexpr uint32_t setupSuccessFlag = 1024;
constexpr uint32_t redirectLogFlag = 2048;
constexpr uint32_t knownFlags = setIdsFlag | setSidFlag | closeFdsFlag |
    newUserNsFlag | inheritEnvFlag | chdirFlag | stdinFileFlag |
    stdinFdFlag | clearGroupsFlag | noNewPrivsFlag | setupSuccessFlag |
    redirectLogFlag;
constexpr uint64_t sandboxFlag = 4096;
constexpr uint64_t mountNamespaceFlag = 8192;
constexpr uint64_t networkNamespaceFlag = 16384;
constexpr uint64_t pidNamespaceFlag = 32768;
constexpr uint64_t ipcNamespaceFlag = 65536;
constexpr uint64_t utsNamespaceFlag = 131072;
constexpr uint64_t chrootFlag = 262144;
constexpr uint64_t procFlag = 524288;
constexpr uint64_t devptsFlag = 1048576;
constexpr uint64_t lockMountsFlag = 2097152;
constexpr uint64_t slirpNetworkFlag = 4194304;
constexpr uint64_t isolateHostLoopbackFlag = 8388608;
constexpr uint64_t ipv6NetworkFlag = 16777216;
constexpr uint64_t namespaceFlags = sandboxFlag | mountNamespaceFlag |
    networkNamespaceFlag | pidNamespaceFlag | ipcNamespaceFlag | utsNamespaceFlag;
constexpr uint64_t sandboxFlags = namespaceFlags | chrootFlag | procFlag |
    devptsFlag | lockMountsFlag;
constexpr uint64_t hostIdentitiesFlag = 33554432;
constexpr uint64_t knownExtendedFlags = sandboxFlags | slirpNetworkFlag |
    isolateHostLoopbackFlag | ipv6NetworkFlag | hostIdentitiesFlag;

class Error : public std::runtime_error {
public:
    explicit Error(const std::string & message) : std::runtime_error(message) { }
};

class SysError : public Error {
public:
    SysError(const std::string & message, int error)
        : Error(message + ": " + std::strerror(error)) { }
    explicit SysError(const std::string & message)
        : SysError(message, errno) { }
};

[[noreturn]] void sysError(const std::string & message)
{
    throw SysError(message);
}

struct Plan {
    uint64_t flags = 0;
    bool extended = false;
    Bytes program;
    std::vector<Bytes> args;
    std::vector<std::pair<Bytes, Bytes>> env;
    Bytes cwd;
    Bytes stdinFile;
    uid_t uid = 0;
    gid_t gid = 0;
    int stdinFd = -1;
    int logFd = -1;
    std::vector<gid_t> supplementaryGroups;
    std::set<int> earlyCloseFds;
    uid_t uidMapInside = 0;
    uid_t uidMapOutside = 0;
    gid_t gidMapInside = 0;
    gid_t gidMapOutside = 0;
    bool allowSetgroups = false;
    Bytes root;
    Bytes storeDirectory;
    Bytes hostname = "localhost";
    Bytes domainname = "(none)";
    std::vector<std::tuple<Bytes, Bytes, bool>> mounts;
    std::vector<struct sock_filter> seccomp;
    Bytes slirpProgram;
    std::vector<struct sock_filter> slirpSeccomp;
    size_t phase = 0;

    bool has(uint32_t flag) const { return (flags & flag) != 0; }
};

/* The plan is bounded before allocation and every string is checked for NUL,
   since the execution interface uses C strings but carries arbitrary other
   path and argument bytes. */
class PlanReader {
    const Bytes input;
    size_t offset = 0;

public:
    explicit PlanReader(Bytes bytes) : input(std::move(bytes)) { }

    uint32_t u32()
    {
        require(4);
        const auto * p = reinterpret_cast<const unsigned char *>(input.data() + offset);
        offset += 4;
        return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
            (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
    }

    uint64_t u64()
    {
        uint64_t low = u32();
        return low | (uint64_t(u32()) << 32);
    }

    Bytes string()
    {
        uint32_t size = u32();
        require(size);
        Bytes result(input, offset, size);
        offset += size;
        if (result.find('\0') != Bytes::npos)
            throw Error("plan byte string contains NUL");
        return result;
    }

    uint32_t count(uint32_t value)
    {
        if (value > (input.size() - offset) / 4)
            throw Error("plan item count exceeds remaining input");
        return value;
    }

    int fd()
    {
        uint32_t value = u32();
        if (value == noFd) return -1;
        if (value > uint32_t(INT_MAX))
            throw Error("plan descriptor is out of range");
        return int(value);
    }

    void finish()
    {
        if (offset != input.size()) throw Error("trailing bytes in plan");
    }

private:
    void require(size_t size)
    {
        if (size > input.size() - offset) throw Error("truncated plan");
    }
};

void readFull(int fd, unsigned char * buffer, size_t count)
{
    while (count) {
        ssize_t result = read(fd, buffer, count);
        if (result == -1) {
            if (errno == EINTR) continue;
            sysError("reading from file descriptor");
        }
        if (result == 0) throw Error("unexpected end-of-file");
        count -= size_t(result);
        buffer += result;
    }
}

void writeFull(int fd, const unsigned char * buffer, size_t count)
{
    while (count) {
        ssize_t result = write(fd, buffer, count);
        if (result == -1) {
            if (errno == EINTR) continue;
            sysError("writing to file descriptor");
        }
        count -= size_t(result);
        buffer += result;
    }
}

void writeFull(int fd, const Bytes & value)
{
    writeFull(fd, reinterpret_cast<const unsigned char *>(value.data()), value.size());
}

void waitForMessage(int fd, const Bytes & message)
{
    Bytes actual(message.size(), '\0');
    readFull(fd, reinterpret_cast<unsigned char *>(actual.data()), actual.size());
    if (actual != message) throw Error("unexpected synchronization message");
}

class Fd {
    int value;
public:
    explicit Fd(int fd = -1) : value(fd) { }
    Fd(const Fd &) = delete;
    Fd & operator=(const Fd &) = delete;
    ~Fd() { if (value != -1) close(value); }
    int get() const { return value; }
    void reset(int fd = -1)
    {
        if (value != -1) close(value);
        value = fd;
    }
    int release()
    {
        int result = value;
        value = -1;
        return result;
    }
};

struct Pipe {
    Fd readSide;
    Fd writeSide;
};

Pipe makePipe()
{
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) == -1) sysError("creating pipe");
    return Pipe { Fd(fds[0]), Fd(fds[1]) };
}

void writeFile(const Bytes & path, const Bytes & contents)
{
    Fd fd(open(path.c_str(), O_WRONLY | O_CLOEXEC));
    if (fd.get() == -1) sysError("opening " + path);
    writeFull(fd.get(), contents);
    if (close(fd.release()) == -1) sysError("closing " + path);
}

Bytes readPlan(const char * path)
{
    Fd fd(open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (fd.get() == -1) sysError(std::string("opening plan `") + path + "'");
    struct stat st;
    if (fstat(fd.get(), &st) == -1) sysError("examining plan");
    if (!S_ISREG(st.st_mode)) throw Error("plan is not a regular file");
    if (st.st_size < 0 || uint64_t(st.st_size) > maxPlanSize)
        throw Error("plan exceeds size limit");
    Bytes input(size_t(st.st_size), '\0');
    readFull(fd.get(), reinterpret_cast<unsigned char *>(input.data()), input.size());
    unsigned char extra;
    ssize_t result;
    do {
        result = read(fd.get(), &extra, 1);
    } while (result == -1 && errno == EINTR);
    if (result == -1) sysError("checking end of plan");
    if (result != 0) throw Error("plan grew while being read");
    return input;
}

/* Parsing starts after the fixed magic.  Keeping the magic out of PlanReader
   makes all subsequent fields use the same bounded u32/string primitives. */
Plan parseFields(const Bytes & input)
{
    static const Bytes magic1("GSP0001\0", 8);
    static const Bytes magic2("GSP0002\0", 8);
    const bool extended = input.size() >= magic2.size() &&
        input.compare(0, magic2.size(), magic2) == 0;
    const Bytes & magic = extended ? magic2 : magic1;
    if (input.size() < magic.size() || input.compare(0, magic.size(), magic) != 0)
        throw Error("invalid plan magic or version");
    PlanReader reader(input.substr(magic.size()));
    Plan plan;
    plan.extended = extended;
    plan.flags = extended ? reader.u64() : reader.u32();
    if ((plan.flags & ~(extended ? uint64_t(knownFlags) | knownExtendedFlags : uint64_t(knownFlags))) != 0)
        throw Error("unknown plan flags");
    if (plan.extended && !plan.has(hostIdentitiesFlag) && !plan.has(sandboxFlag))
        throw Error("inconsistent sandbox plan version");
    if (plan.extended && ((plan.flags & chrootFlag) == 0 ||
                          (plan.flags & (namespaceFlags & ~sandboxFlag)) !=
                          (namespaceFlags & ~sandboxFlag)))
        throw Error("sandbox requires all private non-user namespaces and chroot");
    if (plan.has(hostIdentitiesFlag)) {
        if (geteuid() != 0 || !plan.has(setIdsFlag) || plan.has(newUserNsFlag) ||
            plan.has(lockMountsFlag))
            throw Error("host identities require root, explicit IDs, no user namespace and unlocked mounts");
    }
    if (plan.has(stdinFileFlag) && plan.has(stdinFdFlag))
        throw Error("two stdin sources requested");

    plan.program = reader.string();
    if (plan.program.empty()) throw Error("empty program in plan");
    uint32_t argc = reader.count(reader.u32());
    for (uint32_t i = 0; i < argc; ++i) plan.args.push_back(reader.string());
    if (plan.args.empty()) throw Error("empty argv in plan");

    uint32_t envc = reader.count(reader.u32());
    std::set<Bytes> names;
    for (uint32_t i = 0; i < envc; ++i) {
        Bytes name = reader.string();
        Bytes value = reader.string();
        if (name.empty() || name.find('=') != Bytes::npos)
            throw Error("invalid environment variable name");
        if (!names.insert(name).second) throw Error("duplicate environment variable");
        plan.env.emplace_back(std::move(name), std::move(value));
    }

    plan.cwd = reader.string();
    plan.stdinFile = reader.string();
    plan.uid = uid_t(reader.u32());
    plan.gid = gid_t(reader.u32());
    plan.stdinFd = reader.fd();
    plan.logFd = reader.fd();
    if (plan.has(stdinFdFlag) && plan.stdinFd == -1)
        throw Error("fd-backed stdin has no descriptor");

    uint32_t groups = reader.count(reader.u32());
    for (uint32_t i = 0; i < groups; ++i)
        plan.supplementaryGroups.push_back(gid_t(reader.u32()));
    uint32_t earlyFds = reader.count(reader.u32());
    for (uint32_t i = 0; i < earlyFds; ++i) {
        int fd = reader.fd();
        if (fd < 0) throw Error("invalid early-close descriptor");
        if (fd <= STDERR_FILENO) throw Error("cannot early-close standard descriptor");
        plan.earlyCloseFds.insert(fd);
    }
    if ((plan.has(stdinFdFlag) && plan.earlyCloseFds.count(plan.stdinFd)) ||
        (plan.has(redirectLogFlag) && plan.earlyCloseFds.count(plan.logFd)))
        throw Error("redirected descriptor is also early-closed");
    if (plan.has(redirectLogFlag) && plan.logFd == -1)
        throw Error("log redirection has no descriptor");
    if (plan.has(stdinFdFlag) && plan.stdinFd <= STDERR_FILENO)
        throw Error("fd-backed stdin must use a nonstandard descriptor");
    if (plan.has(redirectLogFlag) && plan.logFd <= STDERR_FILENO)
        throw Error("log redirection must use a nonstandard descriptor");

    plan.uidMapInside = uid_t(reader.u32());
    plan.uidMapOutside = uid_t(reader.u32());
    plan.gidMapInside = gid_t(reader.u32());
    plan.gidMapOutside = gid_t(reader.u32());
    if (plan.has(hostIdentitiesFlag)) {
        if (plan.uid == 0 || plan.gid == 0)
            throw Error("host identities require a non-root build user");
        if (plan.uidMapInside != plan.uidMapOutside ||
            plan.gidMapInside != plan.gidMapOutside)
            throw Error("host identities cannot use an identity mapping");
    }
    if (plan.extended) {
        plan.root = reader.string();
        plan.storeDirectory = reader.string();
        plan.hostname = reader.string();
        plan.domainname = reader.string();
        if (plan.root.empty() || plan.root.front() != '/')
            throw Error("sandbox root is not absolute");
        const uint32_t mounts = reader.count(reader.u32());
        for (uint32_t i = 0; i < mounts; ++i) {
            Bytes source = reader.string();
            Bytes target = reader.string();
            if (source.empty() || source.front() != '/' ||
                target.empty() || target.front() != '/')
                throw Error("mount paths must be absolute");
            plan.mounts.emplace_back(std::move(source), std::move(target),
                                     reader.u32() != 0);
        }
        const uint32_t filters = reader.count(reader.u32());
        for (uint32_t i = 0; i < filters; ++i) {
            const uint32_t code = reader.u32();
            const uint32_t jt = reader.u32();
            const uint32_t jf = reader.u32();
            const uint32_t k = reader.u32();
            if (code > UINT16_MAX || jt > UINT8_MAX || jf > UINT8_MAX)
                throw Error("seccomp instruction is out of range");
            plan.seccomp.push_back(sock_filter {
                uint16_t(code), uint8_t(jt), uint8_t(jf), k });
        }
    }
    plan.slirpProgram = reader.string();
    const uint32_t slirpFilters = reader.count(reader.u32());
    for (uint32_t i = 0; i < slirpFilters; ++i) {
        const uint32_t code = reader.u32();
        const uint32_t jt = reader.u32();
        const uint32_t jf = reader.u32();
        const uint32_t k = reader.u32();
        if (code > UINT16_MAX || jt > UINT8_MAX || jf > UINT8_MAX)
            throw Error("slirp seccomp instruction is out of range");
        plan.slirpSeccomp.push_back(sock_filter {
            uint16_t(code), uint8_t(jt), uint8_t(jf), k });
    }
    reader.finish();
    return plan;
}

Plan readAndParsePlan(const char * path)
{
    return parseFields(readPlan(path));
}

void reap(pid_t child)
{
    int status;
    pid_t result;
    do {
        result = waitpid(child, &status, 0);
    } while (result == -1 && errno == EINTR);
    if (result == -1) sysError("reaping user namespace map writer");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != EXIT_SUCCESS)
        throw Error("user namespace map writer failed");
}

void mkdirParents(const Bytes & path)
{
    for (size_t i = 1; i <= path.size(); ++i) {
        if (path[i] != '/' && path[i] != '\0') continue;
        const Bytes parent = path.substr(0, i);
        if (mkdir(parent.c_str(), 0755) == -1 && errno != EEXIST)
            sysError("creating directory " + parent);
    }
}

std::vector<char *> stringPointers(std::vector<Bytes> & strings);
void mountIntoSandbox(const Plan & plan, const Bytes & source,
                      const Bytes & target, bool readOnly);
void unshareAndInitUserns(Plan & plan);

/* Fixed-output networking follows setupTap and spawnSlirp4netns in
   nix/libstore/build.cc.  The descriptor never crosses exec: only the
   slirp child receives it, in the original network namespace. */
pid_t slirpProcess = -1;

void sendFd(int socketFd, int fd)
{
    unsigned char byte = 0;
    struct iovec iov { &byte, 1 };
    char control[CMSG_SPACE(sizeof(fd))] = {};
    struct msghdr message = {};
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    auto header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(fd));
    memcpy(CMSG_DATA(header), &fd, sizeof(fd));
    if (sendmsg(socketFd, &message, 0) != 1) sysError("sending tap descriptor");
}

void writeNetworkFile(const Bytes & path, const Bytes & contents)
{
    writeFile(path, contents);
}

void setupTap(int socketFd, bool ipv6)
{
    Fd tap(open("/dev/net/tun", O_RDWR | O_CLOEXEC));
    if (tap.get() == -1) sysError("opening /dev/net/tun");
    struct ifreq request = {};
    request.ifr_flags = IFF_TAP | IFF_NO_PI;
    std::strncpy(request.ifr_name, "tap0", IFNAMSIZ - 1);
    if (ioctl(tap.get(), TUNSETIFF, &request) < 0) sysError("TUNSETIFF");
    writeNetworkFile("/proc/sys/net/ipv6/conf/tap0/accept_dad", "0");
    writeNetworkFile("/proc/sys/net/ipv6/conf/tap0/accept_ra", "0");
    Fd socket4(socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0));
    Fd socket6(socket(AF_INET6, SOCK_DGRAM | SOCK_CLOEXEC, 0));
    if (socket4.get() < 0 || socket6.get() < 0) sysError("creating network control socket");
    if (ioctl(socket4.get(), SIOCGIFINDEX, &request) < 0) sysError("getting tap0 index");
    const int index = request.ifr_ifindex;
    request.ifr_flags = IFF_UP | IFF_RUNNING;
    if (ioctl(socket4.get(), SIOCSIFFLAGS, &request) < 0) sysError("bringing up tap0");
    request.ifr_mtu = 1500;
    if (ioctl(socket4.get(), SIOCSIFMTU, &request) < 0) sysError("setting tap0 MTU");
    auto address = reinterpret_cast<struct sockaddr_in *>(&request.ifr_addr);
    address->sin_family = AF_INET;
    if (inet_pton(AF_INET, "10.0.2.100", &address->sin_addr) != 1) throw Error("invalid tap0 address");
    if (ioctl(socket4.get(), SIOCSIFADDR, &request) < 0) sysError("setting tap0 address");
    struct in6_ifreq address6 = {};
    address6.ifr6_prefixlen = 64;
    address6.ifr6_ifindex = index;
    if (ipv6) {
        inet_pton(AF_INET6, "fd00::80", &address6.ifr6_addr);
        if (ioctl(socket6.get(), SIOCSIFADDR, &address6) < 0) sysError("setting tap0 IPv6 address");
    }
    inet_pton(AF_INET6, "fe80::80", &address6.ifr6_addr);
    if (ioctl(socket6.get(), SIOCSIFADDR, &address6) < 0) sysError("setting tap0 link-local address");
    inet_pton(AF_INET, "255.255.255.0", &address->sin_addr);
    if (ioctl(socket4.get(), SIOCSIFNETMASK, &request) < 0) sysError("setting tap0 netmask");
    struct rtentry route = {};
    address = reinterpret_cast<struct sockaddr_in *>(&route.rt_gateway);
    address->sin_family = AF_INET;
    inet_pton(AF_INET, "10.0.2.2", &address->sin_addr);
    address = reinterpret_cast<struct sockaddr_in *>(&route.rt_dst);
    address->sin_family = AF_INET;
    address = reinterpret_cast<struct sockaddr_in *>(&route.rt_genmask);
    address->sin_family = AF_INET;
    route.rt_flags = RTF_UP | RTF_GATEWAY;
    route.rt_dev = const_cast<char *>("tap0");
    if (ioctl(socket4.get(), SIOCADDRT, &route) < 0) sysError("setting tap0 default route");
    struct in6_rtmsg route6 = {};
    inet_pton(AF_INET6, "fd00::2", &route6.rtmsg_gateway);
    if (ipv6) route6.rtmsg_flags = RTF_UP | RTF_GATEWAY;
    else {
        inet_pton(AF_INET6, "fd00::2", &route6.rtmsg_dst);
        route6.rtmsg_dst_len = 128;
        route6.rtmsg_flags = RTF_UP;
    }
    route6.rtmsg_ifindex = index;
    route6.rtmsg_metric = 1;
    if (ioctl(socket6.get(), SIOCADDRT, &route6) < 0) sysError("setting tap0 IPv6 route");
    sendFd(socketFd, tap.get());
    char ready;
    ssize_t result;
    do { result = read(socketFd, &ready, 1); } while (result < 0 && errno == EINTR);
    if (result != 1 || ready != '1') throw Error("slirp4netns did not become ready");
    struct stat routeLocalnet;
    if (stat("/proc/sys/net/ipv4/conf/all/route_localnet", &routeLocalnet) == -1) return;
    writeNetworkFile("/proc/sys/net/ipv4/conf/all/route_localnet", "1");
}

void stopSlirp()
{
    if (slirpProcess <= 0) return;
    kill(slirpProcess, SIGKILL);
    kill(-slirpProcess, SIGKILL);
    int status;
    while (waitpid(slirpProcess, &status, 0) < 0 && errno == EINTR) { }
    slirpProcess = -1;
}

void slirpChild(Plan & plan, int tap, int readyFd)
{
    /* The slirp child has its own process group and PID namespace.  Its
       mounts are private; a read-only tmpfs root prevents self-overwrite. */
    const Bytes oldRoot = plan.root;
    plan.root += "/slirp";
    /* The slirp child starts in the daemon's namespaces.  Create its own
       user namespace first, with the host identity mapped, before creating
       the mount/PID/IPC/UTS namespaces.  This is the C++ cloneFlags plus
       lockMounts ordering. */
    Plan initialIdentity = plan;
    initialIdentity.uidMapInside = plan.uidMapOutside;
    initialIdentity.uidMapOutside = plan.uidMapOutside;
    initialIdentity.gidMapInside = plan.gidMapOutside;
    initialIdentity.gidMapOutside = plan.gidMapOutside;
    unshareAndInitUserns(initialIdentity);
    if (unshare(CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWIPC | CLONE_NEWUTS) == -1)
        sysError("creating slirp namespaces");
    const pid_t child = fork();
    if (child == -1) sysError("entering slirp PID namespace");
    if (child > 0) {
        int status;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) { }
        _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
    }
    /* This second fork enters slirp's PID namespace.  Its immediate parent
       exits when the outer helper dies, so propagate death across that
       boundary as well.  getppid() is zero for a healthy PID 1 here, so it
       cannot be used as the race sentinel. */
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) == -1)
        sysError("setting slirp parent-death signal");
    if (mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) == -1)
        sysError("making slirp mounts private");
    if (mount("tmpfs", oldRoot.c_str(), "tmpfs", 0, "mode=0755") == -1 ||
        mkdir(plan.root.c_str(), 0755) == -1 ||
        mount(plan.root.c_str(), plan.root.c_str(), nullptr, MS_BIND, nullptr) == -1)
        sysError("preparing slirp filesystem root");
    DIR *directory = opendir("/");
    if (!directory) sysError("reading host root for slirp");
    while (auto entry = readdir(directory)) {
        const Bytes name = entry->d_name;
        if (name == "." || name == ".." || name == "etc" || name == "run") continue;
        mountIntoSandbox(plan, "/" + name, "/" + name, true);
    }
    closedir(directory);
    const Bytes executableDirectory = plan.slirpProgram.substr(0, plan.slirpProgram.rfind('/'));
    mountIntoSandbox(plan, executableDirectory, executableDirectory, true);
    for (const Bytes & file : { Bytes("/etc/hosts"), Bytes("/etc/resolv.conf") }) {
        char resolved[PATH_MAX];
        if (realpath(file.c_str(), resolved))
            mountIntoSandbox(plan, resolved, file, true);
    }
    if (mkdir((plan.root + "/run").c_str(), 0700) == -1 && errno != EEXIST)
        sysError("creating slirp /run");
    if (mkdir((plan.root + "/proc").c_str(), 0755) == -1 && errno != EEXIST)
        sysError("creating slirp /proc");
    if (mount("proc", (plan.root + "/proc").c_str(), "proc", 0, nullptr) == -1 ||
        chdir(plan.root.c_str()) == -1 ||
        (mkdir("real-root", 0700) == -1 && errno != EEXIST) ||
        syscall(SYS_pivot_root, ".", "real-root") == -1 || chroot(".") == -1 ||
        umount2("real-root", MNT_DETACH) == -1 ||
        (rmdir("real-root") == -1 && errno != ENOENT))
        sysError("preparing slirp root");
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) == -1 ||
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) sysError("dropping slirp privileges");
    /* Match remapIdsTo0Action: map the requested slirp uid/gid to root in
       a fresh user namespace.  setgroups must remain enabled for slirp's
       --enable-sandbox parent setup. */
    Plan lockIdentity = plan;
    lockIdentity.uidMapInside = plan.uidMapOutside;
    lockIdentity.uidMapOutside = plan.uidMapOutside;
    lockIdentity.gidMapInside = plan.gidMapOutside;
    lockIdentity.gidMapOutside = plan.gidMapOutside;
    unshareAndInitUserns(lockIdentity);
    Plan identity = plan;
    identity.uidMapInside = 0;
    identity.uidMapOutside = plan.uidMapOutside;
    identity.gidMapInside = 0;
    identity.gidMapOutside = plan.gidMapOutside;
    identity.allowSetgroups = geteuid() == 0;
    unshareAndInitUserns(identity);
    if (setgid(0) == -1)
        sysError("setting slirp gid to root");
    if (setuid(0) == -1)
        sysError("setting slirp uid to root");
    if (plan.slirpSeccomp.empty() || plan.slirpSeccomp.size() > USHRT_MAX)
        throw Error("invalid slirp seccomp filter");
    struct sock_fprog filter { static_cast<unsigned short>(plan.slirpSeccomp.size()), plan.slirpSeccomp.data() };
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter) == -1) sysError("installing slirp seccomp filter");
    std::vector<Bytes> arguments { "slirp4netns", "--netns-type=tapfd", "--enable-sandbox", "--enable-ipv6",
        "--ready-fd=" + std::to_string(readyFd) };
    if (plan.has(isolateHostLoopbackFlag)) arguments.push_back("--disable-host-loopback");
    arguments.push_back(std::to_string(tap));
    auto argv = stringPointers(arguments);
    execv(plan.slirpProgram.c_str(), argv.data());
    sysError("executing slirp4netns");
}

int slirpSocket = -1;
int slirpChildSocket = -1;
uid_t slirpHostUid = 0;
gid_t slirpHostGid = 0;

void prepareSlirp(Plan & plan)
{
    if (!plan.has(slirpNetworkFlag)) return;
    /* slirp is reparented to the persistent outer helper when the builder
       enters its PID namespace.  Install this before fork: a SIGKILL to
       that helper cannot run forwardTermination(), and the slirp child's
       own PDEATHSIG relationship is with an intermediate fork parent. */
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) == -1 || getppid() == 1)
        sysError("setting helper parent-death signal");
    if (plan.slirpProgram.empty() || plan.slirpProgram.front() != '/')
        throw Error("slirp program is not absolute");
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == -1)
        sysError("creating slirp setup socket");
    slirpSocket = sockets[0];
    slirpChildSocket = sockets[1];
    slirpHostUid = plan.uidMapOutside;
    slirpHostGid = plan.gidMapOutside;
    /* As in spawnSlirp4netns, this child is created before the builder's
       user and network namespaces.  It waits for the TAP descriptor, then
       enters only its own mount/PID/IPC/UTS namespaces, not a new network
       namespace. */
    slirpProcess = fork();
    if (slirpProcess == -1) sysError("creating slirp process");
    if (slirpProcess == 0) {
        close(slirpSocket);
        slirpSocket = -1;
        if (setpgid(0, 0) == -1) _exit(1);
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) == -1) _exit(1);
        if (getppid() == 1) _exit(1);
        int tap;
        char byte;
        char control[CMSG_SPACE(sizeof(tap))] = {};
        struct iovec iov { &byte, 1 };
        struct msghdr message = {};
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        if (recvmsg(slirpChildSocket, &message, 0) != 1) _exit(1);
        auto header = CMSG_FIRSTHDR(&message);
        if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) _exit(1);
        memcpy(&tap, CMSG_DATA(header), sizeof(tap));
        /* slirp's --ready-fd is intentionally inherited across exec.  The
           setup socket itself was created with SOCK_CLOEXEC for the builder;
           only this slirp child's notification endpoint is made persistent. */
        if (fcntl(slirpChildSocket, F_SETFD, 0) == -1) _exit(1);
        try { slirpChild(plan, tap, slirpChildSocket); }
        catch (const std::exception & error) {
            writeFull(STDERR_FILENO, Bytes("slirp: ") + error.what() + "\n");
        }
        _exit(1);
    }
    close(slirpChildSocket);
    slirpChildSocket = -1;
}

void setupSlirp(Plan & plan)
{
    if (slirpSocket < 0) return;
    /* The builder's namespace now owns tap0.  setupTap sends its descriptor
       to the already-created host-namespace slirp process and waits for its
       readiness byte. */
    setupTap(slirpSocket, plan.has(ipv6NetworkFlag));
    close(slirpSocket);
    slirpSocket = -1;
}

void mountIntoSandbox(const Plan & plan, const Bytes & source,
                      const Bytes & target, bool readOnly)
{
    const Bytes destination = plan.root + target;
    struct stat status;
    if (lstat(source.c_str(), &status) == -1)
        sysError("getting attributes of mount source " + source);
    if (S_ISDIR(status.st_mode)) {
        mkdirParents(destination);
    } else if (S_ISLNK(status.st_mode)) {
        /* A bind mount would follow the link.  Preserve a symlink instead. */
        char targetBuffer[PATH_MAX + 1];
        const ssize_t size = readlink(source.c_str(), targetBuffer, PATH_MAX);
        if (size < 0) sysError("reading symbolic link " + source);
        mkdirParents(destination.substr(0, destination.rfind('/')));
        if (symlink(Bytes(targetBuffer, size).c_str(), destination.c_str()) == -1)
            sysError("copying symbolic link " + source);
        return;
    } else {
        mkdirParents(destination.substr(0, destination.rfind('/')));
        Fd fd(open(destination.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600));
        if (fd.get() == -1 && errno != EEXIST)
            sysError("creating mount destination " + destination);
    }
    if (mount(source.c_str(), destination.c_str(), nullptr, MS_BIND | MS_REC, nullptr) == -1)
        sysError("bind mounting " + source + " to " + destination);
    if (readOnly) {
        struct statvfs filesystem;
        if (statvfs(destination.c_str(), &filesystem) == -1)
            sysError("examining bind mount " + destination);
        unsigned long flags = MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID;
#ifdef ST_NODEV
        if (filesystem.f_flag & ST_NODEV) flags |= MS_NODEV;
#endif
#ifdef ST_NOEXEC
        if (filesystem.f_flag & ST_NOEXEC) flags |= MS_NOEXEC;
#endif
        if (mount(source.c_str(), destination.c_str(), nullptr, flags, nullptr) == -1)
            sysError("remounting read-only " + destination);
    }
}

void setupNamespaces(Plan & plan)
{
    if (!plan.extended) return;
    if (!plan.has(hostIdentitiesFlag)) {
        if (unshare(CLONE_NEWUSER) == -1) sysError("unshare(CLONE_NEWUSER)");
        const Bytes uidMap = std::to_string(plan.uidMapInside) + " " +
            std::to_string(plan.uidMapOutside) + " 1\n";
        const Bytes gidMap = std::to_string(plan.gidMapInside) + " " +
            std::to_string(plan.gidMapOutside) + " 1\n";
        writeFile("/proc/self/uid_map", uidMap);
        writeFile("/proc/self/setgroups", "deny");
        writeFile("/proc/self/gid_map", gidMap);
    }
    const int flags = CLONE_NEWNS | CLONE_NEWNET | CLONE_NEWPID |
        CLONE_NEWIPC | CLONE_NEWUTS;
    if (unshare(flags) == -1) sysError("creating sandbox namespaces");
    plan.uid = plan.uidMapInside;
    plan.gid = plan.gidMapInside;
}

void enterSandbox(Plan & plan)
{
    if (!plan.extended) return;
    if (mount(nullptr, "/", nullptr, MS_REC | MS_PRIVATE, nullptr) == -1)
        sysError("making mounts private");
    if (sethostname(plan.hostname.c_str(), plan.hostname.size()) == -1 ||
        setdomainname(plan.domainname.c_str(), plan.domainname.size()) == -1)
        sysError("setting sandbox hostname");
    if (mount(plan.root.c_str(), plan.root.c_str(), nullptr, MS_BIND, nullptr) == -1)
        sysError("making sandbox root a mount point");
    mkdirParents(plan.root + plan.storeDirectory);
    if (chmod((plan.root + plan.storeDirectory).c_str(), 01777) == -1)
        sysError("making sandbox store writable");
    for (const auto & [source, target, readOnly] : plan.mounts)
        mountIntoSandbox(plan, source, target, readOnly);
    if (plan.has(procFlag)) {
        mkdirParents(plan.root + "/proc");
        if (mount("proc", (plan.root + "/proc").c_str(), "proc", 0, nullptr) == -1)
            sysError("mounting /proc");
    }
    if (plan.has(devptsFlag)) {
        mkdirParents(plan.root + "/dev/pts");
        if (mount("devpts", (plan.root + "/dev/pts").c_str(), "devpts", 0,
                  "newinstance,mode=0620,ptmxmode=0666") == -1)
            sysError("mounting /dev/pts");
        if (symlink("/dev/pts/ptmx", (plan.root + "/dev/ptmx").c_str()) == -1)
            sysError("linking /dev/ptmx");
    }
    if (chdir(plan.root.c_str()) == -1 || mkdir("real-root", 0700) == -1 ||
        syscall(SYS_pivot_root, ".", "real-root") == -1 ||
        chroot(".") == -1 || umount2("real-root", MNT_DETACH) == -1 ||
        rmdir("real-root") == -1)
        sysError("entering sandbox root");
    if (chmod("/", 0555) == -1) sysError("making sandbox root read-only");
    Fd socketFd(socket(AF_INET, SOCK_DGRAM, 0));
    if (socketFd.get() == -1) sysError("opening loopback socket");
    struct ifreq interfaceRequest {};
    std::strncpy(interfaceRequest.ifr_name, "lo", IFNAMSIZ - 1);
    interfaceRequest.ifr_flags = IFF_UP | IFF_LOOPBACK | IFF_RUNNING;
    if (ioctl(socketFd.get(), SIOCSIFFLAGS, &interfaceRequest) == -1)
        sysError("bringing up loopback");
    plan.uid = plan.uidMapInside;
    plan.gid = plan.gidMapInside;
}

/* Retain spawn.cc's external map-writer handshake.  No daemon code runs
   after fork; the child only executes the C++ map-writing routine. */
void unshareAndInitUserns(Plan & plan)
{
    const pid_t target = getpid();
    const Bytes pid = std::to_string(target);
    Pipe toChild = makePipe();
    Pipe fromChild = makePipe();
    pid_t child = fork();
    if (child == -1) sysError("creating user namespace map writer");
    if (child == 0) {
        try {
            toChild.writeSide.reset();
            fromChild.readSide.reset();
            waitForMessage(toChild.readSide.get(), "ready\n");
            writeFile("/proc/" + pid + "/uid_map",
                std::to_string(plan.uidMapInside) + " " +
                std::to_string(plan.uidMapOutside) + " 1\n");
            writeFile("/proc/" + pid + "/setgroups", plan.allowSetgroups ? "allow\n" : "deny\n");
            writeFile("/proc/" + pid + "/gid_map",
                std::to_string(plan.gidMapInside) + " " +
                std::to_string(plan.gidMapOutside) + " 1\n");
            writeFull(fromChild.writeSide.get(), "go\n");
        } catch (const std::exception & error) {
            try {
                writeFull(STDERR_FILENO,
                    Bytes("guix-sandbox: user namespace map writer: ") + error.what() + "\n");
            } catch (...) { }
            _exit(1);
        } catch (...) {
            _exit(1);
        }
        _exit(EXIT_SUCCESS);
    }

    toChild.readSide.reset();
    fromChild.writeSide.reset();
    try {
        if (unshare(CLONE_NEWUSER) == -1) sysError("unshare(CLONE_NEWUSER)");
        writeFull(toChild.writeSide.get(), "ready\n");
        waitForMessage(fromChild.readSide.get(), "go\n");
        toChild.writeSide.reset();
        fromChild.readSide.reset();
    } catch (...) {
        toChild.writeSide.reset();
        fromChild.readSide.reset();
        try { reap(child); } catch (...) { }
        throw;
    }
    reap(child);
}

using Action = void (*)(Plan &);
struct Phase { const char * label; Action action; };

void usernsSetIdsAction(Plan & plan)
{
    if (plan.has(newUserNsFlag)) {
        plan.uid = plan.uidMapInside;
        plan.gid = plan.gidMapInside;
    }
}

void setsidAction(Plan & plan)
{
    if (plan.has(setSidFlag) && setsid() == pid_t(-1))
        sysError("creating a new session");
}

void earlyIoSetupAction(Plan & plan)
{
    for (int fd : plan.earlyCloseFds)
        if (close(fd) == -1) sysError("closing fd");

    if (plan.has(redirectLogFlag)) {
        if (dup2(plan.logFd, STDOUT_FILENO) == -1)
            sysError("cannot dup2 log fd into stdout fd");
        if (dup2(plan.logFd, STDERR_FILENO) == -1)
            sysError("cannot dup2 log fd into stderr fd");
    }

    if (plan.has(stdinFdFlag)) {
        if (dup2(plan.stdinFd, STDIN_FILENO) == -1)
            sysError("cannot dup2 fd into stdin fd");
    } else if (plan.has(stdinFileFlag)) {
        Fd fd(open(plan.stdinFile.c_str(), O_RDWR | O_CLOEXEC));
        if (fd.get() == -1) sysError("cannot open stdin file");
        if (dup2(fd.get(), STDIN_FILENO) == -1)
            sysError("cannot dup2 fd into stdin fd");
    }
}

void chdirAction(Plan & plan)
{
    if (plan.has(chdirFlag) && chdir(plan.cwd.c_str()) == -1)
        sysError("changing working directory");
}

void closeMostFdsAction(Plan & plan)
{
    if (!plan.has(closeFdsFlag)) return;
    long maximum = sysconf(_SC_OPEN_MAX);
    if (maximum < 0) maximum = 65536;
    maximum = std::min(maximum, long(INT_MAX));
    for (int fd = STDERR_FILENO + 1; fd < maximum; ++fd)
        close(fd); /* Match closeMostFDs: absent descriptors are harmless. */
}

void setIdsAction(Plan & plan)
{
    if (plan.has(clearGroupsFlag) || plan.has(setIdsFlag)) {
        /* Unprivileged UID/GID mapping writes "deny" to setgroups.  The
           inherited supplementary groups are then inaccessible and cannot
           be set again; no groups are requested by the sandbox plan. */
        Fd groupsFile(open("/proc/self/setgroups", O_RDONLY | O_CLOEXEC));
        char setting[16] = {};
        const bool denied = plan.extended && groupsFile.get() >= 0 &&
            read(groupsFile.get(), setting, sizeof(setting) - 1) > 0 &&
            Bytes(setting).compare(0, 4, "deny") == 0;
        if (!denied && setgroups(plan.supplementaryGroups.size(),
                                 plan.supplementaryGroups.data()) == -1)
            sysError("cannot set supplementary groups");
    }
    if (plan.has(setIdsFlag)) {
        if (setgid(plan.gid) == -1 || getgid() != plan.gid || getegid() != plan.gid)
            sysError("setgid failed");
        if (setuid(plan.uid) == -1 || getuid() != plan.uid || geteuid() != plan.uid)
            sysError("setuid failed");
    }
}

void setNoNewPrivsAction(Plan & plan)
{
    /* Upstream passes zero here; PR_SET_NO_NEW_PRIVS requires arg2 == 1. */
    if (plan.has(noNewPrivsFlag) && prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1)
        sysError("setting PR_SET_NO_NEW_PRIVS");
}

void addSeccompFilterAction(Plan & plan)
{
    if (plan.seccomp.empty()) return;
    if (plan.seccomp.size() > USHRT_MAX) throw Error("seccomp filter is too large");
    struct sock_fprog program {
        static_cast<unsigned short>(plan.seccomp.size()), plan.seccomp.data() };
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) == -1)
        sysError("installing seccomp filter");
}

void restoreSigpipeAction(Plan &)
{
    struct sigaction action { };
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, nullptr) == -1) sysError("resetting SIGPIPE");
}

void setupSuccessAction(Plan & plan)
{
    if (plan.has(setupSuccessFlag)) writeFull(STDERR_FILENO, "\n");
}

std::vector<char *> stringPointers(std::vector<Bytes> & strings)
{
    std::vector<char *> result;
    result.reserve(strings.size() + 1);
    for (Bytes & value : strings) result.push_back(value.data());
    result.push_back(nullptr);
    return result;
}

void execAction(Plan & plan)
{
    std::vector<Bytes> envStrings;
    std::vector<char *> envPointers;
    char ** environment = nullptr;
    /* Reserve before taking pointers: a later vector reallocation would
       invalidate the C strings passed to execvpe. */
    envStrings.reserve(plan.env.size());
    envPointers.reserve(plan.env.size() + 1);
    if (plan.has(inheritEnvFlag)) {
        for (const auto & entry : plan.env)
            if (setenv(entry.first.c_str(), entry.second.c_str(), 1) == -1)
                sysError("setenv");
        environment = environ;
    } else {
        for (const auto & entry : plan.env) {
            envStrings.push_back(entry.first + "=" + entry.second);
            envPointers.push_back(envStrings.back().data());
        }
        envPointers.push_back(nullptr);
        environment = envPointers.data();
    }
    std::vector<char *> arguments = stringPointers(plan.args);
    execvpe(plan.program.c_str(), arguments.data(), environment);
    sysError("executing " + plan.program);
}

pid_t pidNamespaceChild = -1;

void forwardTermination(int)
{
    stopSlirp();
    if (pidNamespaceChild > 0) {
        kill(pidNamespaceChild, SIGKILL);
        kill(-pidNamespaceChild, SIGKILL);
    }
}

void enterPidNamespace(Plan & plan)
{
    if (!plan.extended) return;
    /* Install the handler before forking: the child is the builder's PID 1
       and must also terminate when the daemon cancels the helper. */
    struct sigaction terminate { };
    terminate.sa_handler = forwardTermination;
    sigemptyset(&terminate.sa_mask);
    if (sigaction(SIGTERM, &terminate, nullptr) == -1 ||
        sigaction(SIGINT, &terminate, nullptr) == -1 ||
        sigaction(SIGHUP, &terminate, nullptr) == -1)
        sysError("installing sandbox termination handlers");
    const pid_t child = fork();
    if (child == -1) sysError("entering PID namespace");
    if (child == 0) {
        /* The helper is the daemon's direct child; if it is killed, do not
           leave the builder running as PID 1 in the new PID namespace. */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) == -1 || getppid() == 1)
            sysError("setting builder parent-death signal");
        return;
    }
    /* Forward cancellation to the builder's process group as well. */
    pidNamespaceChild = child;
    int status = 0;
    pid_t result;
    do { result = waitpid(child, &status, 0); } while (result == -1 && errno == EINTR);
    if (result == -1) sysError("waiting for sandbox child");
    stopSlirp();
    if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
    if (WIFSIGNALED(status)) {
        signal(WTERMSIG(status), SIG_DFL);
        raise(WTERMSIG(status));
    }
    _exit(1);
}

const std::vector<Phase> phases = {
    { "prepareSlirp", prepareSlirp },
    { "unshareAndInitUserns", [](Plan & p) { if (p.has(newUserNsFlag)) unshareAndInitUserns(p); } },
    { "setupNamespaces", setupNamespaces },
    { "setupSlirp", setupSlirp },
    { "enterPidNamespace", enterPidNamespace },
    { "enterSandbox", enterSandbox },
    { "usernsSetIDs", usernsSetIdsAction },
    { "setsid", setsidAction },
    { "earlyIOSetup", earlyIoSetupAction },
    { "chdir", chdirAction },
    { "closeMostFDs", closeMostFdsAction },
    { "setIDs", setIdsAction },
    { "setNoNewPrivs", setNoNewPrivsAction },
    { "addSeccompFilter", addSeccompFilterAction },
    { "restoreSIGPIPE", restoreSigpipeAction },
    { "setupSuccess", setupSuccessAction },
    { "exec", execAction },
};

[[noreturn]] void run(Plan plan)
{
    try {
        for (plan.phase = 0; plan.phase < phases.size(); ++plan.phase)
            phases[plan.phase].action(plan);
    } catch (const std::exception & error) {
        stopSlirp();
        try {
            Bytes message = "guix-sandbox: child setup";
            if (plan.phase < phases.size())
                message += Bytes(": in phase ") + phases[plan.phase].label;
            message += ": ";
            message += error.what();
            message += "\n";
            writeFull(STDERR_FILENO, message);
        } catch (...) { }
        _exit(1);
    }
    _exit(1);
}

} // namespace

int main(int argc, char ** argv)
{
    if (argc != 2) {
        static const char usage[] = "usage: guix-sandbox PLAN\n";
        write(STDERR_FILENO, usage, sizeof(usage) - 1);
        return 1;
    }
    try {
        run(readAndParsePlan(argv[1]));
    } catch (const std::exception & error) {
        try {
            writeFull(STDERR_FILENO, Bytes("guix-sandbox: ") + error.what() + "\n");
        } catch (...) { }
        return 1;
    }
}

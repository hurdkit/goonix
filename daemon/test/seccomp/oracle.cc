/* Differential oracle for the committed nix/libutil/seccomp.cc.
   The policy is copied from DerivationGoal's slirpSeccompFilter. */
#include "util.hh"
#include "seccomp.hh"
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <linux/seccomp.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <vector>

namespace nix {
static std::vector<struct sock_filter> slirpSeccompFilter()
{
    std::vector<struct sock_filter> out;
    struct sock_filter allow = BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    struct sock_filter deny = BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS);
    struct sock_filter silentDeny = BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | 0);
    std::vector<struct sock_filter> allowInet;
    seccompMatchu64(allowInet, AF_INET, {allow}, offsetof(struct seccomp_data, args[0]));
    seccompMatchu64(allowInet, AF_INET6, {allow}, offsetof(struct seccomp_data, args[0]));
    std::vector<struct sock_filter> denyNonInet(allowInet);
    denyNonInet.push_back(deny);
    std::vector<struct sock_filter> silentDenyNonInet(allowInet);
    silentDenyNonInet.push_back(silentDeny);
    out.push_back(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)));
    out.push_back(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_NATIVE, 1, 0));
    out.push_back(deny);
    std::vector<Uint32RangeAction> specialCaseActions;
#ifdef __NR_socket
    specialCaseActions.push_back({__NR_socket, __NR_socket, denyNonInet});
#endif
#ifdef __NR_socketpair
    specialCaseActions.push_back({__NR_socketpair, __NR_socketpair, silentDenyNonInet});
#endif
#ifdef __NR_socketcall
    specialCaseActions.push_back({__NR_socketcall, __NR_socketcall, {deny}});
#endif
    specialCaseActions.push_back({__NR_ptrace, __NR_ptrace, {deny}});
    auto specialCases = rangeActionsToFilter(specialCaseActions);
    out.push_back(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)));
    out.insert(out.end(), specialCases.begin(), specialCases.end());
    out.push_back(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)));
    std::vector<Uint32RangeAction> pinnedSyscallRanges = NATIVE_SYSCALL_RANGES;
    if (!pinnedSyscallRanges.empty()) {
        for (auto &i : pinnedSyscallRanges) i.instructions.push_back(allow);
        auto pinnedWhitelist = rangeActionsToFilter(pinnedSyscallRanges);
        out.insert(out.end(), pinnedWhitelist.begin(), pinnedWhitelist.end());
        out.push_back(deny);
    } else out.push_back(allow);
    return out;
}
}

static void u32(uint32_t value)
{
    unsigned char bytes[] = {static_cast<unsigned char>(value), static_cast<unsigned char>(value >> 8), static_cast<unsigned char>(value >> 16), static_cast<unsigned char>(value >> 24)};
    fwrite(bytes, 1, 4, stdout);
}
int main()
{
    for (auto instruction : nix::slirpSeccompFilter()) {
        u32(instruction.code); u32(instruction.jt); u32(instruction.jf); u32(instruction.k);
    }
}

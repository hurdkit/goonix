// goonix: report the identity granted by the deep-scan runner for its root test.
#include "util.hh"
#include <format>
#include <iostream>
#include <grp.h>
#include <unistd.h>

int main()
{
    gid_t groups[128];
    int count = getgroups(128, groups);
    if (count < 0) {
        perror("getgroups");
        return 2;
    }
    std::string identity = std::format("uid={} gid={} groups=", getuid(), getgid());
    for (int i = 0; i < count; ++i) {
        if (i) identity += ",";
        identity += std::to_string(groups[i]);
    }
    std::cout << "self-token\t0\t" << identity << '\n';
    return 1;
}

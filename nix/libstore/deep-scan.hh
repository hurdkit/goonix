// goonix: run deep CA decoding in a separate, unprivileged process.
#pragma once
#include "types.hh"
#include <functional>

namespace nix {

/* Run the configured libexec helper over TREE.  TOKENS contains every output
   token of the derivation.  A found token or any helper failure is a build
   error; only the helper's explicit clean status permits finalisation. */
/* Return the build-tree override or the make-expanded installed helper. */
Path deepScanHelperPath();

void checkDeepOutput(const Path & tree, const StringSet & tokens,
    uid_t buildUID = (uid_t) -1, gid_t buildGID = (gid_t) -1,
    std::function<void()> cleanup = {});

}

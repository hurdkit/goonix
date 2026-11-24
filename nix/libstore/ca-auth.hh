// goonix: narrow bridge to the daemon's existing signature verifier.
#pragma once
#include "types.hh"

namespace nix {
class LocalStore;
string verifyGoonixRecordSignature(LocalStore & store, const string & signature);
}

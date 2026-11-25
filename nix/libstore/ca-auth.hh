// goonix: narrow bridge to the daemon's record-signature implementation.
#pragma once
#include "types.hh"
#include "ca-record-signature.hh"

namespace nix {
class LocalStore;
string verifyGoonixRecordSignature(LocalStore & store, const string & signature);
}

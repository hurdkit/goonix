// goonix: record-signature encoding, with the store's authentication agent.
#pragma once
#include "types.hh"
#include "hash.hh"
#include <functional>

namespace nix {
class LocalStore;
using SignGoonixRecord = std::function<string(LocalStore &, const Path &, const Hash &)>;
using VerifyGoonixRecord = std::function<string(LocalStore &, const string &)>;
string canonicalGoonixRecordSignature(const string & signature);
string signGoonixRecordPayload(LocalStore & store, const string & payload,
    SignGoonixRecord sign);
string verifyGoonixRecordSignature(LocalStore & store, const string & signature,
    VerifyGoonixRecord verify);
void checkGoonixRecordKeySecrecy(const Path & path);
}

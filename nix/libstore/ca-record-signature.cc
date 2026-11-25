// goonix: encode record signatures and verify them through the store's agent.
#include "ca-record-signature.hh"
#include "ca.hh"
#include "local-store.hh"
#include "globals.hh"

namespace nix {

string signGoonixRecordPayload(LocalStore & store, const string & payload,
    SignGoonixRecord sign)
{
    Path secretKey = settings.nixConfDir + "/signing-key.sec";
    checkGoonixRecordKeySecrecy(secretKey);
    /* The agent's advanced S-expression can hold raw high bytes.  Base64
       makes the stored and transported representation deterministic UTF-8. */
    return goonixBase64Encode(sign(store, secretKey,
        hashString(htSHA256, payload)));
}

string verifyGoonixRecordSignature(LocalStore & store, const string & signature,
    VerifyGoonixRecord verify)
{
    string decoded;
    try {
        decoded = goonixBase64Decode(signature);
    } catch (Error & error) {
        throw InvalidRecordSignature(error.msg());
    }
    /* Authentication failures remain AuthenticationError, not bad encoding. */
    return verify(store, decoded);
}

}

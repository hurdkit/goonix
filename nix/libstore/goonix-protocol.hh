// goonix: the signal by which a goonix daemon and client know each other.
#pragma once

#include "worker-protocol.hh"

namespace nix {

/* The worker protocol of goonix has operations and a setting that
   upstream's does not have.  A peer of upstream must never be sent one of
   them, and must never be taken for a peer that knows them.  The protocol
   version cannot tell the two apart: PROTOCOL_VERSION is upstream's
   number, and what a number means is upstream's to say.

   At the start of a connection the daemon and then the client each send
   one word that holds their protocol version.  Upstream reads the major
   version in bits 8 to 15 of that word and the minor version in bits 0 to
   7: GET_PROTOCOL_MAJOR and GET_PROTOCOL_MINOR here, `protocol-major' and
   `protocol-minor' in the client.  Neither side looks at the bits above,
   and the word is read as 32 bits.  A goonix peer puts its signal there: a
   tag in bits 24 to 31 and a level in bits 16 to 23.  The sixteen bits
   below stay the version, with the meaning upstream gives it.

   The level says which operations of goonix the peer knows: each has the
   level that introduced it.  A word without the tag has level zero, which
   is that of upstream's peers and of the goonix peers that came before the
   signal.  An operation of goonix is used on a connection only when both
   of its ends gave a level that has it: the client does not send it to a
   daemon below that level, and the daemon answers one from a client below
   that level as it answers an operation that does not exist.  */

/* What bits 24 to 31 of a goonix peer's version word hold.  */
const unsigned int goonixProtocolTag = 0x67;

/* The level of this daemon: it knows every operation that
   goonixOperationLevel gives a level.  */
const unsigned int goonixProtocolLevel = 1;

/* The level from which a client that is not trusted may choose
   "goonix-deep-scan" with wopSetOptions.  */
const unsigned int goonixSettingsLevel = 1;

/* The word this daemon sends as its version in the greeting: VERSION in
   the bits upstream reads, and above them the tag and the level.  */
inline unsigned int goonixVersionWord(unsigned int version)
{
    return (version & 0xffff) | (goonixProtocolLevel << 16)
        | (goonixProtocolTag << 24);
}

/* The goonix level that WORD carries, a version word as a peer sent it in
   the greeting, or 0 if WORD does not have the tag of a goonix peer.  */
inline unsigned int goonixPeerLevel(unsigned int word)
{
    return ((word >> 24) & 0xff) == goonixProtocolTag
        ? (word >> 16) & 0xff : 0;
}

/* The level from which a goonix peer has operation OP, or 0 if OP is not
   one of those that upstream's daemon does not have.  */
inline unsigned int goonixOperationLevel(unsigned int op)
{
    switch (op) {
    case wopQueryRealisedOutput:
    case wopQueryBuildRecords:
    case wopQueryBuildGraph:
    case wopQuerySessions:
        return 1;
    default:
        return 0;
    }
}

}

;;; goonix: the signal by which a goonix daemon and client know each other.
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (guix goonix-protocol)
  #:export (goonix-version-word
            version-word-with-level
            version-word-goonix-level
            goonix-operation-level
            goonix-level-knows?
            goonix-refusal
            goonix-settings))

;;; Commentary:
;;;
;;; The worker protocol of goonix has operations and a setting that
;;; upstream's does not have.  A peer of upstream must never be sent one of
;;; them, and must never be taken for a peer that knows them.  The protocol
;;; version cannot tell the two apart: it is upstream's number, and what a
;;; number means is upstream's to say.
;;;
;;; At the start of a connection the daemon and then the client each send
;;; one word that holds their protocol version.  Upstream reads the major
;;; version in bits 8 to 15 of that word and the minor version in bits 0 to
;;; 7: 'protocol-major' and 'protocol-minor' in (guix remote-procedures),
;;; GET_PROTOCOL_MAJOR and GET_PROTOCOL_MINOR in the daemon's
;;; worker-protocol.hh.  Neither side looks at the bits above, and the word
;;; is read as 32 bits.  A goonix peer puts its signal there: a tag in bits
;;; 24 to 31 and a level in bits 16 to 23.  The sixteen bits below stay the
;;; version, with the meaning upstream gives it.
;;;
;;; The level says which of the operations below the peer knows: each has
;;; the level that introduced it.  A word without the tag has level zero,
;;; which is that of upstream's peers and of the goonix peers that came
;;; before the signal.  An operation of goonix is used on a connection only
;;; when both of its ends gave a level that has it: the client does not send
;;; it to a daemon below that level, and the daemon answers one from a client
;;; below that level as it answers an operation that does not exist.
;;;
;;; A connection can be handed to another process, which exchanges no
;;; greeting of its own: an inferior, or the program that computes the
;;; derivation of a channel.  That process is told the version of the
;;; connection in one word, and a goonix client puts the daemon's level in
;;; that word in the same way, so that the level goes with the connection.
;;;
;;; Code:

(define %tag
  ;; What bits 24 to 31 of a goonix peer's version word hold.
  #x67)

(define %level
  ;; The level of this client: it knows every operation listed below.
  1)

(define %operations
  ;; The identifier of each worker operation that upstream's daemon does not
  ;; have, with the level from which a goonix daemon has it.
  '((82 . 1)                                      ;query-realised-output
    (83 . 1)                                      ;query-build-records
    (84 . 1)                                      ;query-build-graph
    (85 . 1)))                                    ;query-sessions

(define %settings-level
  ;; The level from which a goonix daemon lets any client choose
  ;; "goonix-deep-scan" with 'set-build-options'.
  1)

(define (version-word-with-level version level)
  "Return the word that says, to a process that is handed a connection, the
protocol VERSION of that connection and the goonix LEVEL its daemon gave:
VERSION as it is for level 0, which is what upstream writes, and otherwise
VERSION in the bits upstream reads with the tag and LEVEL above them.
'port->connection' reads the level back with 'version-word-goonix-level';
upstream's keeps the major and minor version and nothing else."
  (if (zero? level)
      version
      (logior (logand version #xffff)
              (ash level 16)
              (ash %tag 24))))

(define (goonix-version-word version)
  "Return the word that this client sends as its version in the greeting:
VERSION, the protocol version, in the bits upstream reads, and above them the
tag and the level of a goonix peer."
  (version-word-with-level version %level))

(define (version-word-goonix-level word)
  "Return the goonix level that WORD carries, a version word as a peer sent
it in the greeting, or 0 if WORD does not have the tag of a goonix peer."
  (if (= %tag (logand (ash word -24) #xff))
      (logand (ash word -16) #xff)
      0))

(define (goonix-operation-level operation)
  "Return the level from which a goonix daemon has OPERATION, the identifier
of a worker operation, or 0 if OPERATION is not one of those that upstream's
daemon does not have."
  (or (assv-ref %operations operation) 0))

(define (goonix-level-knows? level operation)
  "Return true if a daemon that gave LEVEL in the greeting may be sent
OPERATION, the identifier of a worker operation.  Any daemon may be sent an
operation that upstream has."
  (>= level (goonix-operation-level operation)))

(define (goonix-refusal name)
  "Return the message of the error raised instead of sending the operation
called NAME, a symbol, to a daemon that does not know it."
  (format #f "the build daemon does not know '~a', an operation of goonix"
          name))

(define (goonix-settings level deep-scan?)
  "Return, as a list of name/value pairs, the settings that a daemon of LEVEL
is sent beside upstream's: DEEP-SCAN? says whether it scans the outputs of
this connection's content-addressed builds in depth.  A daemon below the
level of those settings is sent none."
  (if (>= level %settings-level)
      `(("goonix-deep-scan" . ,(if deep-scan? "true" "false")))
      '()))

;;; goonix-protocol.scm ends here

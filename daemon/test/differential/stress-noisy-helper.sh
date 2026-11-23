#!/usr/bin/env bash
# goonix: a fake `guix substitute --query' helper for the concurrency stress gate.
# Combines the two real-use stresses that froze the daemon:
#   - LOG FLOOD: for each command it writes WELL OVER 64 KiB of progress to stderr
#     (the log pipe) BEFORE its reply, so a daemon that does not drain the log pipe
#     deadlocks (the 0c8a934d515 defect).
#   - SILENCE: it then stays SILENT for $SILENT_SECONDS before writing the reply to
#     fd 4, so a daemon waiting in an `unsafe' foreign select() holds its capability
#     and the next GC freezes every other client (the 52fe97d8ec7 defect).
# A correct daemon drains the log while reading the reply through the IO manager,
# so the other clients (builds, GC, roots, the watchdog) keep running throughout.
# Replies go to fd 4 (%reply-file-descriptor); the loop ends at stdin EOF.
silent=${SILENT_SECONDS:-6}
while read -r command _rest; do
  # ~160 KB of progress, well over the 64 KiB pipe buffer, BEFORE the reply.
  i=0
  while test "$i" -lt 2000; do
    printf 'substitute: progress line %d padding-padding-padding-padding-padding\n' "$i" >&2
    i=$((i + 1))
  done
  case "$command" in
    # "info <paths>" (the substitute client's query): stay SILENT so receiveLine
    # parks on the pipes — the unsafe-select freeze stress.
    info) sleep "$silent"; printf '\n' >&4 ;;
    # "have <paths>" (build clients' substitution check) and anything else: reply
    # at once (the flood above already exercised the log drain), so builds proceed.
    *) printf '\n' >&4 ;;
  esac
done
exit 0
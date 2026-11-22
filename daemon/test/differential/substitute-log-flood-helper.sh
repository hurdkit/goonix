#!/usr/bin/env bash
# goonix: a fake `guix substitute --query' helper for the log-drain regression.
# The daemon invokes it as `guix substitute --query' (goonix_spawn_helper) and
# keeps it alive across queries (the C++ daemon caches the agent).  For EACH
# command it reads from stdin, it writes WELL OVER 64 KiB of progress to stderr
# (the log pipe) BEFORE writing its reply to fd 4.  A daemon that reads only the
# reply pipe and never drains the log pipe deadlocks: the helper blocks in
# write() once the 64 KiB log pipe buffer fills, and the daemon blocks waiting
# for a reply that never comes.  The C++ daemon selects on both descriptors and
# drains the log, so it answers.  Replies go to fd 4 (%reply-file-descriptor),
# diagnostics to stderr.  The loop ends at stdin EOF, like the real helper.
while read -r command _rest; do
  # ~160 KB of progress, well over the 64 KiB pipe buffer, BEFORE the reply.
  i=0
  while test "$i" -lt 2000; do
    printf 'substitute: progress line %d padding-padding-padding-padding-padding\n' "$i" >&2
    i=$((i + 1))
  done
  case "$command" in
    # "have <paths>": reply with the empty list (a blank line ends readPaths).
    # "info <paths>": reply with no infos (a blank line ends readInfos).
    *) printf '\n' >&4 ;;
  esac
done
exit 0
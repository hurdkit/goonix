#!/usr/bin/env bash
# goonix: a fake `guix substitute --query' helper that stays SILENT for a fixed
# time before it replies.  The daemon invokes it as `guix substitute --query'
# (goonix_spawn_helper) and keeps it alive across queries.  For each command it
# reads from stdin it sleeps $SILENT_SECONDS writing NOTHING to either pipe, then
# writes its reply to fd 4.  While it is silent the daemon's receiveLine is parked
# waiting for the reply/log pipes.  A correct daemon waits through the GHC IO
# manager, so other clients keep running and the GC can stop every capability; a
# daemon that waits in an `unsafe' foreign select() holds its capability and the
# next GC freezes every other client until this helper finally writes.
# Replies go to fd 4 (%reply-file-descriptor); the loop ends at stdin EOF.
silent=${SILENT_SECONDS:-8}
while read -r command _rest; do
  sleep "$silent"
  case "$command" in
    # "have <paths>": empty list (a blank line ends readPaths).
    # "info <paths>": no infos (a blank line ends readInfos).
    *) printf '\n' >&4 ;;
  esac
done
exit 0
#!/usr/bin/env bash
# goonix: shared gate preconditions for CA-6 and CA-8.
#
# Sourced by the gate runners.  Two defects found by counted run 18c are fixed
# here rather than left as rules for whoever reads a result (reviewer,
# DECISIONS.md 37):
#
#  1. The runners start guile with --no-auto-compile through ./pre-inst-env, so
#     on a fresh checkout Guile silently INTERPRETS the .scm files.  That is not
#     equivalent to a built tree: upstream's `oniguruma' in (gnu packages
#     textutils) is a MACRO (define-deprecated/public-alias -> define-syntax),
#     and interpreted loading captures it as a syntax object, so jq's input
#     becomes ("_" #<syntax-transformer oniguruma>) and lowering the VM image
#     fails.  Measured on a ZERO-goonix-hook tree with byte-identical package
#     files, so it is an upstream bug that a compiled tree does not hit.  A gate
#     must therefore refuse to run on an unbuilt or stale tree.
#
#  2. A gate must exit with its own verdict, so a failed gate fails the unit
#     that ran it.  See goonix_gate_exit below.
#
# This file is ours (upstream has no such file), so it is not hook-checked.

# goonix_gate_require_compiled IMPL
#
# Refuse to run when any module the tree's Makefile compiles is missing its .go
# or has a .go older than its .scm.  The set comes from make itself (GOBJECTS),
# not from a guessed find: MODULES is assembled across Makefile.am and
# goonix.mk, and MODULES_NOT_COMPILED is excluded by the tree, so only make
# knows the real list.
goonix_gate_require_compiled() {
  local impl=$1
  local listing stale missing total=0
  listing=$(cd "$impl" && make --eval='goonix-print-gobjects:;@printf "%s\n" $(GOBJECTS)' \
              -o Makefile goonix-print-gobjects 2>/dev/null) || listing=''
  if [ -z "$listing" ]; then
    echo 'GATE PRECONDITION FAILED: cannot read GOBJECTS from make.' >&2
    echo 'The tree is not configured.  Run goonix-ca6/prepare-tree.sh first.' >&2
    return 1
  fi
  missing=$(mktemp); stale=$(mktemp)
  local go scm
  while IFS= read -r go; do
    [ -n "$go" ] || continue
    case "$go" in *.go) ;; *) continue;; esac
    scm=${go%.go}.scm
    total=$((total + 1))
    if [ ! -f "$impl/$go" ]; then
      # guix/config.go is generated from config.scm by configure; a missing
      # .scm means the object is not a module of this tree, so skip it.
      [ -f "$impl/$scm" ] && printf '%s\n' "$go" >> "$missing"
      continue
    fi
    if [ -f "$impl/$scm" ] && [ "$impl/$scm" -nt "$impl/$go" ]; then
      printf '%s\n' "$go" >> "$stale"
    fi
  done <<< "$listing"
  local nmissing nstale
  nmissing=$(wc -l < "$missing"); nstale=$(wc -l < "$stale")
  if [ "$nmissing" -gt 0 ] || [ "$nstale" -gt 0 ]; then
    {
      echo "GATE PRECONDITION FAILED: the tree is not fully compiled."
      echo "  modules make compiles: $total"
      echo "  missing .go: $nmissing   stale .go (older than its .scm): $nstale"
      echo "  first missing:"; head -5 "$missing" | sed 's/^/    /'
      echo "  first stale:";   head -5 "$stale"   | sed 's/^/    /'
      echo "Guile would INTERPRET these modules (--no-auto-compile), which is"
      echo "not the load path a built tree uses and can fail on upstream macro"
      echo "hygiene (jq/oniguruma, DECISIONS 37).  Build the tree first:"
      echo "  bash goonix-ca6/prepare-tree.sh [JOBS]"
    } >&2
    rm -f "$missing" "$stale"
    return 1
  fi
  rm -f "$missing" "$stale"
  echo "GATE PRECONDITION OK: $total compiled modules, none missing or stale"
  return 0
}

# goonix_gate_exit VERDICT
#
# Print the verdict and exit with it, so the caller's unit fails when the gate
# failed.  The runners print their diagnostic tails BEFORE calling this.
goonix_gate_exit() {
  local verdict=${1:-1}
  echo "GATE_EXIT=$verdict"
  exit "$verdict"
}

# goonix_stage_running STAGE
#
# Print the pid of a process that is ACTUALLY EXECUTING
# `bash .../ca8-core-run.sh STAGE ...`, and return 0; return 1 when there is none.
#
# Do NOT use `pgrep -f 'ca8-core-run\.sh stage1'` for this.  Measured on the
# laptop: it matches my own z2 submission tickets, because z2run.sh takes the
# remote command as ARGUMENTS, so the runner string sits in the argv of the
# heavy-turn ticket, its launcher and the z2run wrapper.  A queued z2 ticket is
# not a local stage1.  With the pgrep form, goonix-ca8/stage2-gate-after-stage1.sh
# REFUSED on 2026-11-24 07:11:28 with no stage1 running at all - the three matches
# were the counted3 ticket, its launcher and its z2run wrapper.  The same trap was
# first fixed in continuation-then-stage2.sh (744ca029b21); this is the shared
# form, so a third caller does not reintroduce it.
#
# argv[0] must be a bash, argv[1] must end in ca8-core-run.sh, argv[2] must be
# exactly the requested stage.  A string buried in another command's arguments
# cannot satisfy that.
goonix_stage_running() {
  local want=${1:?stage name required}
  local p argv0 argv1 argv2
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    { read -r -d '' argv0; read -r -d '' argv1; read -r -d '' argv2; } \
      < "$p/cmdline" 2>/dev/null || continue
    case "$argv0" in */bash|bash) ;; *) continue ;; esac
    case "$argv1" in */ca8-core-run.sh|ca8-core-run.sh) ;; *) continue ;; esac
    [ "$argv2" = "$want" ] || continue
    printf '%s\n' "${p#/proc/}"
    return 0
  done
  return 1
}
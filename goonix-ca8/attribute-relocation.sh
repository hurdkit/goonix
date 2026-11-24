#!/usr/bin/env bash
# goonix: attribute a relocation FAIL to the bytes that carry the hidden self
# reference.  Two builds of one recipe under two salts realised two items; the
# plan (4.4) says such a package is opaque.  This finds WHERE, so the finding
# is a diagnosis and not just a verdict.
#
# Read-only: it never writes into the store.
set -uo pipefail
A=${1:?item A}
B=${2:?item B}
ha=$(basename "$A" | cut -c1-32)
hb=$(basename "$B" | cut -c1-32)
echo "=== $(basename "$A")"
echo "=== $(basename "$B")"
echo "hash A=$ha"
echo "hash B=$hb"

# Which files differ at all?
diff -rq --no-dereference "$A" "$B" 2>/dev/null | head -40 > /tmp/reloc-diffq.txt
echo "--- differing entries: $(wc -l < /tmp/reloc-diffq.txt) (first 40) ---"
cat /tmp/reloc-diffq.txt

# For each differing regular file, classify the difference:
#   plain  : the file contains A's hash or B's hash literally (a self reference
#            the rewriter SHOULD have reached - would be a goonix bug)
#   hidden : neither hash appears, so the difference is derived from the self
#            path some other way (hashed, encoded, fragmented) -> opaque
echo "--- classification of differing regular files ---"
diff -rq --no-dereference "$A" "$B" 2>/dev/null |
  sed -n 's/^Files \(.*\) and \(.*\) differ$/\1|\2/p' |
  head -25 |
  while IFS='|' read -r fa fb; do
    [ -f "$fa" ] && [ -f "$fb" ] || continue
    a_has=$(grep -c "$ha" "$fa" 2>/dev/null || echo 0)
    b_has=$(grep -c "$hb" "$fb" 2>/dev/null || echo 0)
    rel=${fa#"$A"}
    if [ "$a_has" -gt 0 ] || [ "$b_has" -gt 0 ]; then
      printf 'PLAIN  %s (A-hash lines=%s B-hash lines=%s)\n' "$rel" "$a_has" "$b_has"
    else
      # First differing byte offset, and the size of each side.
      off=$(cmp "$fa" "$fb" 2>/dev/null | sed -n 's/.*differ: byte \([0-9]*\).*/\1/p')
      printf 'HIDDEN %s (first diff byte=%s, sizes %s/%s)\n' \
        "$rel" "${off:-?}" "$(stat -c%s "$fa")" "$(stat -c%s "$fb")"
    fi
  done
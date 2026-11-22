/* Deterministic regression for the goonix_dedup_link temp-path buffer overflow.
 *
 * The bug (f4e4ab0 and earlier): goonix_dedup_link appended a "-<pid>-<attempt>"
 * suffix with snprintf(temp_path + strlen(temp_path), 32, ...), writing up to 32
 * bytes past the caller's buffer.  The Haskell caller passed B.useAsCString,
 * which allocates only strlen+1 bytes, so the suffix overflowed adjacent heap
 * (the CI evacuate+115 segfault reading text bytes 0x302d2e = ".-0").
 *
 * This test calls the shim exactly as the unfixed Haskell caller did: a buffer
 * of strlen(prefix)+1 bytes, with a canary region immediately after it.  It then
 * checks the canary.  UNFIXED: the suffix overwrites the canary -> FAIL.
 * FIXED (capacity-aware): snprintf is bounded to the capacity -> canary intact
 * -> PASS.  Deterministic, no daemon, no GC-layout luck.
 *
 * Build: gcc -I daemon/cbits -o /tmp/dedup-overflow-test \
 *          daemon/test/differential/dedup-overflow-test.c daemon/cbits/files.c
 * (files.c needs only libc + errno; the other shims are not referenced here.)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#ifdef UNFIXED_3ARG
/* f4e4ab0 shim: no capacity parameter; appends suffix past the buffer end. */
extern int goonix_dedup_link(const char *path, const char *link_path,
                             const char *temp_path);
#define DEDUP_CALL(src, lp, buf, cap) goonix_dedup_link(src, lp, (const char *)(buf))
#else
/* Fixed shim: capacity-bounded snprintf. */
extern int goonix_dedup_link(const char *path, const char *link_path,
                             char *temp_path, size_t temp_cap);
#define DEDUP_CALL(src, lp, buf, cap) goonix_dedup_link(src, lp, (char *)(buf), cap)
#endif

/* A canary-filled region placed right after the temp buffer in one allocation,
 * mimicking an adjacent heap object.  We pass temp_cap = prefix_len+1 (the
 * unfixed caller's effective capacity) so the FIXED shim also bounds to it and
 * would truncate rather than overflow; the UNFIXED shim ignores capacity. */
int main(void) {
  const char *prefix = "/gnu/store/.tmp-goonix-dedup";
  size_t plen = strlen(prefix);
  size_t cap = plen + 1;            /* what B.useAsCString allocates */
  size_t canary = 64;
  unsigned char *block = malloc(cap + canary);
  if (!block) return 2;
  memcpy(block, prefix, plen);
  block[plen] = '\0';
  memset(block + cap, 0xA5, canary);  /* canary */

  /* Create a real source file and a .links target dir so dedup proceeds to the
   * temp-path branch (link() fails EEXIST after the first, forcing rename). */
  char tmpl[] = "/tmp/dedup-test-XXXXXX";
  char *dir = mkdtemp(tmpl);
  if (!dir) return 2;
  char src[256], links[256], linkpath[256];
  snprintf(src, sizeof src, "%s/src", dir);
  snprintf(links, sizeof links, "%s/.links", dir);
  snprintf(linkpath, sizeof linkpath, "%s/.links/hash", dir);
  mkdir(links, 0755);
  FILE *f = fopen(src, "w"); fputs("payload", f); fclose(f);
  /* Pre-create the link target with the SAME SIZE as src but a different inode,
   * so link(src, linkpath) returns EEXIST on every attempt (sizes equal => no
   * unlink), the first loop exhausts 100 attempts with result==0, and the shim
   * enters the temp-suffix rename branch that writes past the buffer. */
  f = fopen(linkpath, "w"); fputs("XXXXXXX", f); fclose(f);  /* 7 bytes, same as "payload" */

  /* Call as the UNFIXED caller did: capacity = plen+1 (no room for suffix). */
  DEDUP_CALL(src, linkpath, block, cap);

  int overflow = 0;
  for (size_t i = 0; i < canary; i++)
    if (block[cap + i] != 0xA5) { overflow = 1; break; }

  printf("prefix_len=%zu cap=%zu suffix_would_need=%zu\n",
         plen, cap, plen + 32);
  if (overflow) {
    printf("RESULT: OVERFLOW — canary corrupted past the %zu-byte buffer "
           "(the f4e4ab0 bug)\n", cap);
    /* show the bytes written past the buffer */
    printf("bytes past buffer: ");
    for (size_t i = 0; i < 16; i++) printf("%02x ", block[cap + i]);
    printf("\n");
  } else {
    printf("RESULT: OK — canary intact, no overflow (capacity-bounded)\n");
  }
  /* cleanup */
  unlink(src); unlink(linkpath); rmdir(links); rmdir(dir);
  free(block);
  return overflow ? 1 : 0;
}
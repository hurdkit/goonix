/* Dedup parity regression: the first loop must call link(path, link_path) ONLY
 * when link_path is missing, as C++ optimise-store.cc does at `retry:`.
 *
 * The bug (0871201ce61 and earlier): when link_path existed with EQUAL size and
 * a different inode, the first loop fell through to link(path, link_path), which
 * can only return EEXIST (the target exists), and retried that 100 times before
 * reaching the temp-link step.  Every real dedup hit thus wasted 100 link()
 * calls.  C++ goes straight to the temp link when the sizes match.
 *
 * This test pre-creates an equal-size, different-inode target at link_path and
 * calls goonix_dedup_link with a properly sized buffer.  It asserts:
 *   - the return value is 2 (the file was replaced by a hard link via the temp
 *     link + rename), and
 *   - link() was attempted on link_path (i.e. link(_, link_path)) ZERO times,
 *     and exactly ONE link() call total (the productive link(link_path, temp)).
 * Counted with -Wl,--wrap=link: __wrap_link intercepts every link() call.
 *
 * FAILS on 0871201ce61 (100 wasteful link(_, link_path) attempts, 101 total).
 * PASSES with the parity fix (0 wasteful, 1 total, return 2).
 *
 * Build:
 *   cc -I daemon/cbits -Wl,--wrap=link -o /tmp/dedup-linkcount-test \
 *      daemon/test/differential/dedup-linkcount-test.c daemon/cbits/files.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

extern int goonix_dedup_link(const char *path, const char *link_path,
                             char *temp_path, size_t temp_cap);

/* The link_path under test, so the wrapper can classify each link() call. */
static const char *g_link_path = NULL;
static long g_link_total = 0;       /* every link() call */
static long g_link_on_target = 0;   /* link(_, link_path): the wasteful kind */

int __real_link(const char *oldpath, const char *newpath);
int __wrap_link(const char *oldpath, const char *newpath) {
  g_link_total++;
  if (g_link_path && strcmp(newpath, g_link_path) == 0)
    g_link_on_target++;
  return __real_link(oldpath, newpath);
}

int main(void) {
  char tmpl[] = "/tmp/dedup-lc-XXXXXX";
  char *dir = mkdtemp(tmpl);
  if (!dir) return 2;
  char src[256], links[256], linkpath[256], prefix[256];
  snprintf(src, sizeof src, "%s/src", dir);
  snprintf(links, sizeof links, "%s/.links", dir);
  snprintf(linkpath, sizeof linkpath, "%s/.links/hash", dir);
  /* The temp-link prefix must live in a WRITABLE directory (the real /gnu/store
     is read-only); use the test dir, as the daemon uses its own store dir. */
  snprintf(prefix, sizeof prefix, "%s/.tmp-goonix-dedup", dir);
  size_t plen = strlen(prefix);
  size_t cap = plen + 32;            /* properly sized: prefix + suffix room */
  char *buf = malloc(cap);
  if (!buf) return 2;
  memcpy(buf, prefix, plen);
  buf[plen] = '\0';

  mkdir(links, 0755);
  FILE *f = fopen(src, "w"); fputs("payload", f); fclose(f);
  /* Equal-size (7 bytes), different-inode target already present. */
  f = fopen(linkpath, "w"); fputs("XXXXXXX", f); fclose(f);
  g_link_path = linkpath;

  int rc = goonix_dedup_link(src, linkpath, buf, cap);

  printf("return=%d link_total=%ld link_on_target=%ld\n",
         rc, g_link_total, g_link_on_target);
  int fail = 0;
  if (rc != 2) {
    printf("FAIL: expected return 2 (temp link + rename), got %d\n", rc);
    fail = 1;
  }
  if (g_link_on_target != 0) {
    printf("FAIL: %ld wasteful link(_, link_path) attempts (C++ does 0 when the "
           "equal-size target exists)\n", g_link_on_target);
    fail = 1;
  }
  if (g_link_total != 1) {
    printf("FAIL: expected exactly 1 link() call (the temp link), got %ld\n",
           g_link_total);
    fail = 1;
  }
  if (!fail)
    printf("PASS: return 2 after exactly one link() attempt, none on link_path\n");

  unlink(src); unlink(linkpath); rmdir(links); rmdir(dir);
  free(buf);
  return fail ? 1 : 0;
}
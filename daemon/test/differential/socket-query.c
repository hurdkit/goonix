/* goonix: connect to a Unix socket (chdir + relative name, so >108-byte paths
   work), perform the worker-protocol handshake and one wopQueryAllValidPaths
   (op 23), so the daemon opens its store.  Used to compare empty-root start-up:
   the C++ daemon opens the store lazily on the first operation, not on connect. */
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <libgen.h>
#include <errno.h>

static int write_full(int fd, const void *buf, size_t n) {
  const unsigned char *p = buf;
  while (n) { ssize_t w = write(fd, p, n); if (w <= 0) { if (errno == EINTR) continue; return -1; } p += w; n -= w; }
  return 0;
}
static int read_full(int fd, void *buf, size_t n) {
  unsigned char *p = buf;
  while (n) { ssize_t r = read(fd, p, n); if (r <= 0) { if (r < 0 && errno == EINTR) continue; return -1; } p += r; n -= r; }
  return 0;
}
static int put_u64(int fd, uint64_t v) { unsigned char b[8]; for (int i = 0; i < 8; i++) b[i] = (v >> (i * 8)) & 0xff; return write_full(fd, b, 8); }
static int get_u64(int fd, uint64_t *v) { unsigned char b[8]; if (read_full(fd, b, 8)) return -1; *v = 0; for (int i = 7; i >= 0; i--) *v = (*v << 8) | b[i]; return 0; }

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: socket-query PATH\n"); return 2; }
  char dirbuf[4096], basebuf[4096];
  snprintf(dirbuf, sizeof dirbuf, "%s", argv[1]);
  snprintf(basebuf, sizeof basebuf, "%s", argv[1]);
  char *dir = dirname(dirbuf);
  char *base = basename(basebuf);
  if (chdir(dir) < 0) { perror("chdir"); return 1; }
  char rel[2 + strlen(base) + 1];
  rel[0] = '.'; rel[1] = '/';
  memcpy(rel + 2, base, strlen(base) + 1);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return 1;
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  address.sun_family = AF_UNIX;
  if (strlen(rel) >= sizeof(address.sun_path)) { fprintf(stderr, "relative name too long\n"); return 1; }
  strcpy(address.sun_path, rel);
  if (connect(fd, (struct sockaddr *)&address, sizeof address) < 0) { perror("connect"); return 1; }

  /* Handshake: magic, server magic+version, client version, affinity, cpu. */
  uint64_t v;
  if (put_u64(fd, 0x6e697863)) return 1;
  if (get_u64(fd, &v) || v != 0x6478696f) { fprintf(stderr, "bad server magic\n"); return 1; }
  if (get_u64(fd, &v)) return 1;              /* server protocol version */
  if (put_u64(fd, 0x166)) return 1;           /* client version (minor 0x66) */
  if (put_u64(fd, 0)) return 1;               /* affinity: none */
  if (put_u64(fd, 0)) return 1;               /* cpu count: unchanged */

  /* Read startup stderr frames until stderrLast (0x616c7473). */
  for (;;) {
    if (get_u64(fd, &v)) return 1;
    if (v == 0x616c7473) break;               /* stderrLast */
    if (v == 0x6f6c6d67 || v == 0x64617461 || v == 0x64617416) { /* next/read/write: a string */
      uint64_t len; if (get_u64(fd, &len)) return 1;
      unsigned char buf[65536];
      uint64_t orig = len;
      while (len) { uint64_t chunk = len > sizeof buf ? sizeof buf : len; if (read_full(fd, buf, chunk)) return 1; len -= chunk; }
      uint64_t pad = (8 - (orig % 8)) % 8;
      if (pad) { unsigned char p[8]; if (read_full(fd, p, pad)) return 1; }
    } else { fprintf(stderr, "unexpected stderr frame %llx\n", (unsigned long long)v); return 1; }
  }

  /* wopQueryAllValidPaths = 23, no arguments. */
  if (put_u64(fd, 23)) return 1;
  /* Reply: stderr frames then a string list. */
  for (;;) {
    if (get_u64(fd, &v)) return 1;
    if (v == 0x616c7473) break;
    if (v == 0x6f6c6d67 || v == 0x64617461 || v == 0x64617416) {
      uint64_t len; if (get_u64(fd, &len)) return 1;
      unsigned char buf[65536];
      uint64_t orig = len;
      while (len) { uint64_t chunk = len > sizeof buf ? sizeof buf : len; if (read_full(fd, buf, chunk)) return 1; len -= chunk; }
      uint64_t pad = (8 - (orig % 8)) % 8;
      if (pad) { unsigned char p[8]; if (read_full(fd, p, pad)) return 1; }
    } else { fprintf(stderr, "unexpected reply frame %llx\n", (unsigned long long)v); return 1; }
  }
  uint64_t count; if (get_u64(fd, &count)) return 1;
  printf("connected, %llu valid paths\n", (unsigned long long)count);
  close(fd);
  return 0;
}
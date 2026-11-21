/* goonix: streaming build-log writers, matching the C++ daemon. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <zlib.h>
#include <bzlib.h>

/* KIND is 0 for an uncompressed log, 1 for gzip, and 2 for bzip2.
   The returned pointer owns the file descriptor. */
void *goonix_open_log(const char *path, int kind) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0666);
  if (fd < 0) return NULL;
  if (kind == 1) {
    gzFile stream = gzdopen(fd, "w");
    if (stream == NULL) { close(fd); errno = ENOMEM; return NULL; }
    gzbuffer(stream, 32768);
    gzsetparams(stream, Z_BEST_COMPRESSION, Z_DEFAULT_STRATEGY);
    return stream;
  }
  if (kind == 2) {
    FILE *file = fdopen(fd, "w");
    if (file == NULL) { close(fd); return NULL; }
    int error = 0;
    BZFILE *stream = BZ2_bzWriteOpen(&error, file, 9, 0, 0);
    if (stream == NULL) { fclose(file); errno = ENOMEM; return NULL; }
    /* The BZ2_bzWrite API does not own FILE*, so retain it alongside BZFILE. */
    FILE **pair = malloc(sizeof *pair * 2);
    if (pair == NULL) {
      BZ2_bzWriteClose(&error, stream, 1, NULL, NULL);
      fclose(file);
      errno = ENOMEM;
      return NULL;
    }
    pair[0] = (FILE *)stream;
    pair[1] = file;
    return pair;
  }
  return (void *)(intptr_t)(fd + 1);
}

int goonix_write_log(void *stream, int kind, const void *bytes, size_t size) {
  if (kind == 1)
    return gzwrite(stream, bytes, size) == 0 ? -1 : 0;
  if (kind == 2) {
    FILE **pair = stream;
    int error = 0;
    BZ2_bzWrite(&error, pair[0], (void *)bytes, size);
    return error == BZ_OK ? 0 : -1;
  }
  int fd = (int)(intptr_t)stream - 1;
  const char *cursor = bytes;
  while (size > 0) {
    ssize_t written = write(fd, cursor, size);
    if (written < 0) { if (errno == EINTR) continue; return -1; }
    if (written == 0) { errno = EIO; return -1; }
    cursor += written;
    size -= written;
  }
  return 0;
}

int goonix_close_log(void *stream, int kind) {
  if (kind == 1) return gzclose(stream) == Z_OK ? 0 : -1;
  if (kind == 2) {
    FILE **pair = stream;
    int error = 0;
    BZ2_bzWriteClose(&error, pair[0], 0, 0, 0);
    int closeError = fclose(pair[1]);
    free(pair);
    return error == BZ_OK && closeError == 0 ? 0 : -1;
  }
  return close((int)(intptr_t)stream - 1);
}

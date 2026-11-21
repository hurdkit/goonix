/* goonix: byte-path filesystem and POSIX-lock operations. */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int goonix_restore_node(const char *path, int kind, int executable,
                        const unsigned char *data, uint64_t length) {
  if (kind == 0) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0666);
    if (fd < 0) return -1;
    uint64_t done = 0;
    while (done < length) {
      ssize_t n = write(fd, data + done, length - done);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { int saved = errno; close(fd); errno = saved; return -1; }
      done += n;
    }
    if (close(fd) < 0) return -1;
    if (executable && chmod(path, 0755) < 0) return -1;
    return 0;
  }
  if (kind == 1) return symlink((const char *)data, path);
  if (kind == 2) return mkdir(path, 0777);
  errno = EINVAL;
  return -1;
}

int goonix_canonicalize(const char *path) {
  struct stat st;
  if (lstat(path, &st) < 0) return -1;
  if (!S_ISLNK(st.st_mode)) {
    mode_t mode = 0444 | ((st.st_mode & S_IXUSR) ? 0111 : 0);
    if (chmod(path, mode) < 0) return -1;
  }
  /* Match canonicalisePathMetaData_ in nix/libstore/local-store.cc: take
     ownership of the output for the daemon (root).  A build user's output
     arrives owned by that user; the store item must be root-owned.  lchown
     leaves symlinks' targets alone, as in the C++ daemon. */
  if (st.st_uid != geteuid()) {
    if (lchown(path, geteuid(), getegid()) < 0) return -1;
  }
  struct timeval times[2];
  times[0].tv_sec = st.st_atime;
  times[0].tv_usec = 0;
  times[1].tv_sec = 1;
  times[1].tv_usec = 0;
  return lutimes(path, times);
}

int goonix_lock_exclusive(const char *path) {
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return -1;
  struct flock lock;
  memset(&lock, 0, sizeof lock);
  lock.l_type = F_WRLCK;
  lock.l_whence = SEEK_SET;
  while (fcntl(fd, F_SETLKW, &lock) < 0) {
    if (errno != EINTR) { int saved = errno; close(fd); errno = saved; return -1; }
  }
  struct stat st;
  if (fstat(fd, &st) < 0) { int saved = errno; close(fd); errno = saved; return -1; }
  if (st.st_size != 0) { close(fd); errno = EAGAIN; return -1; }
  return fd;
}

int goonix_unlock_delete(int fd, const char *path) {
  unlink(path);
  ssize_t ignored = write(fd, "d", 1);
  (void)ignored;
  return close(fd);
}

/* A deleted lock file is marked by its last holder. While we waited for its
 * lock, another process may have opened the replacement at the same name. */
int goonix_lock_stale(int fd) {
  struct stat st;
  if (fstat(fd, &st) < 0) return -1;
  return st.st_size != 0;
}

int goonix_make_symlink(const char *target, const char *link) {
  return symlink(target, link);
}

int goonix_rename(const char *from, const char *to) {
  return rename(from, to);
}

int goonix_mkdir_parents(const char *path, mode_t mode) {
  size_t n = strlen(path);
  char copy[n + 1];
  memcpy(copy, path, n + 1);
  for (size_t i = 1; i <= n; i++) {
    if (copy[i] == '/' || copy[i] == '\0') {
      char saved = copy[i];
      copy[i] = '\0';
      if (mkdir(copy, mode) < 0 && errno != EEXIST) return -1;
      copy[i] = saved;
    }
  }
  return 0;
}

int goonix_open_lock(const char *path, int create) {
  return open(path, O_RDWR | (create ? O_CREAT : 0) | O_CLOEXEC, 0600);
}

int goonix_lock_shared(const char *path, int create) {
  int fd = open(path, O_RDWR | (create ? O_CREAT : 0) | O_CLOEXEC, 0600);
  if (fd < 0) return -1;
  struct flock lock;
  memset(&lock, 0, sizeof lock);
  lock.l_type = F_RDLCK;
  lock.l_whence = SEEK_SET;
  while (fcntl(fd, F_SETLKW, &lock) < 0) {
    if (errno != EINTR) { int saved = errno; close(fd); errno = saved; return -1; }
  }
  return fd;
}

int goonix_lock_upgrade(int fd, int write_lock) {
  struct flock lock;
  memset(&lock, 0, sizeof lock);
  lock.l_type = write_lock ? F_WRLCK : F_RDLCK;
  lock.l_whence = SEEK_SET;
  while (fcntl(fd, F_SETLKW, &lock) < 0) {
    if (errno != EINTR) return -1;
  }
  return 0;
}

int goonix_lock_nonblocking(int fd, int write_lock) {
  struct flock lock;
  memset(&lock, 0, sizeof lock);
  lock.l_type = write_lock ? F_WRLCK : F_RDLCK;
  lock.l_whence = SEEK_SET;
  return fcntl(fd, F_SETLK, &lock);
}

int goonix_write_at_end(int fd, const unsigned char *bytes, uint64_t length) {
  if (lseek(fd, 0, SEEK_END) < 0) return -1;
  while (length) {
    ssize_t n = write(fd, bytes, length);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    bytes += n;
    length -= n;
  }
  return 0;
}

int goonix_dedup_link(const char *path, const char *link_path, const char *temp_path) {
  const char *slash = strrchr(path, '/');
  char parent[4096];
  if (!slash || (size_t)(slash - path) >= sizeof parent) { errno = ENAMETOOLONG; return -1; }
  memcpy(parent, path, slash - path);
  parent[slash - path] = '\0';
  struct stat parent_stat;
  if (stat(parent, &parent_stat) < 0) return -1;
  if (chmod(parent, parent_stat.st_mode | S_IWUSR | S_IXUSR) < 0) return -1;
  int result = 0;
  for (unsigned int attempt = 0; attempt < 100; ++attempt) {
    struct stat source_stat, link_stat;
    if (lstat(path, &source_stat) < 0) { result = -1; break; }
    if (lstat(link_path, &link_stat) == 0) {
      if (source_stat.st_ino == link_stat.st_ino) { result = 1; break; }
      if (source_stat.st_size != link_stat.st_size) {
        if (unlink(link_path) < 0) { result = -1; break; }
        continue;
      }
    } else if (errno != ENOENT) { result = -1; break; }
    if (link(path, link_path) == 0) { result = 1; break; }
    if (errno == EEXIST) continue;
    if (errno == ENOSPC) break;
    result = -1;
    break;
  }
  if (result == 0) {
    for (unsigned int attempt = 0; attempt < 100; ++attempt) {
      size_t length = strlen(temp_path);
      if (snprintf((char *)temp_path + length, 32, "-%ld-%u", (long)getpid(), attempt) >= 32) {
        result = -1;
        errno = ENAMETOOLONG;
        break;
      }
      if (link(link_path, temp_path) == 0) {
        if (rename(temp_path, path) == 0) result = 2;
        else {
          result = errno == EMLINK ? 1 : -1;
          int saved = errno;
          unlink(temp_path);
          errno = saved;
        }
        break;
      }
      if (errno == EEXIST) continue;
      result = errno == EMLINK ? 1 : -1;
      break;
    }
  }
  int saved = errno;
  if (chmod(parent, parent_stat.st_mode) < 0 && result >= 0) { saved = errno; result = -1; }
  errno = saved;
  return result;
}

int goonix_remove_tree(const char *path) {
  /* The Haskell caller supplies an already validated direct store path. */
  struct stat st;
  if (lstat(path, &st) < 0) return errno == ENOENT ? 0 : -1;
  if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
    if (chmod(path, st.st_mode | S_IWUSR) < 0 && !S_ISLNK(st.st_mode)) return -1;
    return unlink(path);
  }
  errno = ENOTSUP;
  return -1;
}

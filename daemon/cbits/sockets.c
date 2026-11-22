/* goonix: small socket bridge; no Haskell code runs in a forked child. */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>
#include <sys/select.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

/* goonix: bind a Unix-domain socket exactly as the C++ daemon's
   open_unix_domain_socket (nix/nix-daemon/guix-daemon.cc): create the parent
   directories, chdir into them and bind the relative name "./socket" (so the
   108-byte sun_path limit applies to the basename, not the whole path), unlink
   a stale socket first, bind under umask(0111) so the socket is 0666, chdir
   back, then listen.  Returns the fd, or -step on failure so the caller can
   name the file and the step, as the C++ messages do:
     -1 socket, -2 createDirs, -3 chdir(dir), -4 name too long,
     -5 bind, -6 chdir(/), -7 listen.
   The working directory is restored even when a step fails. */
static int mkdir_parents_socket(const char *path) {
  size_t n = strlen(path);
  char copy[n + 1];
  memcpy(copy, path, n + 1);
  for (size_t i = 1; i <= n; i++) {
    if (copy[i] == '/' || copy[i] == '\0') {
      char saved = copy[i];
      copy[i] = '\0';
      if (mkdir(copy, 0777) < 0 && errno != EEXIST) return -1;
      copy[i] = saved;
    }
  }
  return 0;
}

int goonix_listen_unix(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;

  /* dirOf(path) and baseNameOf(path). */
  const char *slash = strrchr(path, '/');
  char dir[slash ? (size_t)(slash - path) + 1 : 2];
  const char *base;
  if (slash) {
    if (slash == path) { dir[0] = '/'; dir[1] = '\0'; }
    else { memcpy(dir, path, (size_t)(slash - path)); dir[slash - path] = '\0'; }
    base = slash + 1;
  } else { dir[0] = '.'; dir[1] = '\0'; base = path; }

  if (mkdir_parents_socket(dir) < 0) { close(fd); return -2; }

  /* Save the working directory so it can be restored on every exit path. */
  char saved_cwd[4096];
  if (getcwd(saved_cwd, sizeof saved_cwd) == NULL) { close(fd); return -3; }
  if (chdir(dir) < 0) { close(fd); return -3; }

  char rel[2 + strlen(base) + 1];
  rel[0] = '.'; rel[1] = '/';
  memcpy(rel + 2, base, strlen(base) + 1);
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  if (strlen(rel) >= sizeof(address.sun_path)) {
    if (chdir(saved_cwd) < 0) { /* best effort restore */ }
    close(fd); errno = ENAMETOOLONG; return -4;
  }
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, rel, strlen(rel) + 1);

  unlink(path);

  mode_t oldMode = umask(0111);
  int res = bind(fd, (struct sockaddr *)&address, sizeof address);
  umask(oldMode);
  if (res < 0) {
    int saved = errno;
    if (chdir(saved_cwd) < 0) { /* best effort restore */ }
    close(fd); errno = saved; return -5;
  }

  if (chdir(saved_cwd) < 0) { int saved = errno; close(fd); errno = saved; return -6; }

  if (listen(fd, 5) < 0) { int saved = errno; close(fd); errno = saved; return -7; }
  return fd;
}

/* The errno of the last failed socket step, for the caller's message. */
int goonix_socket_errno(void) { return errno; }

int goonix_listen_tcp(const char *host, const char *service) {
  struct addrinfo hints, *addresses = NULL;
  memset(&hints, 0, sizeof hints);
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_family = AF_UNSPEC;
  hints.ai_flags = AI_NUMERICSERV | AI_ADDRCONFIG;
  int error = getaddrinfo(host, service, &hints, &addresses);
  if (error != 0) { errno = EHOSTUNREACH; return -1; }
  int fd = -1;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    fd = socket(address->ai_family, address->ai_socktype | SOCK_CLOEXEC, address->ai_protocol);
    if (fd < 0) continue;
    if (bind(fd, address->ai_addr, address->ai_addrlen) == 0 && listen(fd, 5) == 0) break;
    close(fd); fd = -1;
  }
  freeaddrinfo(addresses);
  return fd;
}

int goonix_accept(int fd) {
  for (;;) {
    int client = accept4(fd, NULL, NULL, SOCK_CLOEXEC);
    if (client >= 0) return client;
    if (errno == EINTR) continue;
    if (errno != EAGAIN && errno != EWOULDBLOCK) return -1;
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(fd, &readfds);
    int ready;
    do { ready = select(fd + 1, &readfds, NULL, NULL, NULL); }
    while (ready < 0 && errno == EINTR);
    if (ready < 0) return -1;
  }
}

int goonix_peer_uid(int fd, uid_t *uid) {
#ifdef SO_PEERCRED
  struct ucred credential;
  socklen_t size = sizeof credential;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential, &size) < 0) return -1;
  *uid = credential.uid;
  return 0;
#else
  (void)fd; (void)uid; errno = ENOTSUP; return -1;
#endif
}

int goonix_is_tcp(int fd) {
  struct sockaddr_storage address;
  socklen_t size = sizeof address;
  if (getsockname(fd, (struct sockaddr *)&address, &size) < 0) return -1;
  return address.ss_family == AF_INET || address.ss_family == AF_INET6;
}

int goonix_is_listening(int fd) {
  int value = 0;
  socklen_t size = sizeof value;
  if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &value, &size) < 0) return -1;
  return value;
}

/* Inspect the next byte without consuming it or blocking. Input is not a
   disconnect: the caller stops its runtime-managed watcher in that case. */
int goonix_peek_socket(int fd) {
  char byte;
  ssize_t result;
  do { result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT); }
  while (result < 0 && errno == EINTR);
  if (result == 0) return 0;
  if (result > 0) return 1;
  return errno == EAGAIN || errno == EWOULDBLOCK ? 2 : 3;
}

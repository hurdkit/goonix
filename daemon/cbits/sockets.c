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

int goonix_listen_unix(const char *path) {
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return -1;
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  size_t length = strlen(path);
  if (length >= sizeof(address.sun_path)) { close(fd); errno = ENAMETOOLONG; return -1; }
  address.sun_family = AF_UNIX;
  memcpy(address.sun_path, path, length + 1);
  unlink(path);
  if (bind(fd, (struct sockaddr *)&address, sizeof address) < 0 || listen(fd, 5) < 0 ||
      /* umask is process-wide: do not race directory creation in other
         connection threads.  Set the socket's mode after binding instead. */
      fchmodat(AT_FDCWD, path, 0666, 0) < 0) {
    int saved = errno;
    close(fd);
    unlink(path);
    errno = saved;
    return -1;
  }
  return fd;
}

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

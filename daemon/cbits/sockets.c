/* goonix: small socket bridge and start-up helpers; no Haskell code runs in
   a forked child. */
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
#include <signal.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include <sys/statvfs.h>
#ifdef __linux__
#include <sched.h>
#include <sys/mount.h>
#endif

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

/* Accept one client from a non-blocking listening socket.  Returns the
   client, -2 when no connection is waiting (the caller waits for the socket
   in the runtime's I/O manager, where the wait can be given up), -1 on any
   other error. */
int goonix_accept_ready(int fd) {
  for (;;) {
    int client = accept4(fd, NULL, NULL, SOCK_CLOEXEC);
    if (client >= 0) return client;
    if (errno == EINTR || errno == ECONNABORTED) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return -2;
    return -1;
  }
}

/* Whether a signal was being ignored when the listening process started.
   The C++ daemon installs no handler for SIGTERM, SIGINT and SIGHUP in that
   process, so one that it inherited as ignored stays ignored: `nohup', and a
   shell without job control that starts the daemon in the background, rely
   on it.  The Haskell runtime replaces the SIGINT disposition before any
   Haskell code runs, so the dispositions are recorded from a constructor,
   which runs before that. */
static unsigned long ignored_at_start;
/* The signal mask the process started with, for goonix_make_store_writable,
   which starts the daemon again. */
static sigset_t mask_at_start;

static const int stop_signals[] = { SIGHUP, SIGINT, SIGTERM };

__attribute__((constructor)) static void record_ignored_signals(void) {
  for (size_t i = 0; i < sizeof stop_signals / sizeof stop_signals[0]; i++) {
    struct sigaction action;
    if (sigaction(stop_signals[i], NULL, &action) == 0 && action.sa_handler == SIG_IGN)
      ignored_at_start |= 1UL << stop_signals[i];
  }
  sigprocmask(SIG_BLOCK, NULL, &mask_at_start);
}

int goonix_ignored_at_start(int sig) {
  return sig > 0 && sig < 32 && ((ignored_at_start >> sig) & 1UL);
}

/* goonix: the C++ LocalStore::ensureStoreWritable (nix/libstore/local-store.cc)
   for the daemon process.  When STORE is on a read-only mount, a root daemon
   gets a private mount namespace in which the store is remounted writable
   (unshare(CLONE_NEWNS), then mount(MS_REMOUNT | MS_BIND)); a daemon that is
   not root cannot, and fails.

   The C++ daemon does this in each connection's process, which is
   single-threaded.  This daemon is one threaded process, and unshare gives
   the new namespace to the calling thread alone: the runtime's other threads,
   and the builders and helpers that they start, would still see the store
   read-only.  So once the store is remounted in this thread's namespace, the
   thread executes the daemon again, with the same arguments and environment:
   execve ends the other threads, and the program that it starts, with all of
   its threads and children, runs in the namespace that has the writable
   store.  The PID stays the same, so systemd's LISTEN_PID still names it, and
   the inherited sockets stay open.  The dispositions of SIGHUP, SIGINT and
   SIGTERM and the signal mask are first put back as the process found them,
   so that the new program records the same ones (the runtime has replaced
   SIGINT's by then).  _GOONIX_STORE_REMOUNTED, set to STORE for the new
   program and removed from the environment by it, tells it that the remount
   is done: a store whose file system itself is read-only stays read-only
   after a bind remount, and C++ goes on in that case too.

   Returns 0 when the store is writable or has been remounted, 1 when it is
   read-only and the daemon is not root, and -1 (statvfs), -2 (unshare), -3
   (mount) or -4 (executing the daemon again) with errno set on failure.  It
   does not return after a remount.  Without unshare and bind mounts (GNU/Hurd)
   it does nothing, as C++ does. */
#define REMOUNTED_STORE "_GOONIX_STORE_REMOUNTED"

extern void getFullProgArgv(int *argc, char **argv[]); /* GHC runtime */

int goonix_make_store_writable(const char *store) {
  const char *remounted = getenv(REMOUNTED_STORE);
  int done = remounted != NULL && strcmp(remounted, store) == 0;
  unsetenv(REMOUNTED_STORE);
  if (done) return 0;
#if defined(__linux__) && defined(CLONE_NEWNS) && defined(MS_BIND) && defined(MS_REMOUNT)
  struct statvfs status;
  if (statvfs(store, &status) != 0) return -1;
  if (!(status.f_flag & ST_RDONLY)) return 0;
  if (getuid() != 0) return 1;
  if (unshare(CLONE_NEWNS) == -1) return -2;
  if (mount(NULL, store, "none", MS_REMOUNT | MS_BIND, NULL) == -1) return -3;

  int argc = 0;
  char **argv = NULL;
  getFullProgArgv(&argc, &argv);
  if (argc < 1 || argv == NULL) { errno = EINVAL; return -4; }
  char **arguments = calloc((size_t)argc + 1, sizeof *arguments);
  if (arguments == NULL) return -4;
  for (int i = 0; i < argc; i++) arguments[i] = argv[i];
  if (setenv(REMOUNTED_STORE, store, 1) != 0) return -4;
  /* The file that /proc/self/exe names, so that the process keeps its name
     (the kernel takes it from the file name given to execve); the link itself
     when that file is gone. */
  char self[PATH_MAX];
  const char *program = "/proc/self/exe";
  ssize_t length = readlink(program, self, sizeof self - 1);
  if (length > 0) {
    self[length] = '\0';
    if (access(self, X_OK) == 0) program = self;
  }
  for (size_t i = 0; i < sizeof stop_signals / sizeof stop_signals[0]; i++)
    signal(stop_signals[i], goonix_ignored_at_start(stop_signals[i]) ? SIG_IGN : SIG_DFL);
  sigprocmask(SIG_SETMASK, &mask_at_start, NULL);
  execv(program, arguments);
  return -4;
#else
  return 0;
#endif
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

int goonix_peer_pid(int fd, pid_t *pid) {
#ifdef SO_PEERCRED
  struct ucred credential;
  socklen_t size = sizeof credential;
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credential, &size) < 0) return -1;
  if (credential.pid <= 0) { errno = ENOTSUP; return -1; }
  *pid = credential.pid;
  return 0;
#else
  (void)fd; (void)pid; errno = ENOTSUP; return -1;
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

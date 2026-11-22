/* goonix: leave a stale Unix-socket file (bound, never listened) so the test
   can check that a daemon start unlinks it.  Bound then exit: the file stays. */
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: stale-socket PATH\n"); return 2; }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return 1;
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  address.sun_family = AF_UNIX;
  if (strlen(argv[1]) >= sizeof(address.sun_path)) return 1;
  strcpy(address.sun_path, argv[1]);
  unlink(argv[1]);
  if (bind(fd, (struct sockaddr *)&address, sizeof address) < 0) return 1;
  /* Do not listen; exit, leaving the socket file behind. */
  close(fd);
  return 0;
}
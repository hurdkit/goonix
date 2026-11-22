/* goonix: connect to a Unix socket by chdir-ing to its directory and using the
   relative name "./socket", so a >108-byte absolute path still connects (the
   same trick the daemon uses to bind).  Used to verify a long-path socket is
   listening; the Guile client cannot connect to a >108-byte path itself. */
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <libgen.h>

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "usage: socket-connect PATH\n"); return 2; }
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
  close(fd);
  printf("connected\n");
  return 0;
}
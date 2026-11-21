#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  int fd = open(argv[1], O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) { perror("open gc.lock"); return 2; }
  struct flock lock;
  memset(&lock, 0, sizeof lock);
  lock.l_type = F_WRLCK;
  lock.l_whence = SEEK_SET;
  if (fcntl(fd, F_SETLKW, &lock) < 0) { perror("lock gc.lock"); return 2; }
  puts("held");
  fflush(stdout);
  pause();
  return 0;
}

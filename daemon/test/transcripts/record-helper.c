/* goonix: capture helper argv and all three protocol streams without changing them. */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

static int transcript;
static int seen_stdin, seen_stdout, seen_fd4;
static int hexval(int c) {
  const char *digits = "0123456789abcdef";
  return digits[c & 15];
}
static void record(const char *direction, const unsigned char *bytes, ssize_t length) {
  if (length <= 0) return;
  dprintf(transcript, "%s %zd ", direction, length);
  for (ssize_t i = 0; i < length; i++) {
    unsigned char pair[2] = {hexval(bytes[i] >> 4), hexval(bytes[i])};
    if (write(transcript, pair, 2) != 2) _exit(74);
  }
  if (write(transcript, "\n", 1) != 1) _exit(74);
  if (strcmp(direction, "stdin") == 0) seen_stdin = 1;
  if (strcmp(direction, "stdout") == 0) seen_stdout = 1;
  if (strcmp(direction, "fd4") == 0) seen_fd4 = 1;
}
static int make_pipe(int p[2]) { return pipe(p); }
static pid_t spawn(const char *program, char *const argv[], int in, int out, int reply) {
  pid_t pid = fork();
  if (pid != 0) return pid;
  if (dup2(in, 0) < 0 || dup2(out, 1) < 0 || dup2(out, 2) < 0 || dup2(reply, 4) < 0) _exit(127);
  close(in); close(out); close(reply);
  execv(program, argv);
  _exit(127);
}
int main(int argc, char **argv) {
  const char *path = getenv("GOONIX_HELPER_TRANSCRIPT");
  if (!path || argc < 3) return 64;
  transcript = open(path, O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0600);
  if (transcript < 0) return 65;
  dprintf(transcript, "argv");
  for (int i = 1; i < argc; i++) dprintf(transcript, " %s", argv[i]);
  dprintf(transcript, "\n");
  const char *root = getenv("GOONIX_ROOT");
  if (!root) return 66;
  char helper[4096], pre[4096];
  snprintf(pre, sizeof pre, "%s/pre-inst-env", root);
  snprintf(helper, sizeof helper, "%s/daemon/test/transcripts/replay-helper.scm", root);
  int inpipe[2], outpipe[2], replypipe[2];
  if (make_pipe(inpipe) || make_pipe(outpipe) || make_pipe(replypipe)) return 67;
  char *const child_argv[] = {pre, (char *)"guile", (char *)"--no-auto-compile", helper,
    argv[1], argv[2], argc > 3 ? argv[3] : NULL, argc > 4 ? argv[4] : NULL,
    argc > 5 ? argv[5] : NULL, argc > 6 ? argv[6] : NULL, NULL};
  pid_t pid = spawn(pre, child_argv, inpipe[0], outpipe[1], replypipe[1]);
  close(inpipe[0]); close(outpipe[1]); close(replypipe[1]);
  if (pid < 0) return 68;
  int in = inpipe[1], out = outpipe[0], reply = replypipe[0];
  int open_in = 1, open_out = 1, open_reply = 1;
  unsigned char buf[32768];
  while (open_in || open_out || open_reply) {
    fd_set fds;
    FD_ZERO(&fds);
    int maxfd = -1;
    if (open_in) { FD_SET(0, &fds); if (0 > maxfd) maxfd = 0; }
    if (open_out) { FD_SET(out, &fds); if (out > maxfd) maxfd = out; }
    if (open_reply) { FD_SET(reply, &fds); if (reply > maxfd) maxfd = reply; }
    if (select(maxfd + 1, &fds, NULL, NULL, NULL) < 0) {
      if (errno == EINTR) continue;
      return 69;
    }
    if (open_in && FD_ISSET(0, &fds)) {
      ssize_t n = read(0, buf, sizeof buf);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { close(in); open_in = 0; }
      else { record("stdin", buf, n); if (write(in, buf, n) != n) return 70; }
    }
    if (open_out && FD_ISSET(out, &fds)) {
      ssize_t n = read(out, buf, sizeof buf);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { close(out); open_out = 0; }
      else { record("stdout", buf, n); if (write(1, buf, n) != n) return 71; }
    }
    if (open_reply && FD_ISSET(reply, &fds)) {
      ssize_t n = read(reply, buf, sizeof buf);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { close(reply); open_reply = 0; }
      else { record("fd4", buf, n); if (write(4, buf, n) != n) return 71; }
    }
  }
  int status;
  if (waitpid(pid, &status, 0) < 0) return 72;
  if (!seen_stdin && !seen_stdout && !seen_fd4) return 73;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

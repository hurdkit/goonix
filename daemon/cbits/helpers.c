/* goonix: descriptor wiring for exec-only helper processes. */
#define _GNU_SOURCE
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>

#include <sys/types.h>

/* Equivalent to the C++ daemon's killUser: the short-lived child changes to
   the leased uid so kill(-1, SIGKILL) affects only that uid's processes.  On
   Linux kill(-1, sig) does NOT signal the calling process (man 2 kill NOTES;
   kernel/signal.c kill_something_info skips same_thread_group(p, current)), so
   the child survives the sweep and _exit(0); it is not "including itself".
   On failure, fills diag (a caller buffer of diag_len bytes) with the failing
   step and the errno, exit status or signal, so killUser can report the cause
   in the C++ form (nix/libutil/util.cc killUser / statusToString) instead of a
   generic message.  The child exits 127 when setuid fails, 126 when kill fails
   with an errno other than ESRCH/EINTR; the parent distinguishes those, a
   signal death, a waitpid failure and a fork failure. */
int goonix_kill_user(uid_t uid, char *diag, size_t diag_len)
{
  if (diag && diag_len > 0) diag[0] = '\0';
  if (uid == 0) {
    if (diag) snprintf(diag, diag_len, "refusing to kill processes for uid 0");
    errno = EPERM;
    return -1;
  }
  pid_t child = fork();
  if (child < 0) {
    if (diag) snprintf(diag, diag_len, "fork: %s", strerror(errno));
    return -1;
  }
  if (child == 0) {
    if (setuid(uid) < 0) _exit(127);
    while (kill(-1, SIGKILL) < 0) {
      if (errno == ESRCH) _exit(0);
      if (errno != EINTR) _exit(126);
    }
    _exit(0);
  }
  int status;
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) {
      if (diag) snprintf(diag, diag_len, "waitpid: %s", strerror(errno));
      return -1;
    }
  }
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
  if (diag) {
    if (WIFEXITED(status)) {
      int code = WEXITSTATUS(status);
      if (code == 127)
        snprintf(diag, diag_len, "setting uid %u: failed with exit code 127 (setuid)",
                 (unsigned)uid);
      else if (code == 126)
        snprintf(diag, diag_len, "cannot kill processes for uid %u: failed with exit code 126 (kill)",
                 (unsigned)uid);
      else
        snprintf(diag, diag_len, "failed with exit code %d", code);
    } else if (WIFSIGNALED(status)) {
      int sig = WTERMSIG(status);
      snprintf(diag, diag_len, "failed due to signal %d (%s)", sig, strsignal(sig));
    } else {
      snprintf(diag, diag_len, "died abnormally");
    }
  }
  errno = EIO;
  return -1;
}

/* Observe a child's exit without reaping it.  The graph-helper reaper marks
   its process as no longer signalable between this call and waitpid.  WNOWAIT
   keeps the zombie and its pid allocated during that transition, so the
   deadline thread cannot signal a pid that has already been reaped. */
int goonix_waitid_nowait(pid_t pid)
{
  siginfo_t info;
  while (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) < 0) {
    if (errno != EINTR) return -1;
  }
  return 0;
}

int goonix_spawn_sandbox(const char *program, const char *plan,
                        int log_fd, int *pid_out)
{
  int pid = fork();
  if (pid < 0) return -1;
  if (pid == 0) {
    /* Do not run Haskell between fork and exec.  Only this tiny C shim runs. */
    if (setpgid(0, 0) < 0) _exit(127);
    if (dup2(log_fd, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0)
      _exit(127);
    if (log_fd > STDERR_FILENO) close(log_fd);
    execl(program, program, plan, (char *)NULL);
    _exit(127);
  }
  *pid_out = pid;
  return 0;
}

int goonix_spawn_helper(const char *program, const char *argument,
                        int input_fd, int output_fd, int reply_fd,
                        const char *options, int *pid_out)
{
  posix_spawn_file_actions_t actions;
  int result = posix_spawn_file_actions_init(&actions);
  if (result != 0) { errno = result; return -1; }
  if ((result = posix_spawn_file_actions_adddup2(&actions, input_fd, STDIN_FILENO)) != 0 ||
      (result = posix_spawn_file_actions_adddup2(&actions, output_fd, STDOUT_FILENO)) != 0 ||
      (result = posix_spawn_file_actions_adddup2(&actions, output_fd, STDERR_FILENO)) != 0 ||
      (reply_fd >= 0 && (result = posix_spawn_file_actions_adddup2(&actions, reply_fd, 4)) != 0) ||
      (result = posix_spawn_file_actions_addclose(&actions, input_fd)) != 0 ||
      (result = posix_spawn_file_actions_addclose(&actions, output_fd)) != 0 ||
      (reply_fd >= 0 && (result = posix_spawn_file_actions_addclose(&actions, reply_fd)) != 0)) {
    posix_spawn_file_actions_destroy(&actions);
    errno = result;
    return -1;
  }
  char *const argv[] = {(char *)program, (char *)"substitute", (char *)argument, NULL};
  size_t count = 0;
  while (environ[count]) count++;
  char **child_environment = calloc(count + 2, sizeof(char *));
  if (!child_environment) { errno = ENOMEM; return -1; }
  size_t index = 0;
  for (size_t i = 0; i < count; i++) {
    if (strncmp(environ[i], "_NIX_OPTIONS=", 13) != 0) child_environment[index++] = environ[i];
  }
  size_t option_length = strlen(options);
  char *option = malloc(option_length + 14);
  if (!option) { free(child_environment); errno = ENOMEM; return -1; }
  memcpy(option, "_NIX_OPTIONS=", 13);
  memcpy(option + 13, options, option_length + 1);
  child_environment[index++] = option;
  child_environment[index] = NULL;
  pid_t pid;
  result = posix_spawn(&pid, program, &actions, NULL, argv, child_environment);
  free(option);
  free(child_environment);
  posix_spawn_file_actions_destroy(&actions);
  if (result != 0) { errno = result; return -1; }
  *pid_out = (int)pid;
  return 0;
}

int goonix_spawn_offload(const char *program, int input_fd, int output_fd,
                         int builder_fd, const char *system, const char *silent,
                         const char *trace, const char *timeout, int *pid_out)
{
  /* Do not run C library code between fork and exec in the threaded RTS.
     posix_spawn performs the descriptor setup and changes directory for us. */
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int result = posix_spawn_file_actions_init(&actions);
  if (result != 0) { errno = result; return -1; }
  if ((result = posix_spawn_file_actions_adddup2(&actions, input_fd, STDIN_FILENO)) != 0 ||
      (result = posix_spawn_file_actions_adddup2(&actions, output_fd, STDOUT_FILENO)) != 0 ||
      (result = posix_spawn_file_actions_adddup2(&actions, output_fd, STDERR_FILENO)) != 0 ||
      (result = posix_spawn_file_actions_adddup2(&actions, builder_fd, 4)) != 0 ||
      (result = posix_spawn_file_actions_addclose(&actions, input_fd)) != 0 ||
      (result = posix_spawn_file_actions_addclose(&actions, output_fd)) != 0 ||
      (result = posix_spawn_file_actions_addclose(&actions, builder_fd)) != 0 ||
      (result = posix_spawn_file_actions_addchdir_np(&actions, "/")) != 0) {
    posix_spawn_file_actions_destroy(&actions);
    errno = result;
    return -1;
  }
  result = posix_spawnattr_init(&attributes);
  if (result != 0) {
    posix_spawn_file_actions_destroy(&actions);
    errno = result;
    return -1;
  }
  if ((result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP)) != 0 ||
      (result = posix_spawnattr_setpgroup(&attributes, 0)) != 0) {
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    errno = result;
    return -1;
  }
  char *const argv[] = {(char *)program, (char *)"offload", (char *)system,
    (char *)silent, (char *)trace, (char *)timeout, NULL};
  pid_t pid;
  result = posix_spawn(&pid, program, &actions, &attributes, argv, environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  if (result != 0) { errno = result; return -1; }
  *pid_out = (int)pid;
  return 0;
}

int goonix_spawn_discover(const char *program, int *pid_out)
{
  /* --discover is a fire-and-forget helper started before serving clients. */
  posix_spawnattr_t attributes;
  int result = posix_spawnattr_init(&attributes);
  if (result != 0) { errno = result; return -1; }
  if ((result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP)) != 0 ||
      (result = posix_spawnattr_setpgroup(&attributes, 0)) != 0) {
    posix_spawnattr_destroy(&attributes);
    errno = result;
    return -1;
  }
  char *const argv[] = {(char *)program, (char *)"discover", NULL};
  pid_t pid;
  result = posix_spawn(&pid, program, NULL, &attributes, argv, environ);
  posix_spawnattr_destroy(&attributes);
  if (result != 0) { errno = result; return -1; }
  *pid_out = (int)pid;
  return 0;
}

/* goonix: launch the deep CA scan helper with no daemon privileges.  The child
   gets a new session, /dev/null on stdin, the output pipe on stdout+stderr, an
   empty environment, and (when the daemon is root) the build user's uid/gid.
   An unprivileged daemon cannot assume the build user's identity and must not
   pretend to have dropped privileges.  Returns the pid; the caller polls the
   output pipe and waits.  Mirrors nix/libstore/deep-scan.cc runDeepScanHelper. */
int goonix_spawn_deep_scan(const char *helper, const char *tree,
                           char *const tokens[], int token_count,
                           int output_fd, uid_t build_uid, gid_t build_gid,
                           int *pid_out)
{
  int nullfd = open("/dev/null", O_RDWR);
  if (nullfd < 0) return -1;
  pid_t pid = fork();
  if (pid < 0) { close(nullfd); return -1; }
  if (pid == 0) {
    /* Only this tiny C shim runs between fork and exec, never Haskell. */
    if (setsid() < 0) _exit(2);
    if (dup2(nullfd, STDIN_FILENO) < 0 ||
        dup2(output_fd, STDOUT_FILENO) < 0 ||
        dup2(output_fd, STDERR_FILENO) < 0)
      _exit(2);
    if (nullfd > STDERR_FILENO) close(nullfd);
    if (output_fd > STDERR_FILENO) close(output_fd);
    if (geteuid() == 0) {
      if (build_uid == (uid_t)-1 || build_gid == (gid_t)-1 || build_uid == 0)
        _exit(2);
      if (setgroups(0, NULL) != 0 || setgid(build_gid) != 0 || setuid(build_uid) != 0)
        _exit(2);
      if (geteuid() == 0) _exit(2);
    } else if (build_uid != (uid_t)-1 && build_uid != geteuid()) {
      _exit(2);
    }
    char **argv = calloc((size_t)token_count + 3, sizeof(char *));
    if (!argv) _exit(2);
    argv[0] = (char *)helper;
    argv[1] = (char *)tree;
    for (int i = 0; i < token_count; i++) argv[i + 2] = tokens[i];
    argv[token_count + 2] = NULL;
    char *empty_env[] = {NULL};
    execve(helper, argv, empty_env);
    _exit(errno == ENOENT ? 127 : 126);
  }
  close(nullfd);
  *pid_out = (int)pid;
  return 0;
}

/* goonix: spawn a builtin builder (guix perform-download) as the leased build
   user, outside the chroot.  C++ runs builtins outside the chroot but "under a
   separate build user, though" (build.cc:2555-2558): the child drops to the
   build user before execBuilderOrBuiltin.  A root daemon that ran the builtin
   as root would be refused by perform-download ("refusing to run with elevated
   privileges").  The drop order matches C++ setIDsAction (spawn.cc):
   setgroups, then setgid, then setuid, each verified.  Only this tiny C shim
   runs between fork and exec; no Haskell (threaded RTS).  When drop_ids is 0
   (no build user, unprivileged daemon) the child keeps the daemon's identity,
   as C++ does when build-users-group is empty. */
int goonix_spawn_builtin(const char *program, char *const argv[],
                         char *const envp[], const char *work_dir,
                         int log_fd, int drop_ids,
                         uid_t uid, gid_t gid, const gid_t *groups, int ngroups,
                         int *pid_out)
{
  pid_t pid = fork();
  if (pid < 0) return -1;
  if (pid == 0) {
    if (setpgid(0, 0) < 0) _exit(127);
    if (dup2(log_fd, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0)
      _exit(127);
    if (log_fd > STDERR_FILENO) close(log_fd);
    if (work_dir && chdir(work_dir) < 0) _exit(127);
    if (drop_ids) {
      if (setgroups((size_t)ngroups, groups) < 0) _exit(126);
      if (setgid(gid) < 0 || getgid() != gid || getegid() != gid) _exit(126);
      if (setuid(uid) < 0 || getuid() != uid || geteuid() != uid) _exit(126);
    }
    execve(program, argv, envp);
    _exit(127);
  }
  *pid_out = (int)pid;
  return 0;
}

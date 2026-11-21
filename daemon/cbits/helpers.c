/* goonix: descriptor wiring for exec-only helper processes. */
#define _GNU_SOURCE
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

#include <sys/types.h>

/* Equivalent to the C++ daemon's killUser: the short-lived child changes to
   the leased uid so kill(-1, SIGKILL) affects only that uid, including itself. */
int goonix_kill_user(uid_t uid)
{
  if (uid == 0) { errno = EPERM; return -1; }
  pid_t child = fork();
  if (child < 0) return -1;
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
    if (errno != EINTR) return -1;
  }
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
  errno = EIO;
  return -1;
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

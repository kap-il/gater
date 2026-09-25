#ifndef GATER_PTY_H
#define GATER_PTY_H

#include <stdint.h>
#include <sys/types.h>

// fork()/exec() can't be called safely from Swift (fork is marked
// unavailable, and the child of a multithreaded Swift process may only run
// async-signal-safe code). So the fork + exec lives here in C, and Swift
// hands over everything fully prepared: resolved executable path, argv,
// envp, and cwd.

/// Spawns `path` in a new pseudo-terminal of the given size.
///
/// - `argv` / `envp` are NULL-terminated arrays, as for execve().
/// - `cwd` may be NULL to inherit the parent's working directory.
///
/// On success returns 0 and stores the master fd and child pid.
/// On failure returns -1 with errno set.
int gater_pty_spawn(const char *path,
                    char *const argv[],
                    char *const envp[],
                    const char *cwd,
                    uint16_t cols, uint16_t rows,
                    uint16_t cell_width, uint16_t cell_height,
                    int *out_fd, pid_t *out_pid);

/// Updates the pty's window size (TIOCSWINSZ); the kernel delivers
/// SIGWINCH to the foreground process group. Returns 0 or -1 with errno.
int gater_pty_resize(int fd,
                     uint16_t cols, uint16_t rows,
                     uint16_t cell_width, uint16_t cell_height);

#endif

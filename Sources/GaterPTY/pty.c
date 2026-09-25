#include "GaterPTY.h"

#include <errno.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

static struct winsize make_winsize(uint16_t cols, uint16_t rows,
                                   uint16_t cell_width, uint16_t cell_height)
{
    struct winsize ws = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = (unsigned short)(cols * cell_width),
        .ws_ypixel = (unsigned short)(rows * cell_height),
    };
    return ws;
}

int gater_pty_spawn(const char *path,
                    char *const argv[],
                    char *const envp[],
                    const char *cwd,
                    uint16_t cols, uint16_t rows,
                    uint16_t cell_width, uint16_t cell_height,
                    int *out_fd, pid_t *out_pid)
{
    struct winsize ws = make_winsize(cols, rows, cell_width, cell_height);
    int fd = -1;

    // forkpty() = openpty + fork + login_tty: the child gets a new session
    // with the slave as its controlling terminal and stdin/stdout/stderr.
    pid_t pid = forkpty(&fd, NULL, NULL, &ws);
    if (pid < 0)
        return -1;

    if (pid == 0) {
        // Child: async-signal-safe calls only from here on.
        if (cwd && chdir(cwd) != 0)
            _exit(126);
        execve(path, argv, envp);
        _exit(127); // execve only returns on error
    }

    *out_fd = fd;
    *out_pid = pid;
    return 0;
}

int gater_pty_resize(int fd,
                     uint16_t cols, uint16_t rows,
                     uint16_t cell_width, uint16_t cell_height)
{
    struct winsize ws = make_winsize(cols, rows, cell_width, cell_height);
    return ioctl(fd, TIOCSWINSZ, &ws);
}

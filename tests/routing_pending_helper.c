// Test fixture only. Hold layout-off before any display operation so the test
// can kill its guardian deterministically. The production guardian's bounded
// child wait and the Python test's cleanup both kill a stopped helper; all
// recovery/read-only commands immediately exec the unmodified real helper.
#include <mach-o/dyld.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX], resolved[PATH_MAX], real_helper[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) || !realpath(executable, resolved)) return 125;
    int length = snprintf(real_helper, sizeof(real_helper), "%s.original", resolved);
    if (length < 0 || (size_t)length >= sizeof(real_helper)) return 125;
    if (argc > 1 && strcmp(argv[1], "layout-off") == 0) {
        fprintf(stderr, "{\"testPendingMutator\":true,\"pid\":%d,\"parentPID\":%d,\"processGroup\":%d}\n",
                getpid(), getppid(), getpgrp());
        fflush(stderr);
        if (raise(SIGSTOP) != 0) return 125;
    }
    argv[0] = real_helper;
    execv(real_helper, argv);
    perror("exec original display-helper");
    return 127;
}

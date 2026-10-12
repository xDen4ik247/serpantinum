/* Fake `quickshell` for the sleep-guard tests (a real binary, so /proc/PID/cmdline is exactly
 * "quickshell -p QML" like the real shell's).
 *   quickshell -p QML                      a "shell": sleeps until killed
 *   quickshell -p QML ipc call lock activate   creates the lock marker 0.5 s later
 *   quickshell -p QML ipc show             exits with the code in $SG_SANDBOX/ipc_show_rc (default 0)
 *   quickshell log -t N FILE               prints a fake log
 * Every call is appended to $SG_SANDBOX/calls.log. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    const char *sb = getenv("SG_SANDBOX"), *run = getenv("XDG_RUNTIME_DIR");
    char path[4096];
    snprintf(path, sizeof path, "%s/calls.log", sb);
    FILE *f = fopen(path, "a");
    if (f) { fprintf(f, "quickshell"); for (int i = 1; i < argc; i++) fprintf(f, " %s", argv[i]); fprintf(f, "\n"); fclose(f); }
    if (argc == 3 && !strcmp(argv[1], "-p")) { for (;;) pause(); }
    if (argc >= 2 && !strcmp(argv[1], "log")) { printf("fake shell log\n"); return 0; }
    if (argc >= 6 && !strcmp(argv[3], "ipc") && !strcmp(argv[4], "call") && !strcmp(argv[5], "lock")) {
        if (fork() == 0) {
            usleep(500000);
            snprintf(path, sizeof path, "%s/serpantinum/lock/locked", run);
            FILE *m = fopen(path, "w"); if (m) fclose(m);
            _exit(0);
        }
        return 0;
    }
    if (argc >= 5 && !strcmp(argv[3], "ipc") && !strcmp(argv[4], "show")) {
        snprintf(path, sizeof path, "%s/ipc_show_rc", sb);
        FILE *r = fopen(path, "r"); int rc = 0;
        if (r) { if (fscanf(r, "%d", &rc) != 1) rc = 0; fclose(r); }
        return rc;
    }
    return 0;
}

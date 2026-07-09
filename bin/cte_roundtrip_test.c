/* cte_roundtrip_test.c — in-process CTE POSIX-interceptor round-trip test.
 * Avoids shell redirection (which is incompatible with the adapter's virtual
 * fds). Does open/write/close then open/read/close on a "clio::" path and
 * verifies the bytes survive the trip through the CTE RAM tier.
 *
 *   argv[1] = path WITHOUT the clio:: marker (marker is added here)
 * Build:  cc cte_roundtrip_test.c -o cte_roundtrip_test
 * Run:    LD_PRELOAD=libclio_cte_posix.so ./cte_roundtrip_test /scratch/.../f.bin
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <execinfo.h>
#include <stdlib.h>

static void crash_handler(int sig) {
  void *bt[64];
  int n = backtrace(bt, 64);
  fprintf(stderr, "\n=== CRASH: signal %d ===\n", sig);
  fflush(stderr);
  backtrace_symbols_fd(bt, n, 2);
  _exit(128 + sig);
}
#define CKPT(msg) do { fprintf(stderr, "[ckpt] %s\n", msg); fflush(stderr); } while (0)

/* mode (argv[2]): "rw" (default, same-process write+read), "w" (write only),
 * "r" (read + verify only). w/r on two different nodes validates a cross-node
 * CTE round-trip. */
int main(int argc, char **argv) {
  const char *bare = (argc > 1) ? argv[1] : "/tmp/cte_rt_default.bin";
  const char *mode = (argc > 2) ? argv[2] : "rw";
  /* argv[3]: on write == payload to store; on read == expected content. Lets a
   * cross-node run write a run-unique payload on node A and verify it on node
   * B (argv[3] must match on both invocations). Defaults to a fixed string. */
  const char *msg = (argc > 3) ? argv[3] : "CTE-ROUNDTRIP-OK-0123456789";
  char path[4096];
  snprintf(path, sizeof(path), "clio::%s", bare);
  size_t n = strlen(msg);
  signal(SIGSEGV, crash_handler);
  signal(SIGABRT, crash_handler);
  signal(SIGBUS, crash_handler);
  int do_w = (mode[0] == 'w' || (mode[0] == 'r' && mode[1] == 'w'));
  int do_r = (mode[0] == 'r' || (mode[0] == 'r' && mode[1] == 'w') || mode[0] == '\0');
  if (strcmp(mode, "rw") == 0) { do_w = 1; do_r = 1; }
  if (strcmp(mode, "w") == 0)  { do_w = 1; do_r = 0; }
  if (strcmp(mode, "r") == 0)  { do_w = 0; do_r = 1; }

  if (do_w) {
    CKPT("before open(write)");
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    CKPT("after open(write)");
    if (fd < 0) { perror("open(write)"); return 2; }
    ssize_t w = write(fd, msg, n);
    CKPT("after write");
    printf("wrote fd=%d bytes=%zd (expected %zu) path=%s\n", fd, w, n, path);
    close(fd);
    CKPT("after close");
  }

  if (do_r) {
    char buf[256];
    memset(buf, 0, sizeof(buf));
    int fd2 = open(path, O_RDONLY);
    if (fd2 < 0) { perror("open(read)"); return 3; }
    ssize_t r = read(fd2, buf, sizeof(buf) - 1);
    printf("read  fd=%d bytes=%zd content=\"%s\"\n", fd2, r, buf);
    close(fd2);
    if (r == (ssize_t)n && memcmp(buf, msg, n) == 0) {
      printf("RESULT: PASS (round-trip through CTE matches)\n");
      return 0;
    }
    printf("RESULT: FAIL (got %zd bytes, expected %zu)\n", r, n);
    return 1;
  }
  printf("RESULT: write-only done\n");
  return 0;
}

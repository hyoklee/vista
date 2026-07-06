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

/* mode (argv[2]): "rw" (default, same-process write+read), "w" (write only),
 * "r" (read + verify only). w/r on two different nodes validates a cross-node
 * CTE round-trip. */
int main(int argc, char **argv) {
  const char *bare = (argc > 1) ? argv[1] : "/tmp/cte_rt_default.bin";
  const char *mode = (argc > 2) ? argv[2] : "rw";
  char path[4096];
  snprintf(path, sizeof(path), "clio::%s", bare);
  const char *msg = "CTE-ROUNDTRIP-OK-0123456789";
  size_t n = strlen(msg);
  int do_w = (mode[0] == 'w' || (mode[0] == 'r' && mode[1] == 'w'));
  int do_r = (mode[0] == 'r' || (mode[0] == 'r' && mode[1] == 'w') || mode[0] == '\0');
  if (strcmp(mode, "rw") == 0) { do_w = 1; do_r = 1; }
  if (strcmp(mode, "w") == 0)  { do_w = 1; do_r = 0; }
  if (strcmp(mode, "r") == 0)  { do_w = 0; do_r = 1; }

  if (do_w) {
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) { perror("open(write)"); return 2; }
    ssize_t w = write(fd, msg, n);
    printf("wrote fd=%d bytes=%zd (expected %zu) path=%s\n", fd, w, n, path);
    close(fd);
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

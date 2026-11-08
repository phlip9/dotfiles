// Workload for nixos/tests/o11y-profiling-ebpf.nix: three threads, each
// parked in one named, non-inlined, global fn, so the profiler can
// symbolize them from `.symtab` (no DWARF needed):
//
// - `hot_loop_spin`: pure user-space CPU burn (on-CPU, user frames only)
// - `hot_syscall_spin`: reads /dev/zero in a loop (on-CPU, kernel frames)
// - `cold_block_wait`: sleeps 10ms in a loop (off-CPU)
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

// Keep the compiler from folding the loop away.
volatile uint64_t spin_counter;

// Burn CPU in user space forever.
__attribute__((noinline)) void hot_loop_spin(void) {
  for (;;) {
    for (uint64_t idx = 0; idx < 1000000; idx++) {
      spin_counter += idx;
    }
  }
}

// Burn CPU in the kernel forever: `read_zero` clears the user buffer.
__attribute__((noinline)) void hot_syscall_spin(void) {
  static char buf[1 << 16];
  int fd = open("/dev/zero", O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    perror("open /dev/zero");
    exit(1);
  }
  for (;;) {
    if (read(fd, buf, sizeof(buf)) < 0) {
      perror("read /dev/zero");
      exit(1);
    }
  }
}

// Block forever, waking every 10ms: shows up in off-CPU profiles.
__attribute__((noinline)) void cold_block_wait(void) {
  const struct timespec delay = {.tv_sec = 0, .tv_nsec = 10 * 1000 * 1000};
  for (;;) {
    nanosleep(&delay, NULL);
  }
}

// pthread entry trampoline: call the named fn.
static void *thread_main(void *arg) {
  void (*body)(void) = (void (*)(void))arg;
  body();
  return NULL;
}

int main(void) {
  void (*bodies[])(void) = {hot_loop_spin, hot_syscall_spin, cold_block_wait};
  pthread_t threads[3];
  for (int idx = 0; idx < 3; idx++) {
    if (pthread_create(&threads[idx], NULL, thread_main, (void *)bodies[idx])) {
      perror("pthread_create");
      return 1;
    }
  }
  for (int idx = 0; idx < 3; idx++) {
    pthread_join(threads[idx], NULL);
  }
  return 0;
}

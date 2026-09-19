#include "lwip/sys.h"
#include <time.h>

/* The one function NO_SYS=1 still requires: milliseconds since some
 * arbitrary fixed point (used for TCP timers/RTT — not wall-clock). */
u32_t sys_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (u32_t)((uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL);
}

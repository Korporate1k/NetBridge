#ifndef LWIP_ARCH_CC_H
#define LWIP_ARCH_CC_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <machine/endian.h>

#define LWIP_NO_INTTYPES_H 0
#define LWIP_NO_STDINT_H 0

/* No RTOS, no hardware — this is a Darwin host (macOS test harness / iOS
 * Network Extension). Everything runs serialized on one queue (see
 * TunnelEngine's private DispatchQueue), so no real locking is needed here;
 * SYS_LIGHTWEIGHT_PROT is 0 in lwipopts.h, which compiles the protect
 * macros to no-ops without needing this header to define anything for them. */

#define LWIP_PLATFORM_DIAG(x) do { printf x; } while (0)
#define LWIP_PLATFORM_ASSERT(x) do { \
    printf("lwIP assertion \"%s\" failed at %s:%d\n", (x), __FILE__, __LINE__); \
    abort(); \
} while (0)

#define LWIP_RAND() ((u32_t)rand())

#endif /* LWIP_ARCH_CC_H */

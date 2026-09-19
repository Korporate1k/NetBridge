#ifndef LWIP_ARCH_SYS_ARCH_H
#define LWIP_ARCH_SYS_ARCH_H

/* NO_SYS=1 and SYS_LIGHTWEIGHT_PROT=0 (see lwipopts.h): no threads,
 * semaphores, mailboxes, or protection macros are compiled in, so there is
 * nothing this port needs to declare here. Everything is driven serially by
 * TunnelEngine's own private DispatchQueue instead of a real OS port. */

#endif /* LWIP_ARCH_SYS_ARCH_H */

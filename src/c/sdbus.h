/* sd-bus, translated for the portal service, theme and notifications.
 * In optimized builds glibc auto-enables _FORTIFY_SOURCE, whose fortified
 * open()/openat() inline wrappers use __attribute__((error)) traps that
 * translate-c can't render. sd-bus.h pulls in fcntl.h transitively; turn it off. */
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <systemd/sd-bus.h>

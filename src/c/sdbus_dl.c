/* sdbus_dl: the sd-bus functions ZFD uses, taken from libsystemd at run time
 * (dlopen) instead of linked, so systemd-libs is an optional dependency. Without it
 * a bus can't be opened (-ENOSYS), which every caller already takes as "no bus":
 * no portal service, no notifications, the theme from the settings alone.
 *
 * Each function looks its real one up on first use. The variadic ones go through
 * the va_list versions sd-bus has for this (readv, appendv, call_methodv). */
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <systemd/sd-bus.h>

static void *lib(void) {
    static void *h = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        h = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL);
    }
    return h;
}

static void *sym(const char *name) {
    void *h = lib();
    return h ? dlsym(h, name) : NULL;
}

/* zfd_sdbus_available: libsystemd is there (it's an optional dependency). */
_Bool zfd_sdbus_available(void) {
    return lib() != NULL;
}

/* FN: look up `name` once into a static pointer `p` of type `type`. */
#define FN(type, name) \
    static __typeof__(type) p = NULL; \
    static int looked = 0; \
    if (!looked) { looked = 1; p = (__typeof__(type))sym(name); }

int sd_bus_open_user(sd_bus **ret) {
    FN(int (*)(sd_bus **), "sd_bus_open_user");
    if (!p) { if (ret) *ret = NULL; return -ENOSYS; }
    return p(ret);
}

sd_bus *sd_bus_flush_close_unref(sd_bus *bus) {
    FN(sd_bus *(*)(sd_bus *), "sd_bus_flush_close_unref");
    return p ? p(bus) : NULL;
}

int sd_bus_add_object(sd_bus *bus, sd_bus_slot **ret_slot, const char *path, sd_bus_message_handler_t callback, void *userdata) {
    FN(int (*)(sd_bus *, sd_bus_slot **, const char *, sd_bus_message_handler_t, void *), "sd_bus_add_object");
    return p ? p(bus, ret_slot, path, callback, userdata) : -ENOSYS;
}

int sd_bus_call_method(sd_bus *bus, const char *destination, const char *path, const char *interface, const char *member,
                       sd_bus_error *reterr_error, sd_bus_message **ret_reply, const char *types, ...) {
    FN(int (*)(sd_bus *, const char *, const char *, const char *, const char *, sd_bus_error *, sd_bus_message **, const char *, va_list),
       "sd_bus_call_methodv");
    if (!p) return -ENOSYS;
    va_list ap;
    va_start(ap, types);
    int r = p(bus, destination, path, interface, member, reterr_error, ret_reply, types, ap);
    va_end(ap);
    return r;
}

void sd_bus_error_free(sd_bus_error *e) {
    FN(void (*)(sd_bus_error *), "sd_bus_error_free");
    if (p) p(e);
}

int sd_bus_match_signal(sd_bus *bus, sd_bus_slot **ret, const char *sender, const char *path, const char *interface,
                        const char *member, sd_bus_message_handler_t callback, void *userdata) {
    FN(int (*)(sd_bus *, sd_bus_slot **, const char *, const char *, const char *, const char *, sd_bus_message_handler_t, void *),
       "sd_bus_match_signal");
    return p ? p(bus, ret, sender, path, interface, member, callback, userdata) : -ENOSYS;
}

int sd_bus_message_append(sd_bus_message *m, const char *types, ...) {
    FN(int (*)(sd_bus_message *, const char *, va_list), "sd_bus_message_appendv");
    if (!p) return -ENOSYS;
    va_list ap;
    va_start(ap, types);
    int r = p(m, types, ap);
    va_end(ap);
    return r;
}

int sd_bus_message_read(sd_bus_message *m, const char *types, ...) {
    FN(int (*)(sd_bus_message *, const char *, va_list), "sd_bus_message_readv");
    if (!p) return -ENOSYS;
    va_list ap;
    va_start(ap, types);
    int r = p(m, types, ap);
    va_end(ap);
    return r;
}

int sd_bus_message_close_container(sd_bus_message *m) {
    FN(int (*)(sd_bus_message *), "sd_bus_message_close_container");
    return p ? p(m) : -ENOSYS;
}

int sd_bus_message_enter_container(sd_bus_message *m, char type, const char *contents) {
    FN(int (*)(sd_bus_message *, char, const char *), "sd_bus_message_enter_container");
    return p ? p(m, type, contents) : -ENOSYS;
}

int sd_bus_message_exit_container(sd_bus_message *m) {
    FN(int (*)(sd_bus_message *), "sd_bus_message_exit_container");
    return p ? p(m) : -ENOSYS;
}

sd_bus *sd_bus_message_get_bus(sd_bus_message *m) {
    FN(sd_bus *(*)(sd_bus_message *), "sd_bus_message_get_bus");
    return p ? p(m) : NULL;
}

const char *sd_bus_message_get_member(sd_bus_message *m) {
    FN(const char *(*)(sd_bus_message *), "sd_bus_message_get_member");
    return p ? p(m) : NULL;
}

int sd_bus_message_new_method_return(sd_bus_message *call, sd_bus_message **ret) {
    FN(int (*)(sd_bus_message *, sd_bus_message **), "sd_bus_message_new_method_return");
    return p ? p(call, ret) : -ENOSYS;
}

int sd_bus_message_open_container(sd_bus_message *m, char type, const char *contents) {
    FN(int (*)(sd_bus_message *, char, const char *), "sd_bus_message_open_container");
    return p ? p(m, type, contents) : -ENOSYS;
}

int sd_bus_message_read_array(sd_bus_message *m, char type, const void **ret_ptr, size_t *ret_size) {
    FN(int (*)(sd_bus_message *, char, const void **, size_t *), "sd_bus_message_read_array");
    return p ? p(m, type, ret_ptr, ret_size) : -ENOSYS;
}

sd_bus_message *sd_bus_message_ref(sd_bus_message *m) {
    FN(sd_bus_message *(*)(sd_bus_message *), "sd_bus_message_ref");
    return p ? p(m) : m;
}

int sd_bus_message_skip(sd_bus_message *m, const char *types) {
    FN(int (*)(sd_bus_message *, const char *), "sd_bus_message_skip");
    return p ? p(m, types) : -ENOSYS;
}

sd_bus_message *sd_bus_message_unref(sd_bus_message *m) {
    FN(sd_bus_message *(*)(sd_bus_message *), "sd_bus_message_unref");
    return p ? p(m) : NULL;
}

int sd_bus_process(sd_bus *bus, sd_bus_message **ret) {
    FN(int (*)(sd_bus *, sd_bus_message **), "sd_bus_process");
    return p ? p(bus, ret) : -ENOSYS;
}

int sd_bus_release_name(sd_bus *bus, const char *name) {
    FN(int (*)(sd_bus *, const char *), "sd_bus_release_name");
    return p ? p(bus, name) : -ENOSYS;
}

int sd_bus_request_name(sd_bus *bus, const char *name, uint64_t flags) {
    FN(int (*)(sd_bus *, const char *, uint64_t), "sd_bus_request_name");
    return p ? p(bus, name, flags) : -ENOSYS;
}

int sd_bus_send(sd_bus *bus, sd_bus_message *m, uint64_t *ret_cookie) {
    FN(int (*)(sd_bus *, sd_bus_message *, uint64_t *), "sd_bus_send");
    return p ? p(bus, m, ret_cookie) : -ENOSYS;
}

sd_bus_slot *sd_bus_slot_unref(sd_bus_slot *s) {
    FN(sd_bus_slot *(*)(sd_bus_slot *), "sd_bus_slot_unref");
    return p ? p(s) : NULL;
}

int sd_bus_wait(sd_bus *bus, uint64_t timeout_usec) {
    FN(int (*)(sd_bus *, uint64_t), "sd_bus_wait");
    return p ? p(bus, timeout_usec) : -ENOSYS;
}

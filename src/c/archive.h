/* libarchive, translated for browsing archives in place (core/arcfs.zig): reading
 * their index and single entries, and extracting chosen ones. The fortified glibc
 * wrappers can't be rendered by translate-c (see sdbus.h). */
#undef _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#include <archive.h>
#include <archive_entry.h>

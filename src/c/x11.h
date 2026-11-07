/* Xlib plus GLFW's native X11 access, translated for src/ui/x11.zig only. */
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/cursorfont.h>
#include <X11/keysym.h>
#include <X11/extensions/sync.h> /* _NET_WM_SYNC_REQUEST: smooth interactive resizing */
#include <GLFW/glfw3.h>
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>

/* The Dear ImGui / GLFW / OpenGL C surface, translated for src/ui/cimgui.zig.
 * Make cimgui emit C struct/enum definitions (it assumes C++ otherwise), and
 * restrict cimgui_impl to the GLFW + OpenGL3 backends. */
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#define CIMGUI_USE_GLFW
#define CIMGUI_USE_OPENGL3
#include <GLFW/glfw3.h> /* must precede cimgui_impl.h (real GLFWwindow type) */
#include "cimgui.h"
#include "cimgui_impl.h"

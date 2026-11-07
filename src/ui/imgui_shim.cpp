// Tiny C shim for the handful of ImGuiIO fields we need but can't reach from Zig:
// translate-c rejects the ImGuiIO struct (it embeds ImGuiContext* as [*c], illegal
// for the opaque type). Expose just what we need as plain C functions.
#include "imgui.h"
#include "imgui_internal.h"
#include <GL/gl.h>
#include <GLFW/glfw3.h>
#include <cstdio>
#include <cstdint>
#include <cstring>

extern "C" void zfd_set_font_scale(float s) {
    ImGui::GetIO().FontGlobalScale = s;
}

// zfd_want_text_input reports whether a text field has the keyboard (any window), so
// the file list leaves typed keys and shortcuts alone.
extern "C" bool zfd_want_text_input(void) {
    return ImGui::GetIO().WantTextInput;
}

// zfd_mouse_wheel returns this frame's vertical wheel delta (ImGuiIO field, opaque to
// Zig). For Ctrl+scroll zoom: layout-independent, unlike +/- physical keys.
extern "C" float zfd_mouse_wheel(void) {
    return ImGui::GetIO().MouseWheel;
}

// zfd_free_ctrl_tab releases Ctrl+Tab / Ctrl+Shift+Tab from ImGui's window switcher
// (we have one window) so the app can use them to cycle tabs, like every tabbed app.
extern "C" void zfd_free_ctrl_tab(void) {
    ImGuiContext* g = ImGui::GetCurrentContext(); // these live on the context in 1.92
    g->ConfigNavWindowingKeyNext = 0;
    g->ConfigNavWindowingKeyPrev = 0;
}

// zfd_set_font_filter sets NEAREST (blocky, no smoothing) or LINEAR filtering on the
// font atlas texture, for the "Blocky font (no anti-aliasing)" toggle. In ImGui 1.92 the
// backend manages the texture dynamically and re-creates it as LINEAR, so this must be
// re-asserted every frame AFTER RenderDrawData. Restores the prior GL binding.
extern "C" void zfd_set_font_filter(bool nearest) {
    ImTextureID id = ImGui::GetIO().Fonts->TexRef.GetTexID();
    if (id == ImTextureID_Invalid)
        return;
    GLint prev = 0;
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
    glBindTexture(GL_TEXTURE_2D, (GLuint)id);
    GLint f = nearest ? GL_NEAREST : GL_LINEAR;
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, f);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f);
    glBindTexture(GL_TEXTURE_2D, (GLuint)prev);
}

// We keep BOTH a smooth TTF and ImGui's built-in bitmap font (ProggyClean, 1-bit /
// natively blocky) loaded, and switch io.FontDefault between them for the "Blocky
// font (no anti-aliasing)" toggle. NEAREST filtering alone is invisible on an
// anti-aliased TTF at 1x, so the toggle has to change the actual font.
static ImFont *g_ttf = nullptr;
static ImFont *g_bitmap = nullptr;
static char g_ttf_path[1024] = {0}; // the loaded TTF, reused as the bitmap font's fallback

// zfd_load_font adds a TTF/OTF as the smooth font. NOTE: AddFontFromFileTTF
// *asserts/aborts* if the file can't be read (it does NOT return null), so we fopen-
// check first and only load existing files (a missing candidate returns false to try
// the next, instead of crashing).
//
// Glyph ranges: without an explicit range ImGui bakes only Basic Latin + Latin-1
// (0x20-0xFF), so accented/extended characters typed into e.g. the Save filename field
// render as nothing ("UTF-8 not supported"). Bake a broad range covering Latin
// Extended-A/B/Additional (European + Vietnamese), Greek, Cyrillic, and the common
// punctuation block (curly quotes, dashes, ellipsis). The array is static so it stays
// valid until ImGui builds the atlas lazily at the first frame. (CJK/other scripts need
// a dedicated fallback font merged in (a later refinement); most sans-serif system fonts
// don't carry those glyphs anyway.)
extern "C" bool zfd_load_font(const char *path, float size) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    std::fclose(f);
    static const ImWchar kRanges[] = {
        0x0020, 0x00FF, // Basic Latin + Latin-1 Supplement
        0x0100, 0x017F, // Latin Extended-A
        0x0180, 0x024F, // Latin Extended-B
        0x0370, 0x03FF, // Greek and Coptic
        0x0400, 0x04FF, // Cyrillic
        0x1E00, 0x1EFF, // Latin Extended Additional (incl. Vietnamese)
        0x2000, 0x206F, // General Punctuation (curly quotes, en/em dash, ellipsis)
        0x20A0, 0x20BF, // Currency symbols (€, etc.)
        0,
    };
    g_ttf = ImGui::GetIO().Fonts->AddFontFromFileTTF(path, size, nullptr, kRanges);
    if (g_ttf) std::snprintf(g_ttf_path, sizeof g_ttf_path, "%s", path);
    return g_ttf != nullptr;
}

// zfd_add_default_font adds the built-in bitmap font (the "blocky" one) and makes the
// TTF the initial default (falling back to bitmap if no TTF loaded).
extern "C" void zfd_add_default_font(void) {
    g_bitmap = ImGui::GetIO().Fonts->AddFontDefault();
    // The bitmap font only has Latin-1: anything past U+00FF (the "›" breadcrumb
    // separator, "…", curly quotes, and every non-Latin-1 filename) drew as "?".
    // Merge the TTF into it as a fallback source, so the blocky font keeps its look
    // for ASCII and borrows the TTF's glyph only where it has none of its own.
    if (g_bitmap && g_ttf_path[0]) {
        ImFontConfig cfg;
        cfg.MergeMode = true;
        // Whole-pixel advances: a borrowed glyph ("…") with a fractional width put
        // every letter after it between pixels, smeared grey under NEAREST filtering.
        cfg.PixelSnapH = true;
        ImGui::GetIO().Fonts->AddFontFromFileTTF(g_ttf_path, 0.0f, &cfg); // 0 = inherit the size, as the bitmap font does
    }
    if (!g_ttf)
        g_ttf = g_bitmap;
    ImGui::GetIO().FontDefault = g_ttf;
}

// zfd_set_blocky selects the bitmap (blocky) or TTF (smooth) font as the default.
// Read at NewFrame, so call before beginFrame.
extern "C" void zfd_set_blocky(bool blocky) {
    ImGui::GetIO().FontDefault = (blocky && g_bitmap) ? g_bitmap : g_ttf;
}

// zfd_input_chars copies this frame's typed ASCII characters (for type-ahead find).
// Returns the count written. When a text widget is focused it consumes these, so the
// caller only reads them when the file list has focus.
extern "C" int zfd_input_chars(char *out, int max) {
    ImGuiIO &io = ImGui::GetIO();
    int n = 0;
    for (int i = 0; i < io.InputQueueCharacters.Size && n < max; i++) {
        ImWchar ch = io.InputQueueCharacters[i];
        if (ch >= 32 && ch < 127) out[n++] = (char)ch;
    }
    return n;
}

// zfd_enable_viewports lets ImGui windows (progress, Properties, dialogs) leave the
// main window as real OS windows (the GLFW backend's multi-viewport support). They get
// no taskbar entry of their own: they belong to the main window.
extern "C" void zfd_enable_viewports(void) {
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_ViewportsEnable;
    io.ConfigViewportsNoTaskBarIcon = true;
}

// zfd_viewports_enabled reports whether multi-viewport mode is on (and the backend
// supports it), i.e. whether ImGui coordinates are desktop rather than window ones.
extern "C" bool zfd_viewports_enabled(void) {
    ImGuiIO &io = ImGui::GetIO();
    return (io.ConfigFlags & ImGuiConfigFlags_ViewportsEnable) &&
           (io.BackendFlags & ImGuiBackendFlags_PlatformHasViewports);
}

// zfd_hook_viewport_windows: every ImGui window that leaves the main one becomes an
// OS window made by the GLFW backend. We wrap the backend's Platform_CreateWindow so
// `cb` sees each new GLFW window before it's shown (Platform_ShowWindow runs later),
// in time to mark it as belonging to the main window: no taskbar entry of its own,
// minimized and raised together with it. `flags` are the viewport's ImGuiViewportFlags
// (whether it may take focus, whether it's a tooltip).
typedef void (*zfd_viewport_cb)(void *glfw_window, int flags);
static zfd_viewport_cb g_vp_cb = nullptr;
static void (*g_vp_orig_create)(ImGuiViewport *) = nullptr;
// Their framebuffers are transparent, and cleared to transparent, so what ZFD draws
// rounded in them (Quick Look's corners, a menu's) is rounded on screen too: ImGui
// itself draws a window that has an OS window to itself square, over opaque black.
static void zfd_vp_create(ImGuiViewport *vp) {
    glfwWindowHint(GLFW_TRANSPARENT_FRAMEBUFFER, GLFW_TRUE);
    g_vp_orig_create(vp);
    glfwWindowHint(GLFW_TRANSPARENT_FRAMEBUFFER, GLFW_FALSE);
    if (g_vp_cb && vp->PlatformHandle) g_vp_cb(vp->PlatformHandle, (int)vp->Flags);
}
static void (*g_vp_orig_render)(ImGuiViewport *, void *) = nullptr;
static void zfd_vp_render(ImGuiViewport *vp, void *arg) {
    vp->Flags |= ImGuiViewportFlags_NoRendererClear; // (the backend's clear is opaque black)
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    g_vp_orig_render(vp, arg);
}
extern "C" void zfd_hook_viewport_windows(zfd_viewport_cb cb) {
    ImGuiPlatformIO &pio = ImGui::GetPlatformIO();
    if (!pio.Platform_CreateWindow) return;
    g_vp_orig_create = pio.Platform_CreateWindow;
    pio.Platform_CreateWindow = zfd_vp_create;
    if (pio.Renderer_RenderWindow) {
        g_vp_orig_render = pio.Renderer_RenderWindow;
        pio.Renderer_RenderWindow = zfd_vp_render;
    }
    g_vp_cb = cb;
}

// zfd_frame_hash sums up what the frame just rendered (igRender) would put on screen:
// every viewport's draw lists (vertices, indices, commands), position, size and scale.
// The loop skips drawing a frame whose hash matches the one on screen. Returns 0
// when it must be drawn regardless: a texture (the font atlas) waits to be uploaded.
static inline uint64_t zfd_mix(uint64_t h, uint64_t v) {
    h ^= v;
    h *= 0x9E3779B97F4A7C15ULL;
    return h ^ (h >> 29);
}
static uint64_t zfd_hash_bytes(uint64_t h, const void *p, size_t n) {
    const unsigned char *b = (const unsigned char *)p;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        uint64_t w;
        memcpy(&w, b + i, 8);
        h = zfd_mix(h, w);
    }
    uint64_t t = 0;
    for (size_t k = 0; i < n; i++, k++) t |= (uint64_t)b[i] << (8 * k);
    return zfd_mix(h, t ^ n);
}
extern "C" uint64_t zfd_frame_hash(int fb_w, int fb_h) {
    uint64_t h = zfd_mix(0x7a6664ULL, ((uint64_t)(uint32_t)fb_w << 32) | (uint32_t)fb_h);
    ImGuiPlatformIO &pio = ImGui::GetPlatformIO();
    for (ImTextureData *tex : pio.Textures)
        if (tex->Status != ImTextureStatus_OK) return 0;
    for (ImGuiViewport *vp : pio.Viewports) {
        ImDrawData *dd = vp->DrawData;
        if (!dd) continue;
        h = zfd_mix(h, vp->ID);
        float geo[6] = {dd->DisplayPos.x, dd->DisplayPos.y, dd->DisplaySize.x, dd->DisplaySize.y, dd->FramebufferScale.x, dd->FramebufferScale.y};
        h = zfd_hash_bytes(h, geo, sizeof geo);
        for (ImDrawList *dl : dd->CmdLists) {
            h = zfd_hash_bytes(h, dl->VtxBuffer.Data, (size_t)dl->VtxBuffer.Size * sizeof(ImDrawVert));
            h = zfd_hash_bytes(h, dl->IdxBuffer.Data, (size_t)dl->IdxBuffer.Size * sizeof(ImDrawIdx));
            h = zfd_hash_bytes(h, dl->CmdBuffer.Data, (size_t)dl->CmdBuffer.Size * sizeof(ImDrawCmd));
        }
    }
    return h ? h : 1;
}

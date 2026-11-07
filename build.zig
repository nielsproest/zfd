const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The pure core: no C, no GLFW/X11/ImGui. Its own module, so `zig build
    // test-core` compiles and tests the logic with zero GUI dependencies — the
    // strict layering (GoFileDialog goal 2) enforced by the build graph itself.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
    });

    // Dear ImGui compiled via cimgui with the GLFW + OpenGL3 backends. Both are
    // packages in build.zig.zon, pinned by commit (docking branch).
    const imgui_tree = imguiTree(b);
    const cimgui = buildCimgui(b, target, optimize, imgui_tree);

    // The C headers the GUI talks to, each translated into a Zig module by the
    // translate-c package (@cImport is gone as of Zig 0.17). One header per C
    // surface, kept in src/c/.
    const translate_c = b.dependency("translate_c", .{});
    const c_imgui: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c/imgui.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "glfw3" }},
    });
    c_imgui.addIncludePath(imgui_tree);
    const c_sdbus: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c/sdbus.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "libsystemd" }},
    });
    const c_x11: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c/x11.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{ .{ .name = "X11" }, .{ .name = "Xext" }, .{ .name = "glfw3" } },
    });

    // The executable. Links the C++ ImGui lib and the GUI system libraries; the
    // portal backend links in as that layer lands.
    const exe = b.addExecutable(.{
        .name = "zfd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true, // final link pulls in the C++ runtime for ImGui
            .imports = &.{
                .{ .name = "core", .module = core },
                .{ .name = "c_imgui", .module = c_imgui.mod },
                .{ .name = "c_sdbus", .module = c_sdbus.mod },
                .{ .name = "c_x11", .module = c_x11.mod },
            },
        }),
    });
    exe.root_module.linkLibrary(cimgui);
    // Quick Look image decoding: stb_image (vendored single header) behind a small C API.
    exe.root_module.addIncludePath(b.path("vendor/stb"));
    exe.root_module.addCSourceFiles(.{ .files = &.{"src/ui/preview_img.c"}, .flags = &.{}, .language = .c });
    exe.root_module.linkSystemLibrary("glfw3", .{}); // pkg-config: -lglfw
    exe.root_module.linkSystemLibrary("GL", .{}); // -lGL (glClear etc.)
    exe.root_module.linkSystemLibrary("X11", .{}); // Xlib: CSD move/resize + XDND
    exe.root_module.linkSystemLibrary("Xext", .{}); // XSync: resize in step with the WM
    exe.root_module.linkSystemLibrary("libsystemd", .{}); // sd-bus: the --service portal backend
    b.installArtifact(exe);

    // `zig build run [-- args]`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run ZFD");
    run_step.dependOn(&run_cmd.step);

    // Tests. `zig build test` runs the core suite plus the exe's own tests;
    // `zig build test-core` runs just the pure core (no GUI toolchain needed).
    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const test_core_step = b.step("test-core", "Run only the pure-core tests");
    test_core_step.dependOn(&run_core_tests.step);
}

/// imguiTree lays the two packages out the way cimgui expects: cimgui's sources
/// include Dear ImGui as "./imgui/imgui.h", so ImGui goes in an imgui/ folder
/// inside cimgui (in cimgui's own repo it's a git submodule there, and Zig doesn't
/// fetch submodules). Only sources and headers are copied.
fn imguiTree(b: *std.Build) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    const src: std.Build.Step.WriteFile.CopyDirectoryOptions = .{ .include_extensions = &.{ ".h", ".cpp" } };
    _ = wf.addCopyDirectory(b.dependency("cimgui", .{}).path(""), "", src);
    _ = wf.addCopyDirectory(b.dependency("imgui", .{}).path(""), "imgui", src);
    return wf.getDirectory();
}

/// buildCimgui compiles Dear ImGui + the cimgui C API and the GLFW +
/// OpenGL3 backends into a static library. No system imgui package exists on Arch,
/// so we own the build. `IMGUI_IMPL_API=extern "C"` gives the backend entry points
/// C linkage (so Zig can call them); `CIMGUI_USE_{GLFW,OPENGL3}` gate cimgui_impl to
/// just those two backends (no SDL/Vulkan headers pulled in). Freetype stays off.
fn buildCimgui(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, tree: std.Build.LazyPath) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "cimgui",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    lib.root_module.addIncludePath(tree);
    lib.root_module.addIncludePath(tree.path(b, "imgui"));
    lib.root_module.addIncludePath(tree.path(b, "imgui/backends"));
    lib.root_module.addCSourceFiles(.{
        .root = tree,
        .files = &.{
            "cimgui.cpp",
            "cimgui_impl.cpp",
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/backends/imgui_impl_glfw.cpp",
            "imgui/backends/imgui_impl_opengl3.cpp",
        },
        .flags = &.{
            "-DIMGUI_IMPL_API=extern \"C\"",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_OPENGL3",
        },
        .language = .cpp,
    });
    // Our own tiny shim for ImGuiIO fields Zig can't reach (see the .cpp).
    lib.root_module.addCSourceFiles(.{
        .files = &.{"src/ui/imgui_shim.cpp"},
        .flags = &.{},
        .language = .cpp,
    });
    // No linkSystemLibrary here: this is a static archive, so glfw/GL references
    // stay unresolved and are satisfied at the final exe link (where we link them).
    // Linking a .so into a .a just embeds a bogus archive member (LLD warns).
    return lib;
}

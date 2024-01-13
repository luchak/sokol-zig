const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const OptimizeMode = std.builtin.OptimizeMode;

pub fn build(b: *Build) !void {
    const opt_force_gl = b.option(bool, "gl", "Force OpenGL backend (default: false)") orelse false;
    const opt_enable_wayland = b.option(bool, "wayland", "Compile with wayland-support (default: false)") orelse false;
    const opt_enable_x11 = b.option(bool, "x11", "Compile with x11-support (default: true)") orelse true;
    const opt_force_egl = b.option(bool, "egl", "Use EGL instead of GLX if possible (default: false)") orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const emsdk = b.dependency("emsdk", .{});

    // a module for the actual bindings, and a static link library with the C code
    const mod_sokol = b.addModule("sokol", .{ .root_source_file = .{ .path = "src/sokol/sokol.zig" } });
    const lib_sokol = try buildLibSokol(b, .{
        .target = target,
        .optimize = optimize,
        .emsdk = emsdk,
        .backend = if (opt_force_gl) .gl else .auto,
        .enable_wayland = opt_enable_wayland,
        .enable_x11 = opt_enable_x11,
        .force_egl = opt_force_egl,
    });
    mod_sokol.linkLibrary(lib_sokol);

    // the integrated examples
    const examples = .{
        "clear",
        "triangle",
        "quad",
        "bufferoffsets",
        "cube",
        "noninterleaved",
        "texcube",
        "blend",
        "offscreen",
        "instancing",
        "mrt",
        "saudio",
        "sgl",
        "sgl-context",
        "sgl-points",
        "debugtext",
        "debugtext-print",
        "debugtext-userfont",
        "shapes",
    };
    inline for (examples) |example| {
        try buildExample(b, example, .{
            .target = target,
            .optimize = optimize,
            .mod_sokol = mod_sokol,
            .lib_sokol = lib_sokol,
            .emsdk = emsdk,
        });
    }

    // a manually invoked build step to recompile shaders via sokol-shdc
    buildShaders(b);
}

const SokolBackend = enum {
    auto, // Windows: D3D11, macOS/iOS: Metal, otherwise: GL
    d3d11,
    metal,
    gl,
    gles3,
    wgpu,
};

const LibSokolOptions = struct {
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    backend: SokolBackend = .auto,
    force_egl: bool = false,
    enable_x11: bool = true,
    enable_wayland: bool = false,
    emsdk: ?*Build.Dependency = null,
};

// build the sokol C headers into a static library
fn buildLibSokol(b: *Build, options: LibSokolOptions) !*Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "sokol",
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
    if (options.target.result.isWasm()) {
        // make sure we're building for the wasm32-emscripten target, not wasm32-freestanding
        if (lib.rootModuleTarget().os.tag != .emscripten) {
            std.log.err("Please build with 'zig build -Dtarget=wasm32-emscripten", .{});
            return error.Wasm32EmscriptenExpected;
        }
        // one-time setup of Emscripten SDK
        if (try emsdkSetupStep(b, options.emsdk.?)) |emsdk_setup| {
            lib.step.dependOn(&emsdk_setup.step);
        }
        // need to manualle add the Emscripten SDK system include path
        const emsdk_sysroot = b.pathJoin(&.{ emsdkPath(b, options.emsdk.?), "upstream", "emscripten", "cache", "sysroot" });
        const include_path = b.pathJoin(&.{ emsdk_sysroot, "include" });
        lib.addSystemIncludePath(.{ .path = include_path });
    }

    // resolve .auto backend into specific backend by platform
    var backend = options.backend;
    if (backend == .auto) {
        if (lib.rootModuleTarget().isDarwin()) {
            backend = .metal;
        } else if (lib.rootModuleTarget().os.tag == .windows) {
            backend = .d3d11;
        } else if (lib.rootModuleTarget().isWasm()) {
            backend = .gles3;
        } else if (lib.rootModuleTarget().isAndroid()) {
            backend = .gles3;
        } else {
            backend = .gl;
        }
    }
    const backend_cflags = switch (backend) {
        .d3d11 => "-DSOKOL_D3D11",
        .metal => "-DSOKOL_METAL",
        .gl => "-DSOKOL_GLCORE33",
        .gles3 => "-DSOKOL_GLES3",
        .wgpu => "-DSOKOL_WGPU",
        else => unreachable,
    };

    // platform specific compile and link options
    var cflags: []const []const u8 = &.{ "-DIMPL", backend_cflags };
    if (lib.rootModuleTarget().isDarwin()) {
        cflags = &.{ "-ObjC", "-DIMPL", backend_cflags };
        lib.linkFramework("Foundation");
        lib.linkFramework("AudioToolbox");
        if (.metal == backend) {
            lib.linkFramework("MetalKit");
            lib.linkFramework("Metal");
        }
        if (lib.rootModuleTarget().os.tag == .ios) {
            lib.linkFramework("UIKit");
            lib.linkFramework("AVFoundation");
            if (.gl == backend) {
                lib.linkFramework("OpenGLES");
                lib.linkFramework("GLKit");
            }
        } else if (lib.rootModuleTarget().os.tag == .macos) {
            lib.linkFramework("Cocoa");
            lib.linkFramework("QuartzCore");
            if (.gl == backend) {
                lib.linkFramework("OpenGL");
            }
        }
    } else if (lib.rootModuleTarget().isAndroid()) {
        if (.gles3 != backend) {
            @panic("For android targets, you must have backend set to GLES3");
        }
        lib.linkSystemLibrary("GLESv3");
        lib.linkSystemLibrary("EGL");
        lib.linkSystemLibrary("android");
        lib.linkSystemLibrary("log");
    } else if (lib.rootModuleTarget().os.tag == .linux) {
        const egl_cflags = if (options.force_egl) "-DSOKOL_FORCE_EGL " else "";
        const x11_cflags = if (!options.enable_x11) "-DSOKOL_DISABLE_X11 " else "";
        const wayland_cflags = if (!options.enable_wayland) "-DSOKOL_DISABLE_WAYLAND" else "";
        const link_egl = options.force_egl or options.enable_wayland;
        cflags = &.{ "-DIMPL", backend_cflags, egl_cflags, x11_cflags, wayland_cflags };
        lib.linkSystemLibrary("asound");
        lib.linkSystemLibrary("GL");
        if (options.enable_x11) {
            lib.linkSystemLibrary("X11");
            lib.linkSystemLibrary("Xi");
            lib.linkSystemLibrary("Xcursor");
        }
        if (options.enable_wayland) {
            lib.linkSystemLibrary("wayland-client");
            lib.linkSystemLibrary("wayland-cursor");
            lib.linkSystemLibrary("wayland-egl");
            lib.linkSystemLibrary("xkbcommon");
        }
        if (link_egl) {
            lib.linkSystemLibrary("egl");
        }
    } else if (lib.rootModuleTarget().os.tag == .windows) {
        lib.linkSystemLibrary("kernel32");
        lib.linkSystemLibrary("user32");
        lib.linkSystemLibrary("gdi32");
        lib.linkSystemLibrary("ole32");
        if (.d3d11 == backend) {
            lib.linkSystemLibrary("d3d11");
            lib.linkSystemLibrary("dxgi");
        }
    }

    // finally add the C source files
    const csrc_root = "src/sokol/c/";
    const csources = [_][]const u8{
        csrc_root ++ "sokol_log.c",
        csrc_root ++ "sokol_app.c",
        csrc_root ++ "sokol_gfx.c",
        csrc_root ++ "sokol_time.c",
        csrc_root ++ "sokol_audio.c",
        csrc_root ++ "sokol_gl.c",
        csrc_root ++ "sokol_debugtext.c",
        csrc_root ++ "sokol_shape.c",
    };
    for (csources) |csrc| {
        lib.addCSourceFile(.{
            .file = .{ .path = csrc },
            .flags = cflags,
        });
    }
    return lib;
}

// build one of the examples
const ExampleOptions = struct {
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    mod_sokol: *Build.Module,
    lib_sokol: *Build.Step.Compile, // only needed for WASM in the Emscripten linker step
    emsdk: ?*Build.Dependency = null,
};

fn buildExample(b: *Build, comptime name: []const u8, options: ExampleOptions) !void {
    const main_src = "src/examples/" ++ name ++ ".zig";
    var run: ?*Build.Step.Run = null;
    if (!options.target.result.isWasm()) {
        // for native platforms, build into a regular executable
        const example = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = main_src },
            .target = options.target,
            .optimize = options.optimize,
        });
        example.root_module.addImport("sokol", options.mod_sokol);
        b.installArtifact(example);
        run = b.addRunArtifact(example);
    } else {
        // for WASM, need to build the Zig code as static library, since linking happens via emcc
        const example = b.addStaticLibrary(.{
            .name = name,
            .root_source_file = .{ .path = main_src },
            .target = options.target,
            .optimize = options.optimize,
        });
        example.root_module.addImport("sokol", options.mod_sokol);

        // create a special emcc linker run step
        const emcc_link_step = try emccLinkStep(b, .{
            .target = options.target,
            .optimize = options.optimize,
            .lib_sokol = options.lib_sokol,
            .lib_main = example,
            .emsdk = options.emsdk,
        });
        // ...and special run step to run the build result via emrun
        run = emrunStep(b, .{
            .name = name,
            .emsdk = options.emsdk,
        });
        run.?.step.dependOn(&emcc_link_step.step);
    }
    b.step("run-" ++ name, "Run " ++ name).dependOn(&run.?.step);
}

// for wasm32-emscripten, need to run the Emscripten linker from the Emscripten SDK
// NOTE: ideally this would go into a separate emsdk-zig package
const EmccLinkOptions = struct {
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    lib_sokol: *Build.Step.Compile,
    lib_main: *Build.Step.Compile, // the actual Zig code must be compiled to a static link library
    emsdk: ?*Build.Dependency = null,
};
pub fn emccLinkStep(b: *Build, options: EmccLinkOptions) !*Build.Step.Run {
    const emcc_path = b.findProgram(&.{"emcc"}, &.{}) catch b.pathJoin(&.{ emsdkPath(b, options.emsdk.?), "upstream", "emscripten", "emcc" });

    // create a separate output directory zig-out/web
    try std.fs.cwd().makePath(b.fmt("{s}/web", .{b.install_path}));

    var emcc_cmd = std.ArrayList([]const u8).init(b.allocator);
    defer emcc_cmd.deinit();

    try emcc_cmd.append(emcc_path);
    if (options.optimize != .Debug) {
        try emcc_cmd.append("-Oz");
    } else {
        try emcc_cmd.append("-Og");
    }
    try emcc_cmd.append("--closure");
    try emcc_cmd.append("1");
    try emcc_cmd.append(b.fmt("-o{s}/web/{s}.html", .{ b.install_path, options.lib_main.name }));
    try emcc_cmd.append("-sNO_FILESYSTEM=1");
    try emcc_cmd.append("-sMALLOC='emmalloc'");
    try emcc_cmd.append("-sASSERTIONS=0");
    try emcc_cmd.append("-sERROR_ON_UNDEFINED_SYMBOLS=0");
    try emcc_cmd.append("--shell-file=src/sokol/web/shell.html");

    // TODO: fix undefined references
    // switch (options.backend) {
    //     .wgpu => {
    // try emcc_cmd.append("-sUSE_WEBGPU=1");
    // },
    // else => {
    try emcc_cmd.append("-sUSE_WEBGL2=1");
    //     },
    // }

    const emcc = b.addSystemCommand(emcc_cmd.items);
    emcc.setName("emcc"); // hide emcc path

    // get artifacts from zig-cache, no need zig-out
    emcc.addArtifactArg(options.lib_sokol);
    emcc.addArtifactArg(options.lib_main);

    // get the emcc step to run on 'zig build'
    b.getInstallStep().dependOn(&emcc.step);
    return emcc;
}

// build a run step which uses the emsdk emrun command to run a build target in the browser
// NOTE: ideally this would go into a separate emsdk-zig package
const EmrunOptions = struct {
    name: []const u8,
    emsdk: ?*Build.Dependency = null,
};
pub fn emrunStep(b: *Build, options: EmrunOptions) *Build.Step.Run {
    const emrun_path = b.findProgram(&.{"emrun"}, &.{}) catch b.pathJoin(&.{ emsdkPath(b, options.emsdk.?), "upstream", "emscripten", "emrun" });
    const emrun = b.addSystemCommand(&.{ emrun_path, b.fmt("{s}/web/{s}.html", .{ b.install_path, options.name }) });
    return emrun;
}

// helper function to extract emsdk path from the emsdk package dependency
fn emsdkPath(b: *Build, emsdk: *Build.Dependency) []const u8 {
    return emsdk.path("").getPath(b);
}

// One-time setup of the Emscripten SDK (runs 'emsdk install + activate'). If the
// SDK had to be setup, a run step will be returned which should be added
// as dependency to the sokol library (since this needs the emsdk in place),
// if the emsdk was already setup, null will be returned.
// NOTE: ideally this would go into a separate emsdk-zig package
fn emsdkSetupStep(b: *Build, emsdk: *Build.Dependency) !?*Build.Step.Run {
    const emsdk_path = emsdkPath(b, emsdk);
    const dot_emsc_path = b.pathJoin(&.{ emsdk_path, ".emscripten" });
    const dot_emsc_exists = !std.meta.isError(std.fs.accessAbsolute(dot_emsc_path, .{}));
    if (!dot_emsc_exists) {
        var cmd = std.ArrayList([]const u8).init(b.allocator);
        defer cmd.deinit();
        if (builtin.os.tag == .windows)
            try cmd.append(b.pathJoin(&.{ emsdk_path, "emsdk.bat" }))
        else {
            try cmd.append("bash"); // or try chmod
            try cmd.append(b.pathJoin(&.{ emsdk_path, "emsdk" }));
        }
        const emsdk_install = b.addSystemCommand(cmd.items);
        emsdk_install.addArgs(&.{ "install", "latest" });
        const emsdk_activate = b.addSystemCommand(cmd.items);
        emsdk_activate.addArgs(&.{ "activate", "latest" });
        emsdk_activate.step.dependOn(&emsdk_install.step);
        return emsdk_activate;
    } else {
        return null;
    }
}

// a separate step to compile shaders, expects the shader compiler in ../sokol-tools-bin/
// TODO: install sokol-shdc via package manager
fn buildShaders(b: *Build) void {
    const sokol_tools_bin_dir = "../sokol-tools-bin/bin/";
    const shaders_dir = "src/examples/shaders/";
    const shaders = .{
        "bufferoffsets.glsl",
        "cube.glsl",
        "instancing.glsl",
        "mrt.glsl",
        "noninterleaved.glsl",
        "offscreen.glsl",
        "quad.glsl",
        "shapes.glsl",
        "texcube.glsl",
        "blend.glsl",
    };
    const optional_shdc: ?[:0]const u8 = comptime switch (builtin.os.tag) {
        .windows => "win32/sokol-shdc.exe",
        .linux => "linux/sokol-shdc",
        .macos => if (builtin.cpu.arch.isX86()) "osx/sokol-shdc" else "osx_arm64/sokol-shdc",
        else => null,
    };
    if (optional_shdc == null) {
        std.log.warn("unsupported host platform, skipping shader compiler step", .{});
        return;
    }
    const shdc_path = sokol_tools_bin_dir ++ optional_shdc.?;
    const shdc_step = b.step("shaders", "Compile shaders (needs ../sokol-tools-bin)");
    inline for (shaders) |shader| {
        const cmd = b.addSystemCommand(&.{
            shdc_path,
            "-i",
            shaders_dir ++ shader,
            "-o",
            shaders_dir ++ shader ++ ".zig",
            "-l",
            "glsl330:metal_macos:hlsl4:glsl300es:wgsl",
            "-f",
            "sokol_zig",
        });
        shdc_step.dependOn(&cmd.step);
    }
}

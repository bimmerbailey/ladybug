const std = @import("std");

// UVICORN PARITY: Additional modules needed for full compatibility:
// - src/tls/ (TLS/SSL support with certificate management)
// - src/http2/ (HTTP/2 protocol implementation)
// - src/websocket/ (Complete WebSocket protocol handler)
// - src/middleware/ (ASGI middleware chain support)
// - src/config/ (Configuration file parsing - YAML/JSON)
// - src/reload/ (File watching and auto-reload functionality)
// - src/metrics/ (Request metrics and health endpoints)
// - src/compression/ (Response compression - gzip, brotli)

// Helper function to detect Python installation
fn detectPythonPaths(b: *std.Build, target: std.Build.ResolvedTarget) struct {
    include_path: []const u8,
    lib_path: []const u8,
    lib_name: []const u8,
} {
    // Default fallback paths
    var python_include_path: []const u8 = undefined;
    var python_lib_path: []const u8 = undefined;
    var python_lib_name: []const u8 = undefined;

    switch (target.result.os.tag) {
        .macos => {
            // Try to detect Python installation on macOS
            python_include_path = std.process.getEnvVarOwned(b.allocator, "PYTHON_INCLUDE_PATH") catch
                "/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/include/python3.13";
            python_lib_path = std.process.getEnvVarOwned(b.allocator, "PYTHON_LIB_PATH") catch
                "/opt/homebrew/opt/python@3.13/Frameworks";
            python_lib_name = "python";
        },
        .linux => {
            python_include_path = std.process.getEnvVarOwned(b.allocator, "PYTHON_INCLUDE_PATH") catch
                "/usr/include/python3.13";
            python_lib_path = std.process.getEnvVarOwned(b.allocator, "PYTHON_LIB_PATH") catch
                "/usr/lib";
            python_lib_name = "python3.13";
        },
        else => {
            // Windows or other platforms
            python_include_path = std.process.getEnvVarOwned(b.allocator, "PYTHON_INCLUDE_PATH") catch
                "C:\\Python313\\include";
            python_lib_path = std.process.getEnvVarOwned(b.allocator, "PYTHON_LIB_PATH") catch
                "C:\\Python313\\libs";
            python_lib_name = "python313";
        },
    }

    return .{
        .include_path = python_include_path,
        .lib_path = python_lib_path,
        .lib_name = python_lib_name,
    };
}

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    // OPTIMIZATION 7: Compilation - Use ReleaseFast for production builds
    // OPTIMIZATION 7: Compilation - Consider enabling LTO (Link Time Optimization)
    const optimize = b.standardOptimizeOption(.{});

    // Detect Python installation
    const python_config = detectPythonPaths(b, target);

    // This creates a "module", which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Every executable or library we compile will be based on one or more modules.
    const lib_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create a Python wrapper module (only if the wrapper file exists)
    const python_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("src/python/wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add include path to wrapper module (C imports need this)
    python_wrapper_mod.addIncludePath(.{ .cwd_relative = python_config.include_path });
    python_wrapper_mod.addIncludePath(.{ .cwd_relative = "include" });

    // Modules can depend on one another using the `std.Build.Module.addImport` function.
    // This is what allows Zig source code to use `@import("foo")` where 'foo' is not a
    // file path. In this case, we set up `exe_mod` to import `lib_mod`.
    exe_mod.addImport("ladybug_lib", lib_mod);
    exe_mod.addImport("python_wrapper", python_wrapper_mod);

    // Add imports to library module
    lib_mod.addImport("python_wrapper", python_wrapper_mod);

    // Now, we will create a static library based on the module we created above.
    // This creates a `std.Build.Step.Compile`, which is the build step responsible
    // for actually invoking the compiler.
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "ladybug",
        .root_module = lib_mod,
    });

    // Add Python linking to library as well
    lib.addSystemIncludePath(.{ .cwd_relative = python_config.include_path });
    lib.addIncludePath(.{ .cwd_relative = "include" });
    if (target.result.os.tag == .macos) {
        lib.addFrameworkPath(.{ .cwd_relative = python_config.lib_path });
        lib.linkFramework(python_config.lib_name);
    } else {
        lib.addLibraryPath(.{ .cwd_relative = python_config.lib_path });
        lib.linkSystemLibrary(python_config.lib_name);
    }
    lib.linkLibC();

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(lib);

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "ladybug",
        .root_module = exe_mod,
    });

    // Add C file for Python compatibility (only if it exists)
    exe.addCSourceFile(.{
        .file = b.path("include/py_compat.c"),
        .flags = &.{},
    });

    // Add Python to executable
    exe.addSystemIncludePath(.{ .cwd_relative = python_config.include_path });
    exe.addIncludePath(.{ .cwd_relative = "include" }); // Add our wrapper directory

    // Platform-specific Python linking
    if (target.result.os.tag == .macos) {
        exe.addFrameworkPath(.{ .cwd_relative = python_config.lib_path });
        exe.linkFramework(python_config.lib_name);
    } else {
        exe.addLibraryPath(.{ .cwd_relative = python_config.lib_path });
        exe.linkSystemLibrary(python_config.lib_name);
    }
    exe.linkLibC();

    // OPTIMIZATION 7: Compilation - Add CPU-specific optimizations and strip debug info for production
    // OPTIMIZATION 7: Compilation - Consider adding -ffast-math for floating point optimizations
    if (optimize == .ReleaseFast or optimize == .ReleaseSmall) {
        // Add optimization flags for release builds
        exe.want_lto = true;
    }

    // Test module needs Python too (only create if test file exists)
    const python_integration_test = b.addTest(.{
        .name = "python-integration-test",
        .root_source_file = b.path("src/python/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    python_integration_test.root_module.addImport("python_wrapper", python_wrapper_mod);

    python_integration_test.addIncludePath(.{ .cwd_relative = python_config.include_path });
    python_integration_test.addIncludePath(.{ .cwd_relative = "include" });

    // Consistent Python linking for tests
    if (target.result.os.tag == .macos) {
        python_integration_test.addFrameworkPath(.{ .cwd_relative = python_config.lib_path });
        python_integration_test.linkFramework(python_config.lib_name);
    } else {
        python_integration_test.addLibraryPath(.{ .cwd_relative = python_config.lib_path });
        python_integration_test.linkSystemLibrary(python_config.lib_name);
    }
    python_integration_test.linkLibC();

    // Add C file for Python compatibility to the test
    python_integration_test.addCSourceFile(.{
        .file = b.path("include/py_compat.c"),
        .flags = &.{},
    });

    const run_python_tests = b.addRunArtifact(python_integration_test);
    const test_python_step = b.step("test-python", "Run Python integration tests");
    test_python_step.dependOn(&run_python_tests.step);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

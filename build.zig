// SPDX-FileCopyrightText: 2026 Pooya Parsa <pooya@pi0.io>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // default is the production build (ReleaseFast); pass -Doptimize=Debug
    // for symbols + safety checks (also makes `zig build test` catch UB).
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseFast;
    // non-Debug strips the server; the wasm is always ReleaseSmall, whose
    // default already strips — forcing strip=false balloons it 115K → 770K.
    const strip = optimize != .Debug;

    // relay executable (wlandr). -Dhttp=false drops the HTTP/WebSocket server
    // (and std.http) for a smaller --link-only build — the shape a guest wants.
    const http = b.option(bool, "http", "Include the HTTP/WebSocket server (default true; false = --link-only)") orelse true;
    const server_options = b.addOptions();
    server_options.addOption(bool, "http", http);
    const options_mod = server_options.createModule();

    // core: shared wayland implementation, native flavor (server + tests)
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const server_mod = serverModule(b, target, optimize, strip, core_mod, options_mod);
    b.installArtifact(b.addExecutable(.{ .name = "wlandr", .root_module = server_mod }));

    // wland-fixture: the small Wayland clients the E2E tests run in place of
    // real apps (test/fixture/main.zig). Installed next to wlandr; not shipped.
    b.installArtifact(b.addExecutable(.{ .name = "wland-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("test/fixture/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    }) }));

    // `zig build release`: the binaries the npm package ships, as
    // zig-out/release/wlandr-<node platform>-<node arch>. No libc is linked,
    // so these are static and run on any Linux (glibc, musl or neither); the
    // explicit target also means the baseline CPU, where the native default
    // above uses the host's features.
    const release_step = b.step("release", "Build wlandr for linux x64 + arm64 (zig-out/release/)");
    const releases = [_]struct { arch: std.Target.Cpu.Arch, node: []const u8 }{
        .{ .arch = .x86_64, .node = "x64" },
        .{ .arch = .aarch64, .node = "arm64" },
    };
    for (releases) |r| {
        const rt = b.resolveTargetQuery(.{ .cpu_arch = r.arch, .os_tag = .linux, .abi = .musl });
        const rcore = b.createModule(.{
            .root_source_file = b.path("core/src/root.zig"),
            .target = rt,
            .optimize = optimize,
        });
        const exe = b.addExecutable(.{
            .name = "wlandr",
            .root_module = serverModule(b, rt, optimize, strip, rcore, options_mod),
        });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = b.fmt("wlandr-linux-{s}", .{r.node}),
        });
        release_step.dependOn(&install.step);
    }

    // core compiled to wasm for the browser client
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const core_wasm_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("core/src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "core", .module = core_wasm_mod }},
    });
    const wasm_exe = b.addExecutable(.{
        .name = "wland",
        .root_module = wasm_mod,
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    // The wasm is a SOURCE-TREE output, written relative to the build root
    // whatever the install prefix (-p elsewhere must not write outside it):
    // next to the npm lib, where lib/engine.ts resolves it relative to itself
    // via import.meta.url (so vite bundles it into the web page too). It is
    // committed, so the page builds (e.g. on Vercel) without zig.
    const wasm_to_source = b.addUpdateSourceFiles();
    wasm_to_source.addCopyFileToSource(wasm_exe.getEmittedBin(), "lib/wland.wasm");
    b.getInstallStep().dependOn(&wasm_to_source.step);

    // tests (native only)
    const core_tests = b.addTest(.{ .root_module = core_mod });
    const run_core_tests = b.addRunArtifact(core_tests);
    const server_tests = b.addTest(.{ .root_module = server_mod });
    const run_server_tests = b.addRunArtifact(server_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_server_tests.step);
}

fn serverModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    core_mod: *std.Build.Module,
    options_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("server/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "build_options", .module = options_mod },
        },
    });
}

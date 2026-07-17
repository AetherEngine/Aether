<div align="center"><img width=50% src="branding/Aether-Transparent.png"/></div>
<h2 align="center">A performant, cross-platform game engine</h2>

## What is Aether?

Aether is a game engine written in [Zig](https://ziglang.org/). It is platform-agnostic -- there should be no difference running between Windows, Linux, macOS, and consoles like the PSP or Switch.

User code is structured as hooks into the engine via a `State` interface. You implement the game logic; the engine handles the platform details.

## Features

- **Cross-platform**: Windows, Linux, macOS (PSP/Switch planned)
- **Multiple graphics backends**: OpenGL 4.5, Vulkan — selected at compile time, overridable with `-Dgfx=opengl`
- **Fixed-step game loop**: 144 Hz updates, 20 Hz ticks, uncapped rendering
- **Action-based input system**: keyboard, mouse, and gamepad with callback bindings
- **Generic mesh & pipeline API**: define vertex layouts from structs using comptime reflection
- **Budgeted memory pools**: render, audio, game, user, and scratch — no hidden heap allocations

## Requirements

- Zig **0.16.0-dev** or later (see `build.zig.zon` for exact minimum)
- GLFW 3 (system library)
- Vulkan SDK (for Vulkan headers; on macOS, MoltenVK is used)

## Getting Started

Add Aether as a dependency in your `build.zig.zon`:

```zon
.dependencies = .{
    .engine = .{
        .url = "https://github.com/user/aether/archive/<commit>.tar.gz",
        .hash = "...",
    },
},
```

Then set up your `build.zig`:

```zig
const std = @import("std");
const Aether = @import("engine");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional: allow overriding the graphics backend with -Dgfx=opengl
    const overrides: Aether.Config.Overrides = .{
        .gfx = b.option(Aether.Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
    };

    const config = Aether.Config.resolve(target, overrides);

    const ae_dep = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
    });

    // Create a game executable -- this wires up the engine module
    // and all platform-specific dependencies (GLFW/Vulkan/OpenGL/pspsdk)
    const exe = Aether.addGame(ae_dep.builder, b, .{
        .name = "my_game",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });

    // Export the artifact (produces EBOOT.PBP for PSP, install artifact otherwise)
    Aether.exportArtifact(ae_dep.builder, b, exe, config, .{
        .title = "My Game",
    });

    const run_step = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
}
```

The first argument to `addGame` and `exportArtifact` is the
dependency's builder (`ae_dep.builder`), and the second is your project's
builder (`b`). This lets Aether resolve its own internal dependencies (GLFW,
Vulkan, Slang, pspsdk) from its `build.zig.zon` while building artifacts that
belong to your project.

You can add additional module imports to the returned compile step as usual:

```zig
exe.root_module.addImport("my_module", my_module);
```

Then write your game code:

```zig
const std = @import("std");
const ae = @import("aether");

const MyState = struct {
    fn init(ctx: *anyopaque, engine: *ae.Engine) anyerror!void { _ = ctx; _ = engine; }
    fn deinit(ctx: *anyopaque, engine: *ae.Engine) void { _ = ctx; _ = engine; }
    fn tick(ctx: *anyopaque, engine: *ae.Engine) anyerror!void { _ = ctx; _ = engine; }
    fn update(ctx: *anyopaque, engine: *ae.Engine, dt: f32, _: *const ae.Util.BudgetContext) anyerror!void { _ = ctx; _ = engine; _ = dt; }
    fn draw(ctx: *anyopaque, engine: *ae.Engine, dt: f32, _: *const ae.Util.BudgetContext) anyerror!void { _ = ctx; _ = engine; _ = dt; }

    pub fn state(self: *MyState) ae.Core.State {
        return .{ .ptr = self, .tab = &.{
            .init = init, .deinit = deinit,
            .tick = tick, .update = update, .draw = draw,
        }};
    }
};

pub fn main(init: std.process.Init) !void {
    const memory = try init.gpa.alignedAlloc(u8, .fromByteUnits(16), 32 * 1024 * 1024);
    defer init.gpa.free(memory);

    var my_state: MyState = undefined;
    var engine: ae.Engine = undefined;
    try engine.init(init.io, init.environ_map, memory, .{
        .memory = .{
            .render = 8 * 1024 * 1024,
            .audio = 2 * 1024 * 1024,
            .game = 2 * 1024 * 1024,
            .user = 16 * 1024 * 1024,
        },
        .title = "My Game",
    }, &my_state.state());
    defer engine.deinit();
    try engine.run();
}
```

Platform and graphics backend are available as comptime constants for per-platform configuration:

```zig
const memory_config: ae.Util.MemoryConfig = switch (ae.platform) {
    .psp => .{ .render = 512 * 1024, .audio = 256 * 1024, ... },
    else => .{ .render = 8 * 1024 * 1024, .audio = 2 * 1024 * 1024, ... },
};
```

## Building

```sh
# Build and run
zig build run

# Run tests
zig build test

# Override graphics backend
zig build run -Dgfx=opengl

# Build for PSP
zig build -Dtarget=mipsel-psp

# Build in release mode
zig build -Doptimize=ReleaseFast
```

## Input System

Actions are registered by name and bound to one or more input sources:

```zig
try ae.Core.input.register_action("jump", .button);
try ae.Core.input.bind_action("jump", .{ .source = .{ .key = .Space } });
try ae.Core.input.add_button_callback("jump", ctx, on_jump);
```

Supported sources: keyboard keys, mouse buttons, mouse scroll, mouse relative movement, and gamepad buttons/axes.

## Rendering

Build editable CPU geometry in `MeshData`, upload or bind it through `Mesh`,
and draw with an explicit render state:

```zig
const Vertex = ae.Rendering.Vertex;
const MeshData = ae.Rendering.MeshData(Vertex);
const Mesh = ae.Rendering.Mesh(Vertex);

var data = try MeshData.init(render_alloc);
defer data.deinit(render_alloc);

var mesh = try Mesh.init(&.{});
defer mesh.deinit();

try data.add_tri(render_alloc, a, b, c);
mesh.update(&data);

ae.Rendering.set_state(&.{
    .texture = texture.handle,
    .proj = projection,
    .view = view,
    .depth_write = false,
});
mesh.draw(&model);
```

On PSP and 3DS, mesh data is borrowed directly by the backend, so keep the
`MeshData` alive and call `mesh.update(&data)` after edits that may reallocate.
Static textures can use the default `.cpu_access = .none`; request
`.read_write` when you need `set_pixel` or direct CPU buffer access.

## Build API Reference

### `Aether.addGame(owner, b, opts) -> *Compile`

Creates a game executable with the engine module and platform dependencies wired up.

| Option | Type | Description |
|--------|------|-------------|
| `name` | `[]const u8` | Executable name |
| `root_source_file` | `LazyPath` | Path to your main source file |
| `target` | `ResolvedTarget` | Build target |
| `optimize` | `OptimizeMode` | Optimization level (default: `.Debug`) |
| `overrides` | `Config.Overrides` | Graphics/display mode overrides (default: `.{}`) |

### `Aether.exportArtifact(owner, b, exe, config, opts)`

Exports the build artifact. For PSP targets, produces an `EBOOT.PBP`. For desktop, installs the artifact normally.

| Option | Type | Description |
|--------|------|-------------|
| `title` | `[]const u8` | Application title (used in PSP `EBOOT.PBP`) |
| `output_dir` | `?[]const u8` | Output directory name (optional) |
| `icon0` | `?LazyPath` | PSP icon (optional) |
| `pic0`, `pic1` | `?LazyPath` | PSP background images (optional) |
| `snd0` | `?LazyPath` | PSP startup sound (optional) |

### `Aether.Config.resolve(target, overrides) -> Config`

Resolves the full engine configuration (platform, graphics backend, audio, input) from the build target and any user overrides. Pass the result to `exportArtifact`.

### `Aether.Config.Overrides`

| Field | Type | Description |
|-------|------|-------------|
| `gfx` | `?Gfx` | Graphics backend override (`null` = auto-detect) |
| `psp_display_mode` | `?PspDisplayMode` | PSP display mode (`null` = `rgba8888`) |

## License

See [LICENSE](LICENSE).

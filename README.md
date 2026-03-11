<div align="center"><img width=50% src="branding/Aether-Transparent.png"/></div>
<h2 align="center">A performant, cross-platform game engine</h2>

## What is Aether?

Aether is a game engine written in [Zig](https://ziglang.org/). It is platform-agnostic — there should be no difference running between Windows, Linux, macOS, and consoles like the PSP or the 3DS.

User code is structured as hooks into the engine via a `State` interface. You implement the game logic; the engine handles the platform details.

## Features

- **Cross-platform**: Windows, Linux, macOS (PSP/3DS planned)
- **Multiple graphics backends**: OpenGL 4.5 (Windows/Linux), Vulkan (Windows/macOS/Linux) — selected at compile time
- **Fixed-step game loop**: 144 Hz updates, 20 Hz ticks, uncapped rendering
- **Action-based input system**: keyboard, mouse, and gamepad with callback bindings
- **Generic mesh & pipeline API**: define vertex layouts from structs using comptime reflection

## Requirements

- Zig **0.15.2** or later
- GLFW 3 (system library)
- Vulkan SDK (Windows/macOS only)

## Getting Started

Add Aether as a dependency in your `build.zig.zon`, then import and use it:

```zig
const ae = @import("aether");

const MyState = struct {
    fn init(ctx: *anyopaque) anyerror!void { _ = ctx; }
    fn deinit(ctx: *anyopaque) void { _ = ctx; }
    fn tick(ctx: *anyopaque) anyerror!void { _ = ctx; }
    fn update(ctx: *anyopaque, dt: f32) anyerror!void { _ = ctx; _ = dt; }
    fn draw(ctx: *anyopaque, dt: f32) anyerror!void { _ = ctx; _ = dt; }

    pub fn state(self: *MyState) ae.Core.State {
        return .{ .ptr = self, .tab = &.{
            .init = init, .deinit = deinit,
            .tick = tick, .update = update, .draw = draw,
        }};
    }
};

pub fn main(init: std.process.Init) !void {
    var my_state: MyState = undefined;
    try ae.App.init(init.io, 1280, 720, "My Game", .default, false, true, &my_state.state());
    defer ae.App.deinit(init.io);
    try ae.App.main_loop(init.io);
}
```

## Building

```sh
# Build and run
zig build run

# Run tests
zig build test --summary all
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

Define a vertex type, create a pipeline, and draw meshes:

```zig
const Vertex = struct {
    pos: [3]f32,
    color: [4]u8,

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &.{
        .{ .field = "pos", .location = 0 },
        .{ .field = "color", .location = 1 },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};

const MyMesh = Rendering.Mesh(Vertex);
```

Shaders are embedded at compile time with `@embedFile`. OpenGL uses GLSL; Vulkan uses pre-compiled SPIR-V.

## License

See [LICENSE](LICENSE).

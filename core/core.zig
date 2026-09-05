//! High-level engine API, built on Platform contracts and services.

pub const state_machine = @import("state_machine.zig");
pub const StateMachine = state_machine.StateMachine;
pub const State = @import("State.zig");
pub const input = @import("input/input.zig");
pub const InputSystem = input.InputSystem;
pub const paths = @import("platform").paths;

pub const Engine = @import("engine.zig").Engine;
pub const AppOptions = @import("app_options.zig");
pub const Audio = @import("audio/audio.zig");
pub const Rendering = @import("rendering/rendering.zig");
pub const Ui = @import("ui/ui.zig");
pub const Util = @import("util/util.zig");

/// Shared low-level math primitives, also available through the engine API.
pub const Math = @import("platform").math;

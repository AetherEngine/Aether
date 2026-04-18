const std = @import("std");
const builtin = @import("builtin");
const Platform = @import("../platform/platform.zig");

pub const Key = enum(u16) {
    // Printable keys
    Space = 32,
    Apostrophe = 39,
    Comma = 44,
    Minus = 45,
    Period = 46,
    Slash = 47,
    Num0 = 48,
    Num1 = 49,
    Num2 = 50,
    Num3 = 51,
    Num4 = 52,
    Num5 = 53,
    Num6 = 54,
    Num7 = 55,
    Num8 = 56,
    Num9 = 57,
    Semicolon = 59,
    Equal = 61,
    A = 65,
    B = 66,
    C = 67,
    D = 68,
    E = 69,
    F = 70,
    G = 71,
    H = 72,
    I = 73,
    J = 74,
    K = 75,
    L = 76,
    M = 77,
    N = 78,
    O = 79,
    P = 80,
    Q = 81,
    R = 82,
    S = 83,
    T = 84,
    U = 85,
    V = 86,
    W = 87,
    X = 88,
    Y = 89,
    Z = 90,
    LeftBracket = 91,
    Backslash = 92,
    RightBracket = 93,
    GraveAccent = 96,
    // Function keys
    Escape = 256,
    Enter = 257,
    Tab = 258,
    Backspace = 259,
    Insert = 260,
    Delete = 261,
    Right = 262,
    Left = 263,
    Down = 264,
    Up = 265,
    PageUp = 266,
    PageDown = 267,
    Home = 268,
    End = 269,
    CapsLock = 280,
    ScrollLock = 281,
    NumLock = 282,
    PrintScreen = 283,
    Pause = 284,
    F1 = 290,
    F2 = 291,
    F3 = 292,
    F4 = 293,
    F5 = 294,
    F6 = 295,
    F7 = 296,
    F8 = 297,
    F9 = 298,
    F10 = 299,
    F11 = 300,
    F12 = 301,
    // Keypad
    Kp0 = 320,
    Kp1 = 321,
    Kp2 = 322,
    Kp3 = 323,
    Kp4 = 324,
    Kp5 = 325,
    Kp6 = 326,
    Kp7 = 327,
    Kp8 = 328,
    Kp9 = 329,
    KpDecimal = 330,
    KpDivide = 331,
    KpMultiply = 332,
    KpSubtract = 333,
    KpAdd = 334,
    KpEnter = 335,
    KpEqual = 336,
    // Modifiers
    LeftShift = 340,
    LeftControl = 341,
    LeftAlt = 342,
    LeftSuper = 343,
    RightShift = 344,
    RightControl = 345,
    RightAlt = 346,
    RightSuper = 347,
    Menu = 348,
};
pub const MouseButton = enum(u16) {
    Left = 0,
    Right = 1,
    Middle = 2,
};
pub const Button = enum(u16) {
    A = 0,
    B = 1,
    X = 2,
    Y = 3,
    LButton = 4,
    RButton = 5,
    Back = 6,
    Start = 7,
    Guide = 8,
    LeftThumb = 9,
    DpadUp = 10,
    DpadRight = 11,
    DpadDown = 12,
    DpadLeft = 13,
};

pub const Axis = enum(u16) {
    LeftX = 0,
    LeftY = 1,
    RightX = 2,
    RightY = 3,
    // Analog triggers. Desktop gamepads only; PSP backend returns 0.
    // GLFW reports these on axes 4/5 as -1 released to 1 fully pressed.
    LeftTrigger = 4,
    RightTrigger = 5,
};

pub const MouseScroll = enum(u16) {
    Up,
    Down,
};

pub const MouseRelativeAxis = enum(u16) {
    X,
    Y,
};

pub const ActionType = enum {
    button,
    axis,
    vector2,
};

pub const BindingSource = union(enum) {
    key: Key,
    mouse_button: MouseButton,
    gamepad_button: Button,
    gamepad_axis: Axis,
    mouse_scroll: void,
    mouse_relative: MouseRelativeAxis,
};

pub const ActionComponent = enum(u8) {
    x,
    y,
};

pub const InputMode = enum {
    keyboard,
    controller,
};

pub const Deadzone = 0.4;
pub const Binding = struct {
    source: BindingSource,
    component: ?ActionComponent = null,
    multiplier: f32 = 1.0,
    deadzone: f32 = Deadzone,
};

pub const ButtonEvent = enum {
    pressed,
    released,
};

pub const ActionValue = union(ActionType) {
    button: ButtonEvent,
    axis: f32,
    vector2: [2]f32,
};

pub const ButtonCallback = *const fn (ctx: *anyopaque, event: ButtonEvent) void;
pub const AxisCallback = *const fn (ctx: *anyopaque, value: f32) void;
pub const Vector2Callback = *const fn (ctx: *anyopaque, value: [2]f32) void;
pub const LostFocusCallback = *const fn (ctx: *anyopaque) void;

pub const Action = struct {
    type: ActionType,
    bindings: std.ArrayList(Binding),
    context: ?*anyopaque = null,
    callback: ?*const anyopaque = null,
    current_value: ActionValue = undefined,
    previous_value: ActionValue = undefined,
};

var allocator: std.mem.Allocator = undefined;
var actions: std.StringArrayHashMapUnmanaged(Action) = .empty;
var lost_focus_context: ?*anyopaque = null;
var lost_focus_callback: ?LostFocusCallback = null;
var last_input_mode: InputMode = if (builtin.os.tag == .freestanding) .controller else .keyboard;

pub var mouse_sensitivity: f32 = 1.0;

/// Initializes the input system with the given allocator.
pub fn init(alloc: std.mem.Allocator) !void {
    allocator = alloc;
    actions = .empty;

    set_mouse_relative_mode(false);
}

/// Deinitializes the input system, freeing all resources.
pub fn deinit() void {
    for (actions.values()) |*action| {
        action.bindings.deinit(allocator);
    }
    actions.deinit(allocator);
}

/// Removes all registered actions, their bindings, and callbacks.
/// Leaves the input system initialized and ready to accept new registrations.
pub fn clear() void {
    for (actions.values()) |*action| {
        action.bindings.deinit(allocator);
    }
    actions.clearRetainingCapacity();
    lost_focus_context = null;
    lost_focus_callback = null;
}

/// Registers a new action with the given name and type.
/// Returns an error if an action with the same name already exists.
pub fn register_action(name: []const u8, action_type: ActionType) !void {
    if (actions.get(name)) |_| {
        return error.ActionAlreadyExists;
    }

    const action = Action{
        .type = action_type,
        .bindings = try std.ArrayList(Binding).initCapacity(allocator, 4),
        .current_value = switch (action_type) {
            .button => ActionValue{ .button = .released },
            .axis => ActionValue{ .axis = 0.0 },
            .vector2 => ActionValue{ .vector2 = .{ 0.0, 0.0 } },
        },
        .previous_value = switch (action_type) {
            .button => ActionValue{ .button = .released },
            .axis => ActionValue{ .axis = 0.0 },
            .vector2 => ActionValue{ .vector2 = .{ 0.0, 0.0 } },
        },
    };

    try actions.put(allocator, name, action);
}

/// Binds a new input source to the specified action.
/// Returns an error if the action does not exist.
pub fn bind_action(name: []const u8, binding: Binding) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    try action.bindings.append(allocator, binding);
}

/// Adds a callback for button actions.
pub fn add_button_callback(name: []const u8, context: *anyopaque, callback: ButtonCallback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    action.context = context;
    if (action.type != .button) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

/// Adds a callback for axis actions.
pub fn add_axis_callback(name: []const u8, context: *anyopaque, callback: AxisCallback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    action.context = context;
    if (action.type != .axis) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

/// Adds a callback for vector2 actions.
pub fn add_vector2_callback(name: []const u8, context: *anyopaque, callback: Vector2Callback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    action.context = context;
    if (action.type != .vector2) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

/// Sets the callback fired when the window loses focus.
/// No-op on platforms without windowed focus (e.g. PSP) — the event never fires.
pub fn set_lost_focus_callback(context: *anyopaque, callback: LostFocusCallback) void {
    lost_focus_context = context;
    lost_focus_callback = callback;
}

/// Dispatches the lost-focus event to the registered callback, if any.
/// Called by the platform layer when the window loses focus.
pub fn fire_lost_focus() void {
    if (lost_focus_callback) |cb| cb(lost_focus_context.?);
}

/// Enables or disables mouse relative mode (captured and hidden).
pub fn set_mouse_relative_mode(enabled: bool) void {
    Platform.input.set_mouse_relative_mode(enabled);
}

/// Returns the input device category that most recently produced a non-zero binding value.
/// Useful for branching UI prompts between KBM and gamepad glyphs.
pub fn get_last_input_mode() InputMode {
    return last_input_mode;
}

/// Updates the input system, polling the current state and invoking callbacks as necessary.
pub fn update() void {
    var iter = actions.iterator();
    while (iter.next()) |entry| {
        var action = entry.value_ptr;
        const new_value = get_action_value(action);

        const changed = !std.meta.eql(new_value, action.current_value);
        action.previous_value = action.current_value;
        action.current_value = new_value;

        if (action.callback) |cb_ptr| {
            if (action.context) |ctx| {
                switch (action.type) {
                    .button => {
                        const cb: ButtonCallback = @ptrCast(@alignCast(cb_ptr));
                        if (changed)
                            cb(ctx, new_value.button);
                    },
                    .axis => {
                        const cb: AxisCallback = @ptrCast(@alignCast(cb_ptr));

                        if (changed or new_value.axis > Deadzone or new_value.axis < -Deadzone)
                            cb(ctx, new_value.axis);
                    },
                    .vector2 => {
                        const cb: Vector2Callback = @ptrCast(@alignCast(cb_ptr));

                        if (changed or new_value.vector2[0] > Deadzone or new_value.vector2[0] < -Deadzone or new_value.vector2[1] > Deadzone or new_value.vector2[1] < -Deadzone)
                            cb(ctx, new_value.vector2);
                    },
                }
            }
        }
    }
}

fn get_action_value(action: *const Action) ActionValue {
    switch (action.type) {
        .button => {
            var is_pressed = false;
            for (action.bindings.items) |b| {
                const contrib = get_binding_value(&b);
                if (contrib > 0.0) {
                    is_pressed = true;
                    break;
                }
            }

            return .{
                .button = if (is_pressed) .pressed else .released,
            };
        },
        .axis => {
            var value: f32 = 0.0;
            for (action.bindings.items) |b| {
                value += get_binding_value(&b);
            }

            return .{
                .axis = value,
            };
        },
        .vector2 => {
            var x: f32 = 0.0;
            var y: f32 = 0.0;

            for (action.bindings.items) |b| {
                const contrib = get_binding_value(&b);

                if (b.component == null) {
                    continue;
                }

                switch (b.component.?) {
                    .x => x += contrib,
                    .y => y += contrib,
                }
            }

            return .{
                .vector2 = [_]f32{ x, y },
            };
        },
    }
}

fn get_binding_value(binding: *const Binding) f32 {
    const multiplier = binding.multiplier;
    var raw: f32 = 0.0;

    switch (binding.source) {
        .key => |k| {
            raw = if (Platform.input.is_key_down(k)) 1.0 else 0.0;
        },
        .mouse_button => |mb| {
            raw = if (Platform.input.is_mouse_button_down(mb)) 1.0 else 0.0;
        },
        .gamepad_button => |gb| {
            raw = if (Platform.input.is_gamepad_button_down(gb)) 1.0 else 0.0;
        },
        .gamepad_axis => |ga| {
            raw = Platform.input.get_gamepad_axis(ga);
            if (raw > binding.deadzone) {
                raw = (raw - binding.deadzone) / (1.0 - binding.deadzone);
            } else if (raw < -binding.deadzone) {
                raw = (raw + binding.deadzone) / (1.0 - binding.deadzone);
            } else {
                raw = 0.0;
            }
        },
        .mouse_scroll => {
            raw = Platform.input.get_mouse_scroll();
        },
        .mouse_relative => |mr| {
            raw = if (mr == .X) Platform.input.get_mouse_delta(mouse_sensitivity)[0] else Platform.input.get_mouse_delta(mouse_sensitivity)[1];
        },
    }

    if (raw != 0.0) {
        last_input_mode = switch (binding.source) {
            .key, .mouse_button, .mouse_scroll, .mouse_relative => .keyboard,
            .gamepad_button, .gamepad_axis => .controller,
        };
    }

    return raw * multiplier;
}

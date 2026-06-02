//! Public input system entry point. Owns the state singletons (frame
//! buffer, device state, action-set registry, context stack, sessions)
//! and exposes the five surfaces from spec/input.allium:
//! FrameApi, ActionApi, ContextStackApi, TextInputApi, CaptureNextInputApi.
//!
//! Backends call the `deliver_*` and `signal_frame_boundary` functions
//! below -- they are public so the platform module can reach them, but
//! game code should treat them as backend-internal.

const std = @import("std");

pub const data = @import("data.zig");
pub const frame = @import("frame.zig");
pub const binding_mod = @import("binding.zig");
pub const action_mod = @import("action.zig");
pub const context_mod = @import("context.zig");
pub const text_session_mod = @import("text_session.zig");
pub const capture_session_mod = @import("capture_session.zig");

// Re-exports -- game code reaches these through `Core.input.<name>`.
pub const Key = data.Key;
pub const MouseButton = data.MouseButton;
pub const Button = data.Button;
pub const Axis = data.Axis;
pub const Modifier = data.Modifier;
pub const ModifierSet = data.ModifierSet;
pub const ButtonState = data.ButtonState;
pub const InputMode = data.InputMode;

pub const Vec2 = frame.Vec2;
pub const Pointer = frame.Pointer;
pub const RawEvent = frame.RawEvent;
pub const InputFrame = frame.InputFrame;

pub const BindingSourceKind = binding_mod.BindingSourceKind;
pub const BindingSource = binding_mod.BindingSource;
pub const Binding = binding_mod.Binding;
pub const AxisComponent = binding_mod.AxisComponent;
pub const Vec2Axis = binding_mod.Vec2Axis;

pub const ActionKind = action_mod.ActionKind;
pub const ActionValue = action_mod.ActionValue;
pub const Action = action_mod.Action;
pub const ActionSet = action_mod.ActionSet;
pub const ActionSetHandle = action_mod.ActionSetHandle;

pub const CursorMode = context_mod.CursorMode;
pub const InputContext = context_mod.InputContext;
pub const ContextStack = context_mod.ContextStack;

pub const TextInputStatus = text_session_mod.TextInputStatus;
pub const TextInputTarget = text_session_mod.TextInputTarget;
pub const TextInputOptions = text_session_mod.TextInputOptions;
pub const TextInputSession = text_session_mod.TextInputSession;

pub const CaptureNextInputStatus = capture_session_mod.CaptureNextInputStatus;
pub const CaptureResult = capture_session_mod.CaptureResult;
pub const CaptureNextInputSession = capture_session_mod.CaptureNextInputSession;

pub const config = struct {
    pub const axis_activity_threshold: f32 = 0.1;
    pub const default_axis_deadzone: f32 = binding_mod.default_axis_deadzone;
};

// -- module state -------------------------------------------------------------

var alloc: std.mem.Allocator = undefined;
var fb: frame.FrameBuffer = undefined;
var device: action_mod.DeviceState = .{};
var pub_frame: InputFrame = .{};
var registry: std.ArrayList(ActionSet) = .empty;
var stack: ContextStack = .{};
var text_session_state: ?TextInputSession = null;
var capture_session_state: ?CaptureNextInputSession = null;
var current_modifiers: ModifierSet = .{};
var last_mode: InputMode = .keyboard_mouse;
var initialised: bool = false;

var begin_text_session_hook: ?*const fn (TextInputTarget, TextInputOptions) anyerror!void = null;
var end_text_session_hook: ?*const fn () void = null;

const base_set_name = "__base";

// -- lifecycle ----------------------------------------------------------------

/// Initialise the input system. Called by `Platform.input.init` (do not
/// call directly from game code).
pub fn init(allocator: std.mem.Allocator) !void {
    alloc = allocator;
    fb = frame.FrameBuffer.init(allocator);
    device = .{};
    registry = .empty;
    stack = .{};
    text_session_state = null;
    capture_session_state = null;
    current_modifiers = .{};
    last_mode = .keyboard_mouse;
    pub_frame = .{};

    // Seed an installed empty base set so the stack always has a top.
    const base_handle = try register_action_set(base_set_name);
    try install_action_set(base_handle);
    try stack.push(.{
        .name = "base",
        .cursor_mode = .visible,
        .actions = base_handle,
        .consumes_text = false,
        .consumes_pointer = true,
    });

    initialised = true;
}

pub fn deinit() void {
    if (!initialised) return;
    initialised = false;

    if (text_session_state) |*s| s.deinit(alloc);
    text_session_state = null;
    if (capture_session_state) |*s| s.deinit(alloc);
    capture_session_state = null;

    for (registry.items) |*set| {
        var it = set.actions.iterator();
        while (it.next()) |entry| entry.value_ptr.bindings.deinit(alloc);
        set.actions.deinit(alloc);
    }
    registry.deinit(alloc);

    device.deinit(alloc);
    fb.deinit();
    stack = .{};
}

// -- platform-facing entry points ---------------------------------------------

pub fn deliver_key_down(key: Key, mods: ModifierSet, is_repeat: bool) void {
    current_modifiers = mods;
    if (!is_repeat) _ = device.keys.put(alloc, key, {}) catch return;
    _ = fb.append_event(.{ .key_down = .{ .key = key, .modifiers = mods, .is_repeat = is_repeat } }) catch return;
    last_mode = .keyboard_mouse;
    capture_on_down(.{ .key = key }, mods, is_repeat);
}

pub fn deliver_key_up(key: Key, mods: ModifierSet) void {
    current_modifiers = mods;
    _ = device.keys.remove(key);
    _ = fb.append_event(.{ .key_up = .{ .key = key, .modifiers = mods } }) catch return;
    capture_on_release(.{ .key = key });
}

pub fn deliver_text(text: []const u8) void {
    const interned = fb.intern_text(text) catch return;
    _ = fb.append_event(.{ .text_utf8 = .{ .text = interned } }) catch return;
    route_text_to_session(interned);
    last_mode = .keyboard_mouse;
}

pub fn deliver_mouse_button(button: MouseButton, edge: ButtonState, position: Vec2) void {
    device.pointer_position = position;
    if (edge == .pressed) {
        device.mouse_buttons.insert(button);
        _ = fb.append_event(.{ .mouse_button_down = .{ .button = button, .position = position } }) catch return;
        capture_on_down(.{ .mouse_button = button }, current_modifiers, false);
    } else {
        device.mouse_buttons.remove(button);
        _ = fb.append_event(.{ .mouse_button_up = .{ .button = button, .position = position } }) catch return;
        capture_on_release(.{ .mouse_button = button });
    }
    last_mode = .keyboard_mouse;
}

pub fn deliver_mouse_move(position: Vec2, delta: Vec2) void {
    device.pointer_position = position;
    device.pointer_delta_accum.x += delta.x;
    device.pointer_delta_accum.y += delta.y;
    _ = fb.append_event(.{ .mouse_move_abs = .{ .position = position } }) catch {};
    if (delta.x != 0 or delta.y != 0) {
        _ = fb.append_event(.{ .mouse_move_rel = .{ .delta = delta } }) catch {};
        last_mode = .keyboard_mouse;
    }
}

pub fn deliver_mouse_wheel(delta: Vec2) void {
    device.wheel_accum.x += delta.x;
    device.wheel_accum.y += delta.y;
    _ = fb.append_event(.{ .mouse_wheel = .{ .delta = delta } }) catch return;
    if (delta.x != 0 or delta.y != 0) last_mode = .keyboard_mouse;
}

pub fn deliver_gamepad_button(button: Button, edge: ButtonState) void {
    if (edge == .pressed) {
        device.gamepad_buttons.insert(button);
        _ = fb.append_event(.{ .gamepad_button_down = .{ .button = button } }) catch return;
        last_mode = .gamepad;
        capture_on_down(.{ .gamepad_button = button }, current_modifiers, false);
    } else {
        device.gamepad_buttons.remove(button);
        _ = fb.append_event(.{ .gamepad_button_up = .{ .button = button } }) catch return;
        capture_on_release(.{ .gamepad_button = button });
    }
}

pub fn deliver_gamepad_axis(axis: Axis, value: f32) void {
    const prev = device.axis(axis);
    device.set_axis(axis, value);
    _ = fb.append_event(.{ .gamepad_axis_changed = .{ .axis = axis, .value = value } }) catch return;
    if (@abs(value) > config.axis_activity_threshold) last_mode = .gamepad;

    capture_on_axis_change(.{ .gamepad_axis = axis }, prev, value);
}

pub fn deliver_focus_change(gained: bool) void {
    device.focused = gained;
    if (gained) {
        _ = fb.append_event(.focus_gained) catch return;
        if (text_session_state) |*s| {
            if (s.status == .suspended) s.status = .active;
        }
    } else {
        _ = fb.append_event(.focus_lost) catch return;
        if (text_session_state) |*s| {
            if (s.status == .active) s.status = .suspended;
        }
    }
}

/// Flip accumulator and published frame buffers; snapshot pointer state
/// into the published frame; clear the new accumulator. Called by the
/// backend at the end of each pump.
pub fn signal_frame_boundary() void {
    fb.signal_frame_boundary();
    pub_frame = .{
        .sequence = fb.frame_sequence,
        .events = fb.published_events(),
        .pointer = .{
            .position = device.pointer_position,
            .delta = device.pointer_delta_accum,
        },
    };
}

// -- per-step update (called by Engine after Platform.update) ----------------

/// Re-evaluate every action in the top context's installed set. After
/// reading device accumulators, zero them so the next frame starts clean.
pub fn update() void {
    if (stack.top()) |top| {
        if (set_ptr_or_null(top.actions)) |set| {
            if (set.installed) action_mod.evaluate_set(set, &device);
        }
    }
    device.pointer_delta_accum = .{};
    device.wheel_accum = .{};
}

// -- FrameApi -----------------------------------------------------------------

pub fn current_frame() *const InputFrame {
    return &pub_frame;
}

pub fn frame_pointer() Pointer {
    return pub_frame.pointer;
}

pub fn frame_events() []const RawEvent {
    return pub_frame.events;
}

// -- ActionApi ----------------------------------------------------------------

pub fn register_action_set(name: []const u8) !ActionSetHandle {
    try registry.append(alloc, .{ .name = name, .actions = .empty, .installed = false });
    return @enumFromInt(registry.items.len - 1);
}

pub fn add_action(set: ActionSetHandle, name: []const u8, kind: ActionKind) !void {
    const s = set_ptr(set) orelse return error.UnknownActionSet;
    if (action_ptr(s, name) != null) return error.ActionAlreadyExists;
    try s.actions.put(alloc, name, .{
        .kind = kind,
        .bindings = .empty,
        .current_value = Action.zero(kind),
        .previous_value = Action.zero(kind),
    });
}

pub fn bind_action(set: ActionSetHandle, action_name: []const u8, b: Binding) !void {
    const s = set_ptr(set) orelse return error.UnknownActionSet;
    const a = action_ptr(s, action_name) orelse return error.ActionNotFound;
    if (a.kind == .vector2 and b.component == .none) return error.Vector2BindingNeedsComponent;
    try a.bindings.append(alloc, b);
}

pub fn install_action_set(set: ActionSetHandle) !void {
    const s = set_ptr(set) orelse return error.UnknownActionSet;
    if (s.installed) return error.AlreadyInstalled;
    s.installed = true;
}

pub fn uninstall_action_set(set: ActionSetHandle) !void {
    const s = set_ptr(set) orelse return error.UnknownActionSet;
    if (!s.installed) return error.NotInstalled;
    if (stack.references(set)) return error.ActionSetInUse;
    s.installed = false;
}

pub fn get_action(name: []const u8) ?ActionValue {
    const top = stack.top() orelse return null;
    const s = set_ptr(top.actions) orelse return null;
    if (!s.installed) return null;
    const a = action_ptr(s, name) orelse return null;
    return a.current_value;
}

pub fn get_action_button(name: []const u8) ButtonState {
    return switch (get_action(name) orelse return .released) {
        .button => |b| b,
        else => .released,
    };
}

pub fn get_action_axis(name: []const u8) f32 {
    return switch (get_action(name) orelse return 0.0) {
        .axis => |v| v,
        else => 0.0,
    };
}

pub fn get_action_vector2(name: []const u8) [2]f32 {
    return switch (get_action(name) orelse return .{ 0, 0 }) {
        .vector2 => |v| v,
        else => .{ 0, 0 },
    };
}

pub fn active_action_set() ?*const ActionSet {
    const top = stack.top() orelse return null;
    return set_ptr_or_null(top.actions);
}

// -- ContextStackApi ----------------------------------------------------------

pub fn push_context(ctx: InputContext) !void {
    const s = set_ptr(ctx.actions) orelse return error.UnknownActionSet;
    if (!s.installed) return error.ActionSetNotInstalled;
    try stack.push(ctx);
}

pub fn pop_context() !InputContext {
    return try stack.pop();
}

pub fn replace_top(ctx: InputContext) !InputContext {
    const s = set_ptr(ctx.actions) orelse return error.UnknownActionSet;
    if (!s.installed) return error.ActionSetNotInstalled;
    return try stack.replace_top(ctx);
}

pub fn stack_top() ?*const InputContext {
    return stack.top();
}

pub fn stack_layers() []const InputContext {
    return stack.slice();
}

pub fn effective_cursor_mode() CursorMode {
    return context_mod.effective_cursor_mode(&stack);
}

// -- TextInputApi -------------------------------------------------------------

pub fn begin_text_input(target: TextInputTarget, options: TextInputOptions) !*TextInputSession {
    if (text_session_state) |*s| {
        if (!s.is_terminal()) return error.TextSessionInFlight;
        s.deinit(alloc);
    }
    text_session_state = .{
        .target = target,
        .options = options,
        .buffer = .empty,
        .status = .active,
    };
    if (options.initial) |seed| {
        if (seed.len > 0) {
            const limit = options.max_bytes orelse seed.len;
            const take = @min(seed.len, limit);
            try text_session_state.?.buffer.appendSlice(alloc, seed[0..take]);
        }
    }
    if (begin_text_session_hook) |h| try h(target, options);
    return &text_session_state.?;
}

pub fn submit_text() !void {
    const s = &(text_session_state orelse return error.NoActiveTextSession);
    if (s.status != .active) return error.TextSessionNotActive;
    s.status = .submitted;
    if (end_text_session_hook) |h| h();
}

pub fn cancel_text() !void {
    const s = &(text_session_state orelse return error.NoActiveTextSession);
    if (s.status != .active and s.status != .suspended) return error.TextSessionTerminal;
    s.status = .cancelled;
    if (end_text_session_hook) |h| h();
}

/// Install platform hooks for text-session begin/end. Called by
/// `Platform.input.init` once per process; passing null detaches.
pub fn set_text_session_hooks(
    begin_hook: ?*const fn (TextInputTarget, TextInputOptions) anyerror!void,
    end_hook: ?*const fn () void,
) void {
    begin_text_session_hook = begin_hook;
    end_text_session_hook = end_hook;
}

pub fn current_text_session() ?*const TextInputSession {
    if (text_session_state) |*s| return s;
    return null;
}

/// Backend hook: PSP OSK populates the buffer directly on completion. The
/// platform layer calls this in lieu of `deliver_text`.
pub fn write_text_session_buffer(text: []const u8, terminal: TextInputStatus) void {
    if (text_session_state) |*s| {
        s.buffer.clearRetainingCapacity();
        s.buffer.appendSlice(alloc, text) catch {};
        s.status = terminal;
    }
}

// -- CaptureNextInputApi ------------------------------------------------------

pub fn begin_capture_next_input(eligible: std.EnumSet(BindingSourceKind)) !void {
    if (capture_session_state) |*s| {
        if (s.status == .waiting) return error.CaptureInFlight;
        s.deinit(alloc);
    }
    var session = CaptureNextInputSession{
        .eligible_kinds = eligible,
        .held_at_start = .empty,
        .armed = .empty,
        .status = .waiting,
    };
    try snapshot_held_sources(&session);
    capture_session_state = session;
}

pub fn cancel_capture() !void {
    const s = &(capture_session_state orelse return error.NoCaptureSession);
    if (s.status != .waiting) return error.CaptureTerminal;
    s.status = .cancelled;
}

pub fn current_capture_session() ?*const CaptureNextInputSession {
    if (capture_session_state) |*s| return s;
    return null;
}

// -- last input mode ----------------------------------------------------------

pub fn last_input_mode() InputMode {
    return last_mode;
}

// -- internal helpers ---------------------------------------------------------

fn set_ptr(handle: ActionSetHandle) ?*ActionSet {
    const i = @intFromEnum(handle);
    if (i >= registry.items.len) return null;
    return &registry.items[i];
}

fn set_ptr_or_null(handle: ActionSetHandle) ?*ActionSet {
    return set_ptr(handle);
}

fn action_ptr(set: *ActionSet, name: []const u8) ?*Action {
    if (set.actions.getPtr(name)) |action| return action;

    var it = set.actions.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, name)) return entry.value_ptr;
    }
    return null;
}

fn route_text_to_session(text: []const u8) void {
    const top = stack.top() orelse return;
    if (!top.consumes_text) return;
    const s = &(text_session_state orelse return);
    if (s.status != .active) return;
    s.append(alloc, text) catch {};
}

fn snapshot_held_sources(session: *CaptureNextInputSession) !void {
    var k_it = device.keys.keyIterator();
    while (k_it.next()) |k| {
        try session.held_at_start.append(alloc, .{ .key = k.* });
    }
    var mb_it = device.mouse_buttons.iterator();
    while (mb_it.next()) |mb| {
        try session.held_at_start.append(alloc, .{ .mouse_button = mb });
    }
    var gp_it = device.gamepad_buttons.iterator();
    while (gp_it.next()) |gb| {
        try session.held_at_start.append(alloc, .{ .gamepad_button = gb });
    }
    inline for (std.meta.fields(Axis)) |f| {
        const a: Axis = @enumFromInt(f.value);
        if (@abs(device.axis(a)) > config.axis_activity_threshold) {
            try session.held_at_start.append(alloc, .{ .gamepad_axis = a });
        }
    }
}

fn capture_on_down(src: BindingSource, mods: ModifierSet, is_repeat: bool) void {
    if (is_repeat) return;
    const s = &(capture_session_state orelse return);
    if (s.status != .waiting) return;
    if (!s.eligible_kinds.contains(@as(BindingSourceKind, src))) return;
    if (!capture_session_mod.eligible_to_complete(s, src)) return;
    s.result = .{ .source = src, .modifiers = mods };
    s.result.display_len = capture_session_mod.format_label(&s.result.display_buf, src, mods);
    s.status = .captured;
}

fn capture_on_release(src: BindingSource) void {
    const s = &(capture_session_state orelse return);
    if (s.status != .waiting) return;
    capture_session_mod.arm_on_release(s, alloc, src) catch {};
}

fn capture_on_axis_change(src: BindingSource, prev: f32, now: f32) void {
    const s = &(capture_session_state orelse return);
    if (s.status != .waiting) return;
    const t = config.axis_activity_threshold;
    const was_active = @abs(prev) > t;
    const now_active = @abs(now) > t;
    if (was_active and !now_active) {
        capture_session_mod.arm_on_release(s, alloc, src) catch {};
    } else if (!was_active and now_active) {
        if (!s.eligible_kinds.contains(@as(BindingSourceKind, src))) return;
        if (!capture_session_mod.eligible_to_complete(s, src)) return;
        s.result = .{ .source = src, .modifiers = current_modifiers };
        s.result.display_len = capture_session_mod.format_label(&s.result.display_buf, src, current_modifiers);
        s.status = .captured;
    }
}

// -- compile-time validation -------------------------------------------------

comptime {
    std.testing.refAllDecls(@This());
}

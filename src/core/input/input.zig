//! Public input system entry point. Defines the input state container and
//! exposes the five surfaces from spec/input.allium:
//! FrameApi, ActionApi, ContextStackApi, TextInputApi, CaptureNextInputApi.
//!
//! Backends call the `deliver_*` and `signal_frame_boundary` methods on the
//! engine-owned `InputSystem`. Game code should treat those methods as
//! backend-internal.

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
pub const ActionHandle = action_mod.ActionHandle;
pub const ButtonQuery = action_mod.ButtonQuery;
pub const AxisQuery = action_mod.AxisQuery;
pub const Vector2Query = action_mod.Vector2Query;

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

pub const InitError = error{
    OutOfMemory,
    ContextStackFull,
};

pub const ActionSetError = error{
    OutOfMemory,
    UnknownActionSet,
    ActionAlreadyExists,
    ActionNotFound,
    Vector2BindingNeedsComponent,
    AlreadyInstalled,
    NotInstalled,
    ActionSetInUse,
};

pub const ContextError = error{
    UnknownActionSet,
    ActionSetNotInstalled,
    ContextStackFull,
    ContextStackBaseProtected,
    ContextStackEmpty,
};

pub const TextSessionError = error{
    OutOfMemory,
    TextSessionInFlight,
    NoActiveTextSession,
    TextSessionNotActive,
    TextSessionTerminal,
    NoCurrentApplication,
    GraphicsNotInitialized,
};

pub const CaptureError = error{
    OutOfMemory,
    CaptureInFlight,
    NoCaptureSession,
    CaptureTerminal,
};

const base_set_name = "__base";

pub const TextSessionBeginHook = *const fn (*InputSystem, *const TextInputTarget, *const TextInputOptions) TextSessionError!void;
pub const TextSessionEndHook = *const fn (*InputSystem) void;

pub const InputSystem = struct {
    alloc: std.mem.Allocator = undefined,
    fb: frame.FrameBuffer = undefined,
    device: action_mod.DeviceState = .{},
    pub_frame: InputFrame = .{},
    registry: std.ArrayList(ActionSet) = .empty,
    stack: ContextStack = .{},
    text_session_state: ?TextInputSession = null,
    capture_session_state: ?CaptureNextInputSession = null,
    current_modifiers: ModifierSet = .{},
    last_mode: InputMode = .keyboard_mouse,
    initialised: bool = false,
    begin_text_session_hook: ?TextSessionBeginHook = null,
    end_text_session_hook: ?TextSessionEndHook = null,

    // -- lifecycle ------------------------------------------------------------

    /// Initialise the input system. Called by `Engine.init`.
    pub fn init(self: *InputSystem, allocator: std.mem.Allocator) InitError!void {
        self.alloc = allocator;
        self.fb = frame.FrameBuffer.init(allocator);
        self.device = .{};
        self.registry = .empty;
        self.stack = .{};
        self.text_session_state = null;
        self.capture_session_state = null;
        self.current_modifiers = .{};
        self.last_mode = .keyboard_mouse;
        self.pub_frame = .{};
        self.begin_text_session_hook = null;
        self.end_text_session_hook = null;

        // Seed an installed empty base set so the stack always has a top.
        const base_handle = self.register_action_set(base_set_name) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("input init: unexpected base action set registration error: {s}", .{@errorName(err)}),
        };
        self.install_action_set(base_handle) catch |err| {
            std.debug.panic("input init: unexpected base action set install error: {s}", .{@errorName(err)});
        };
        try self.stack.push(.{
            .name = "base",
            .cursor_mode = .visible,
            .actions = base_handle,
            .consumes_text = false,
            .consumes_pointer = true,
        });

        self.initialised = true;
    }

    pub fn deinit(self: *InputSystem) void {
        if (!self.initialised) return;
        self.initialised = false;

        if (self.text_session_state) |*s| s.deinit(self.alloc);
        self.text_session_state = null;
        if (self.capture_session_state) |*s| s.deinit(self.alloc);
        self.capture_session_state = null;

        for (self.registry.items) |*set| {
            for (set.actions.keys(), set.actions.values()) |name, *action| {
                action.bindings.deinit(self.alloc);
                self.alloc.free(name);
            }
            set.actions.deinit(self.alloc);
            self.alloc.free(set.name);
        }
        self.registry.deinit(self.alloc);

        self.device.deinit(self.alloc);
        self.fb.deinit();
        self.stack = .{};
        self.begin_text_session_hook = null;
        self.end_text_session_hook = null;
    }

    // -- platform-facing entry points ----------------------------------------

    pub fn deliver_key_down(self: *InputSystem, key: Key, mods: ModifierSet, is_repeat: bool) void {
        self.current_modifiers = mods;
        if (!is_repeat) _ = self.device.keys.put(self.alloc, key, {}) catch return;
        _ = self.fb.append_event(.{ .key_down = .{ .key = key, .modifiers = mods, .is_repeat = is_repeat } }) catch return;
        self.last_mode = .keyboard_mouse;
        self.capture_on_down(.{ .key = key }, mods, is_repeat);
    }

    pub fn deliver_key_up(self: *InputSystem, key: Key, mods: ModifierSet) void {
        self.current_modifiers = mods;
        _ = self.device.keys.remove(key);
        _ = self.fb.append_event(.{ .key_up = .{ .key = key, .modifiers = mods } }) catch return;
        self.capture_on_release(.{ .key = key });
    }

    pub fn deliver_text(self: *InputSystem, text: []const u8) void {
        const interned = self.fb.intern_text(text) catch return;
        _ = self.fb.append_event(.{ .text_utf8 = .{ .text = interned } }) catch return;
        self.route_text_to_session(interned);
        self.last_mode = .keyboard_mouse;
    }

    pub fn deliver_mouse_button(self: *InputSystem, mouse_button: MouseButton, edge: ButtonState, position: Vec2) void {
        self.device.pointer_position = position;
        if (edge == .pressed) {
            self.device.mouse_buttons.insert(mouse_button);
            _ = self.fb.append_event(.{ .mouse_button_down = .{ .button = mouse_button, .position = position } }) catch return;
            self.capture_on_down(.{ .mouse_button = mouse_button }, self.current_modifiers, false);
        } else {
            self.device.mouse_buttons.remove(mouse_button);
            _ = self.fb.append_event(.{ .mouse_button_up = .{ .button = mouse_button, .position = position } }) catch return;
            self.capture_on_release(.{ .mouse_button = mouse_button });
        }
        self.last_mode = .keyboard_mouse;
    }

    pub fn deliver_mouse_move(self: *InputSystem, position: Vec2, delta: Vec2) void {
        self.device.pointer_position = position;
        self.device.pointer_delta_accum.x += delta.x;
        self.device.pointer_delta_accum.y += delta.y;
        _ = self.fb.append_event(.{ .mouse_move_abs = .{ .position = position } }) catch {};
        if (delta.x != 0 or delta.y != 0) {
            _ = self.fb.append_event(.{ .mouse_move_rel = .{ .delta = delta } }) catch {};
            self.last_mode = .keyboard_mouse;
        }
    }

    pub fn deliver_mouse_wheel(self: *InputSystem, delta: Vec2) void {
        self.device.wheel_accum.x += delta.x;
        self.device.wheel_accum.y += delta.y;
        _ = self.fb.append_event(.{ .mouse_wheel = .{ .delta = delta } }) catch return;
        if (delta.x != 0 or delta.y != 0) self.last_mode = .keyboard_mouse;
    }

    pub fn deliver_gamepad_button(self: *InputSystem, gamepad_button: Button, edge: ButtonState) void {
        if (edge == .pressed) {
            self.device.gamepad_buttons.insert(gamepad_button);
            _ = self.fb.append_event(.{ .gamepad_button_down = .{ .button = gamepad_button } }) catch return;
            self.last_mode = .gamepad;
            self.capture_on_down(.{ .gamepad_button = gamepad_button }, self.current_modifiers, false);
        } else {
            self.device.gamepad_buttons.remove(gamepad_button);
            _ = self.fb.append_event(.{ .gamepad_button_up = .{ .button = gamepad_button } }) catch return;
            self.capture_on_release(.{ .gamepad_button = gamepad_button });
        }
    }

    pub fn deliver_gamepad_axis(self: *InputSystem, gamepad_axis: Axis, value: f32) void {
        const prev = self.device.axis(gamepad_axis);
        self.device.set_axis(gamepad_axis, value);
        _ = self.fb.append_event(.{ .gamepad_axis_changed = .{ .axis = gamepad_axis, .value = value } }) catch return;
        if (@abs(value) > config.axis_activity_threshold) self.last_mode = .gamepad;

        self.capture_on_axis_change(.{ .gamepad_axis = gamepad_axis }, prev, value);
    }

    pub fn deliver_focus_change(self: *InputSystem, gained: bool) void {
        self.device.focused = gained;
        if (gained) {
            _ = self.fb.append_event(.focus_gained) catch return;
            if (self.text_session_state) |*s| {
                if (s.status == .suspended) s.status = .active;
            }
        } else {
            _ = self.fb.append_event(.focus_lost) catch return;
            if (self.text_session_state) |*s| {
                if (s.status == .active) s.status = .suspended;
            }
        }
    }

    /// Flip accumulator and published frame buffers; snapshot pointer state
    /// into the published frame; clear the new accumulator. Called by the
    /// backend at the end of each pump.
    pub fn signal_frame_boundary(self: *InputSystem) void {
        self.fb.signal_frame_boundary();
        self.pub_frame = .{
            .sequence = self.fb.frame_sequence,
            .events = self.fb.published_events(),
            .pointer = .{
                .position = self.device.pointer_position,
                .delta = self.device.pointer_delta_accum,
            },
        };
    }

    // -- per-step update (called by Engine after Platform.update) ------------

    /// Re-evaluate every action in the top context's installed set. After
    /// reading device accumulators, zero them so the next frame starts clean.
    pub fn update(self: *InputSystem) void {
        if (self.stack.top()) |top| {
            if (self.set_ptr(top.actions)) |set| {
                if (set.installed) action_mod.evaluate_set(set, &self.device);
            }
        }
        self.device.pointer_delta_accum = .{};
        self.device.wheel_accum = .{};
    }

    // -- FrameApi -------------------------------------------------------------

    pub fn current_frame(self: *const InputSystem) *const InputFrame {
        return &self.pub_frame;
    }

    pub fn frame_pointer(self: *const InputSystem) Pointer {
        return self.pub_frame.pointer;
    }

    pub fn frame_events(self: *const InputSystem) []const RawEvent {
        return self.pub_frame.events;
    }

    // -- ActionApi ------------------------------------------------------------

    pub fn register_action_set(self: *InputSystem, name: []const u8) ActionSetError!ActionSetHandle {
        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        try self.registry.append(self.alloc, .{ .name = owned_name, .actions = .empty, .installed = false });
        return @enumFromInt(self.registry.items.len - 1);
    }

    pub fn add_action(self: *InputSystem, set: ActionSetHandle, name: []const u8, kind: ActionKind) ActionSetError!ActionHandle {
        const s = self.set_ptr(set) orelse return error.UnknownActionSet;
        if (s.actions.getIndex(name) != null) return error.ActionAlreadyExists;

        const owned_name = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(owned_name);
        try s.actions.put(self.alloc, owned_name, .{
            .kind = kind,
            .bindings = .empty,
            .current_value = Action.zero(kind),
            .previous_value = Action.zero(kind),
        });
        return ActionHandle.from_parts(set, s.actions.count() - 1);
    }

    pub fn bind_action(self: *InputSystem, action: ActionHandle, b: *const Binding) ActionSetError!void {
        const a = self.action_ptr(action) orelse return error.ActionNotFound;
        if (a.kind == .vector2 and b.component == .none) return error.Vector2BindingNeedsComponent;
        try a.bindings.append(self.alloc, b.*);
    }

    pub fn install_action_set(self: *InputSystem, set: ActionSetHandle) ActionSetError!void {
        const s = self.set_ptr(set) orelse return error.UnknownActionSet;
        if (s.installed) return error.AlreadyInstalled;
        s.installed = true;
    }

    pub fn uninstall_action_set(self: *InputSystem, set: ActionSetHandle) ActionSetError!void {
        const s = self.set_ptr(set) orelse return error.UnknownActionSet;
        if (!s.installed) return error.NotInstalled;
        if (self.stack.references(set)) return error.ActionSetInUse;
        s.installed = false;
    }

    pub fn find_action(self: *InputSystem, set: ActionSetHandle, name: []const u8) ?ActionHandle {
        const s = self.set_ptr(set) orelse return null;
        const index = s.actions.getIndex(name) orelse return null;
        return ActionHandle.from_parts(set, index);
    }

    pub fn action_name(self: *InputSystem, action: ActionHandle) ?[]const u8 {
        const s = self.set_ptr(action.set()) orelse return null;
        if (action.action_index >= s.actions.count()) return null;
        return s.actions.keys()[action.action_index];
    }

    pub fn action_kind(self: *InputSystem, action: ActionHandle) ?ActionKind {
        const a = self.action_ptr(action) orelse return null;
        return a.kind;
    }

    pub fn get_action(self: *InputSystem, action: ActionHandle) ?ActionValue {
        const a = self.active_action_ptr(action) orelse return null;
        return a.current_value;
    }

    pub fn button(self: *InputSystem, action: ActionHandle) ButtonQuery {
        const a = self.active_action_ptr(action) orelse return .{};
        if (a.kind != .button) return .{};
        return .{
            .current = a.current_value.button,
            .previous = a.previous_value.button,
        };
    }

    pub fn axis(self: *InputSystem, action: ActionHandle) AxisQuery {
        const a = self.active_action_ptr(action) orelse return .{};
        if (a.kind != .axis) return .{};
        return .{
            .current = a.current_value.axis,
            .previous = a.previous_value.axis,
        };
    }

    pub fn vector2(self: *InputSystem, action: ActionHandle) Vector2Query {
        const a = self.active_action_ptr(action) orelse return .{};
        if (a.kind != .vector2) return .{};
        return .{
            .current = a.current_value.vector2,
            .previous = a.previous_value.vector2,
        };
    }

    pub fn active_action_set(self: *InputSystem) ?ActionSetHandle {
        const top = self.stack.top() orelse return null;
        const s = self.set_ptr(top.actions) orelse return null;
        if (!s.installed) return null;
        return top.actions;
    }

    // -- ContextStackApi ------------------------------------------------------

    pub fn push_context(self: *InputSystem, ctx: *const InputContext) ContextError!void {
        const s = self.set_ptr(ctx.actions) orelse return error.UnknownActionSet;
        if (!s.installed) return error.ActionSetNotInstalled;
        action_mod.sync_set(s, &self.device);
        try self.stack.push(ctx.*);
    }

    pub fn pop_context(self: *InputSystem) ContextError!InputContext {
        return try self.stack.pop();
    }

    pub fn replace_top(self: *InputSystem, ctx: *const InputContext) ContextError!InputContext {
        const s = self.set_ptr(ctx.actions) orelse return error.UnknownActionSet;
        if (!s.installed) return error.ActionSetNotInstalled;
        action_mod.sync_set(s, &self.device);
        return try self.stack.replace_top(ctx.*);
    }

    pub fn stack_top(self: *const InputSystem) ?*const InputContext {
        return self.stack.top();
    }

    pub fn stack_layers(self: *const InputSystem) []const InputContext {
        return self.stack.slice();
    }

    pub fn effective_cursor_mode(self: *const InputSystem) CursorMode {
        return context_mod.effective_cursor_mode(&self.stack);
    }

    // -- TextInputApi ---------------------------------------------------------

    pub fn begin_text_input(self: *InputSystem, target: *const TextInputTarget, options: *const TextInputOptions) TextSessionError!*TextInputSession {
        if (self.text_session_state) |*s| {
            if (!s.is_terminal()) return error.TextSessionInFlight;
            s.deinit(self.alloc);
        }
        self.text_session_state = .{
            .target = target.*,
            .options = options.*,
            .buffer = .empty,
            .status = .active,
        };
        if (options.initial) |seed| {
            if (seed.len > 0) {
                const limit = options.max_bytes orelse seed.len;
                const take = @min(seed.len, limit);
                try self.text_session_state.?.buffer.appendSlice(self.alloc, seed[0..take]);
            }
        }
        if (self.begin_text_session_hook) |h| try h(self, target, options);
        return &self.text_session_state.?;
    }

    pub fn submit_text(self: *InputSystem) TextSessionError!void {
        const s = &(self.text_session_state orelse return error.NoActiveTextSession);
        if (s.status != .active) return error.TextSessionNotActive;
        s.status = .submitted;
        if (self.end_text_session_hook) |h| h(self);
    }

    pub fn cancel_text(self: *InputSystem) TextSessionError!void {
        const s = &(self.text_session_state orelse return error.NoActiveTextSession);
        if (s.status != .active and s.status != .suspended) return error.TextSessionTerminal;
        s.status = .cancelled;
        if (self.end_text_session_hook) |h| h(self);
    }

    /// Install platform hooks for text-session begin/end. Called by
    /// `Platform.input.init` once per process; passing null detaches.
    pub fn set_text_session_hooks(
        self: *InputSystem,
        begin_hook: ?TextSessionBeginHook,
        end_hook: ?TextSessionEndHook,
    ) void {
        self.begin_text_session_hook = begin_hook;
        self.end_text_session_hook = end_hook;
    }

    pub fn current_text_session(self: *InputSystem) ?*const TextInputSession {
        if (self.text_session_state) |*s| return s;
        return null;
    }

    /// Backend hook: system OSKs populate the buffer directly on completion.
    /// The platform layer calls this in lieu of `deliver_text`.
    pub fn write_text_session_buffer(self: *InputSystem, text: []const u8, terminal: TextInputStatus) void {
        if (self.text_session_state) |*s| {
            s.buffer.clearRetainingCapacity();
            s.buffer.appendSlice(self.alloc, text) catch {};
            s.status = terminal;
        }
    }

    // -- CaptureNextInputApi --------------------------------------------------

    pub fn begin_capture_next_input(self: *InputSystem, eligible: std.EnumSet(BindingSourceKind)) CaptureError!void {
        if (self.capture_session_state) |*s| {
            if (s.status == .waiting) return error.CaptureInFlight;
            s.deinit(self.alloc);
        }
        var session = CaptureNextInputSession{
            .eligible_kinds = eligible,
            .held_at_start = .empty,
            .armed = .empty,
            .status = .waiting,
        };
        try self.snapshot_held_sources(&session);
        self.capture_session_state = session;
    }

    pub fn cancel_capture(self: *InputSystem) CaptureError!void {
        const s = &(self.capture_session_state orelse return error.NoCaptureSession);
        if (s.status != .waiting) return error.CaptureTerminal;
        s.status = .cancelled;
    }

    pub fn current_capture_session(self: *InputSystem) ?*const CaptureNextInputSession {
        if (self.capture_session_state) |*s| return s;
        return null;
    }

    // -- last input mode ------------------------------------------------------

    pub fn last_input_mode(self: *const InputSystem) InputMode {
        return self.last_mode;
    }

    // -- internal helpers -----------------------------------------------------

    fn set_ptr(self: *InputSystem, handle: ActionSetHandle) ?*ActionSet {
        const i = @intFromEnum(handle);
        if (i >= self.registry.items.len) return null;
        return &self.registry.items[i];
    }

    fn action_ptr(self: *InputSystem, action: ActionHandle) ?*Action {
        if (action.is_null()) return null;
        const set = self.set_ptr(action.set()) orelse return null;
        if (action.action_index >= set.actions.count()) return null;
        return &set.actions.values()[action.action_index];
    }

    fn active_action_ptr(self: *InputSystem, action: ActionHandle) ?*Action {
        if (action.is_null()) return null;
        const top = self.stack.top() orelse return null;
        if (@intFromEnum(top.actions) != action.set_index) return null;
        const set = self.set_ptr(top.actions) orelse return null;
        if (!set.installed) return null;
        if (action.action_index >= set.actions.count()) return null;
        return &set.actions.values()[action.action_index];
    }

    fn route_text_to_session(self: *InputSystem, text: []const u8) void {
        const top = self.stack.top() orelse return;
        if (!top.consumes_text) return;
        const s = &(self.text_session_state orelse return);
        if (s.status != .active) return;
        s.append(self.alloc, text) catch {};
    }

    fn snapshot_held_sources(self: *InputSystem, session: *CaptureNextInputSession) !void {
        var k_it = self.device.keys.keyIterator();
        while (k_it.next()) |k| {
            try session.held_at_start.append(self.alloc, .{ .key = k.* });
        }
        var mb_it = self.device.mouse_buttons.iterator();
        while (mb_it.next()) |mb| {
            try session.held_at_start.append(self.alloc, .{ .mouse_button = mb });
        }
        var gp_it = self.device.gamepad_buttons.iterator();
        while (gp_it.next()) |gb| {
            try session.held_at_start.append(self.alloc, .{ .gamepad_button = gb });
        }
        inline for (std.meta.fields(Axis)) |f| {
            const a: Axis = @enumFromInt(f.value);
            if (@abs(self.device.axis(a)) > config.axis_activity_threshold) {
                try session.held_at_start.append(self.alloc, .{ .gamepad_axis = a });
            }
        }
    }

    fn capture_on_down(self: *InputSystem, src: BindingSource, mods: ModifierSet, is_repeat: bool) void {
        if (is_repeat) return;
        const s = &(self.capture_session_state orelse return);
        if (s.status != .waiting) return;
        if (!s.eligible_kinds.contains(@as(BindingSourceKind, src))) return;
        if (!capture_session_mod.eligible_to_complete(s, src)) return;
        s.result = .{ .source = src, .modifiers = mods };
        s.result.display_len = capture_session_mod.format_label(&s.result.display_buf, src, mods);
        s.status = .captured;
    }

    fn capture_on_release(self: *InputSystem, src: BindingSource) void {
        const s = &(self.capture_session_state orelse return);
        if (s.status != .waiting) return;
        capture_session_mod.arm_on_release(s, self.alloc, src) catch {};
    }

    fn capture_on_axis_change(self: *InputSystem, src: BindingSource, prev: f32, now: f32) void {
        const s = &(self.capture_session_state orelse return);
        if (s.status != .waiting) return;
        const t = config.axis_activity_threshold;
        const was_active = @abs(prev) > t;
        const now_active = @abs(now) > t;
        if (was_active and !now_active) {
            capture_session_mod.arm_on_release(s, self.alloc, src) catch {};
        } else if (!was_active and now_active) {
            if (!s.eligible_kinds.contains(@as(BindingSourceKind, src))) return;
            if (!capture_session_mod.eligible_to_complete(s, src)) return;
            s.result = .{ .source = src, .modifiers = self.current_modifiers };
            s.result.display_len = capture_session_mod.format_label(&s.result.display_buf, src, self.current_modifiers);
            s.status = .captured;
        }
    }
};

test "action handles drive button edges" {
    var input = InputSystem{};
    try input.init(std.testing.allocator);
    defer input.deinit();

    const gameplay = try input.register_action_set("gameplay");
    const jump = try input.add_action(gameplay, "jump", .button);
    try input.bind_action(jump, &.{ .source = .{ .key = .Space } });
    try input.install_action_set(gameplay);
    try input.push_context(&.{
        .name = "gameplay",
        .cursor_mode = .visible,
        .actions = gameplay,
    });

    try std.testing.expectEqualStrings("jump", input.action_name(jump).?);
    try std.testing.expectEqual(ActionKind.button, input.action_kind(jump).?);
    try std.testing.expectEqual(jump, input.find_action(gameplay, "jump").?);
    try std.testing.expect(!input.button(jump).down());

    input.deliver_key_down(.Space, .{}, false);
    input.update();
    try std.testing.expect(input.button(jump).down());
    try std.testing.expect(input.button(jump).pressed());
    try std.testing.expect(!input.button(jump).released());

    input.update();
    try std.testing.expect(input.button(jump).down());
    try std.testing.expect(!input.button(jump).pressed());

    input.deliver_key_up(.Space, .{});
    input.update();
    try std.testing.expect(!input.button(jump).down());
    try std.testing.expect(input.button(jump).released());
}

test "action handles are neutral outside active context" {
    var input = InputSystem{};
    try input.init(std.testing.allocator);
    defer input.deinit();

    const gameplay = try input.register_action_set("gameplay");
    const menu = try input.register_action_set("menu");
    const jump = try input.add_action(gameplay, "jump", .button);
    const confirm = try input.add_action(menu, "confirm", .button);
    try input.bind_action(jump, &.{ .source = .{ .key = .Space } });
    try input.bind_action(confirm, &.{ .source = .{ .key = .Enter } });
    try input.install_action_set(gameplay);
    try input.install_action_set(menu);

    try input.push_context(&.{
        .name = "gameplay",
        .cursor_mode = .visible,
        .actions = gameplay,
    });

    input.deliver_key_down(.Enter, .{}, false);
    input.update();
    try std.testing.expect(!input.button(confirm).down());
    try std.testing.expect(!input.button(ActionHandle.none).down());

    try input.push_context(&.{
        .name = "menu",
        .cursor_mode = .visible,
        .actions = menu,
    });
    try std.testing.expect(!input.button(confirm).pressed());
    try std.testing.expect(input.button(confirm).down());
    try std.testing.expect(!input.button(jump).down());
}

test "axis and vector2 handles report values and deltas" {
    var input = InputSystem{};
    try input.init(std.testing.allocator);
    defer input.deinit();

    const gameplay = try input.register_action_set("gameplay");
    const throttle = try input.add_action(gameplay, "throttle", .axis);
    const move = try input.add_action(gameplay, "move", .vector2);
    try input.bind_action(throttle, &.{ .source = .{ .gamepad_axis = .RightTrigger }, .deadzone = 0.0 });
    try input.bind_action(move, &.{ .source = .{ .key = .D }, .component = .x });
    try input.bind_action(move, &.{ .source = .{ .key = .W }, .component = .y });
    try input.install_action_set(gameplay);
    try input.push_context(&.{
        .name = "gameplay",
        .cursor_mode = .visible,
        .actions = gameplay,
    });

    input.deliver_gamepad_axis(.RightTrigger, 0.25);
    input.deliver_key_down(.D, .{}, false);
    input.update();

    try std.testing.expectEqual(@as(f32, 0.25), input.axis(throttle).value());
    try std.testing.expectEqual(@as(f32, 0.25), input.axis(throttle).delta());
    try std.testing.expectEqual([2]f32{ 1.0, 0.0 }, input.vector2(move).value());
    try std.testing.expectEqual([2]f32{ 1.0, 0.0 }, input.vector2(move).delta());
}

test "input systems keep device and action state independent" {
    var first = InputSystem{};
    var second = InputSystem{};
    try first.init(std.testing.allocator);
    defer first.deinit();
    try second.init(std.testing.allocator);
    defer second.deinit();

    const first_set = try first.register_action_set("gameplay");
    const second_set = try second.register_action_set("gameplay");
    const first_jump = try first.add_action(first_set, "jump", .button);
    const second_jump = try second.add_action(second_set, "jump", .button);
    try first.bind_action(first_jump, &.{ .source = .{ .key = .Space } });
    try second.bind_action(second_jump, &.{ .source = .{ .key = .Space } });
    try first.install_action_set(first_set);
    try second.install_action_set(second_set);
    try first.push_context(&.{ .name = "first", .cursor_mode = .visible, .actions = first_set });
    try second.push_context(&.{ .name = "second", .cursor_mode = .visible, .actions = second_set });

    first.deliver_key_down(.Space, .{}, false);
    first.update();
    second.update();

    try std.testing.expect(first.button(first_jump).pressed());
    try std.testing.expect(!second.button(second_jump).down());
}

// -- compile-time validation -------------------------------------------------

comptime {
    std.testing.refAllDecls(@This());
}

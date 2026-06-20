//! 3DS audio backend -- CSND with software mixing.
//!
//! CSND is driven through Zitrus' `ChannelSound` service. Aether mixes the
//! public slot API into a looping linear-memory PCM16 ring and keeps refilling
//! small pages ahead of the play cursor.

const std = @import("std");
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const thread_mod = @import("../../util/thread.zig");
const Stream = @import("../../audio/stream.zig").Stream;
const PcmFormat = @import("../../audio/stream.zig").PcmFormat;

const horizon = zitrus.horizon;
const hardware = zitrus.hardware;
const csnd_hw = hardware.csnd;
const ChannelSound = horizon.services.ChannelSound;
const Thread = thread_mod.Thread;

const DEVICE_SAMPLE_RATE: u32 = 44_100;
const DEVICE_CHANNELS: usize = 1;
const NUM_SLOTS: usize = 16;
const SAMPLES_PER_PAGE: usize = 512;
const RING_PAGE_COUNT: usize = 8;
const LEAD_PAGE_COUNT: usize = 4;
const OUTPUT_PAGE_BYTES: usize = SAMPLES_PER_PAGE * DEVICE_CHANNELS * @sizeOf(i16);
const TOTAL_OUTPUT_BYTES: usize = OUTPUT_PAGE_BYTES * RING_PAGE_COUNT;
const RING_SAMPLES: usize = SAMPLES_PER_PAGE * RING_PAGE_COUNT;
const PAGE_NS: u64 = (@as(u64, SAMPLES_PER_PAGE) * std.time.ns_per_s) / DEVICE_SAMPLE_RATE;
const FP_ONE: u64 = 1 << 32;

const COMMAND_BLOCK_SIZE: u32 = 0x2000;
const STATUS_DSP_OFFSET: u32 = COMMAND_BLOCK_SIZE;
const STATUS_CHANNEL_OFFSET: u32 = STATUS_DSP_OFFSET + 8;
const STATUS_CAPTURE_OFFSET: u32 = STATUS_CHANNEL_OFFSET + 12 * 32;
const STATUS_EXTRA_OFFSET: u32 = STATUS_CAPTURE_OFFSET + 8 * 2;
const SHM_SIZE: usize = std.mem.alignForward(usize, STATUS_EXTRA_OFFSET + 0x3c, horizon.heap.page_size);
const COMMAND_OFFSET: u32 = 0;
const COMMAND_NONE: i16 = -1;

const ChannelId = enum(u8) {
    _,

    fn init(value: u5) ChannelId {
        return @enumFromInt(@as(u8, value));
    }
};

const SlotState = enum(u8) {
    inactive = 0,
    pending = 1,
    active = 2,
    finished = 3,
};

const Slot = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(SlotState.inactive)),
    gain: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0))),
    pan: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0))),
    stream: Stream = undefined,
    format: PcmFormat = .{ .sample_rate = DEVICE_SAMPLE_RATE, .channels = 1, .bit_depth = 16 },
    step_fp: u64 = FP_ONE,
    phase_fp: u64 = 0,
    current_left: i16 = 0,
    current_right: i16 = 0,
};

var slots: [NUM_SLOTS]Slot = init_slots();
var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;
var snd: ?ChannelSound = null;
var snd_mutex: horizon.Object = .none;
var snd_shm_block: horizon.MemoryBlock = .none;
var snd_shm: ?[]align(horizon.heap.page_size) u8 = null;
var output_data: ?[]align(horizon.heap.page_size) u8 = null;
var channel: ChannelId = .init(0);
var audio_thread: ?Thread = null;
var running: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var applet_suspended: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var stream_started: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var initialized = false;

fn init_slots() [NUM_SLOTS]Slot {
    var s: [NUM_SLOTS]Slot = undefined;
    for (&s) |*slot| {
        slot.* = .{};
    }
    return s;
}

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
}

pub fn init() anyerror!void {
    _ = audio_io;

    const app = app_3ds.currentApplication() orelse std.debug.panic("3DS audio init failed: no current application", .{});

    snd = ChannelSound.open(app.srv) catch |err| return init_failed("open csnd:SND", err);
    errdefer {
        snd.?.close();
        snd = null;
    }

    const shm_ptr = horizon.heap.allocShared(SHM_SIZE);
    const shm_slice = shm_ptr[0..SHM_SIZE];

    const init_handles = send_initialize(snd.?) catch |err| return init_failed("initialize CSND", err);
    snd_mutex = @bitCast(init_handles.mutex);
    snd_shm_block = init_handles.shared_memory;
    errdefer {
        snd_shm_block.close();
        snd_shm_block = .none;
        snd_mutex.close();
        snd_mutex = .none;
    }

    snd_shm_block.map(shm_ptr, .rw, .dont_care) catch |err| return init_failed("map CSND shared memory", err);
    errdefer snd_shm_block.unmap(shm_ptr);
    @memset(shm_slice, 0);
    snd_shm = shm_slice;

    const mask = send_acquire_channels(snd.?) catch |err| return init_failed("acquire CSND channels", err);
    channel = choose_channel(mask) orelse {
        std.debug.panic("3DS audio init failed: no CSND channel available, mask=0x{x:0>8}", .{mask});
    };
    errdefer snd.?.sendReleaseSoundChannels() catch {};

    output_data = horizon.heap.linear_page_allocator.alignedAlloc(
        u8,
        .fromByteUnits(horizon.heap.page_size),
        TOTAL_OUTPUT_BYTES,
    ) catch |err| return init_failed("allocate CSND output buffer", err);
    errdefer {
        horizon.heap.linear_page_allocator.free(output_data.?);
        output_data = null;
    }
    @memset(output_data.?, 0);
    flush_output();
    stream_started.store(0, .release);

    running.store(1, .release);
    audio_thread = Thread.spawn(
        .{ .allocator = audio_alloc, .name = "aether_audio", .priority = .high, .stack_size = 24 * 1024 },
        audio_thread_fn,
        .{},
    ) catch |err| return init_failed("start audio thread", err);

    initialized = true;
}

fn init_failed(comptime stage: []const u8, err: anyerror) anyerror {
    std.log.err("3DS audio init failed at {s}: {s}", .{ stage, @errorName(err) });
    return err;
}

pub fn deinit() void {
    if (!initialized and snd == null) return;

    running.store(0, .release);
    if (audio_thread) |thread| {
        thread.join();
        audio_thread = null;
    }

    stop_channel();

    if (snd) |sound| {
        sound.sendReleaseSoundChannels() catch {};
        sound.sendShutdown() catch {};
        sound.close();
        snd = null;
    }

    if (snd_shm) |shm| {
        snd_shm_block.unmap(shm.ptr);
        snd_shm = null;
    }
    if (object_is_valid(snd_shm_block.obj)) {
        snd_shm_block.close();
        snd_shm_block = .none;
    }
    if (object_is_valid(snd_mutex)) {
        snd_mutex.close();
        snd_mutex = .none;
    }

    if (output_data) |data| {
        horizon.heap.linear_page_allocator.free(data);
        output_data = null;
    }

    for (&slots) |*slot| {
        slot.state.store(@intFromEnum(SlotState.inactive), .release);
    }

    initialized = false;
}

pub fn suspend_for_applet() void {
    if (!initialized) return;
    applet_suspended.store(1, .release);
    stop_channel();
}

pub fn resume_from_applet() void {
    if (!initialized) return;
    applet_suspended.store(0, .release);
}

pub fn update() void {}

pub fn max_voices() u32 {
    return NUM_SLOTS;
}

pub fn play_slot(slot: u8, stream: Stream) anyerror!void {
    if (slot >= NUM_SLOTS) return error.InvalidArgs;
    if (!format_supported(stream.format)) return error.UnsupportedFormat;

    const i: usize = slot;
    slots[i].stream = stream;
    slots[i].format = stream.format;
    slots[i].step_fp = (@as(u64, stream.format.sample_rate) << 32) / DEVICE_SAMPLE_RATE;
    slots[i].phase_fp = 0;
    slots[i].current_left = 0;
    slots[i].current_right = 0;
    slots[i].state.store(@intFromEnum(SlotState.pending), .release);
}

pub fn stop_slot(slot: u8) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].state.store(@intFromEnum(SlotState.inactive), .release);
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].gain.store(@bitCast(gain), .release);
    slots[slot].pan.store(@bitCast(pan), .release);
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= NUM_SLOTS) return false;
    const state: SlotState = @enumFromInt(slots[slot].state.load(.acquire));
    return state != .inactive and state != .finished;
}

fn audio_thread_fn() void {
    var next_page: usize = 0;
    var written_samples: u64 = 0;
    var start_ns: u96 = 0;
    const lead_target_samples: u64 = SAMPLES_PER_PAGE * LEAD_PAGE_COUNT;
    const sleep_ns: i64 = @intCast(@max(PAGE_NS / 4, @as(u64, std.time.ns_per_ms)));

    while (running.load(.acquire) != 0) {
        if (applet_suspended.load(.acquire) != 0) {
            next_page = 0;
            written_samples = 0;
            horizon.sleepThread(std.time.ns_per_ms);
            continue;
        }

        if (stream_started.load(.acquire) == 0) {
            const data = output_data orelse std.debug.panic("3DS audio thread lost output buffer before start", .{});
            @memset(data, 0);
            for (0..RING_PAGE_COUNT) |page| {
                fill_output_page(page);
            }
            start_looping_output() catch |err| {
                std.debug.panic("3DS audio start failed: {s}", .{@errorName(err)});
            };
            stream_started.store(1, .release);
            start_ns = horizon.time.getSystemNanoseconds();
            written_samples = RING_SAMPLES;
            next_page = 0;
        }

        const played_samples = samples_since(start_ns);
        if (played_samples > written_samples) {
            if (any_active_slots()) {
                std.debug.panic("3DS audio underrun: played={} written={} page={} lead_target={}", .{
                    played_samples,
                    written_samples,
                    next_page,
                    lead_target_samples,
                });
            }
            start_ns = horizon.time.getSystemNanoseconds();
            written_samples = RING_SAMPLES;
            next_page = 0;
            horizon.sleepThread(sleep_ns);
            continue;
        }

        const queued_samples = written_samples - played_samples;
        if (queued_samples <= lead_target_samples) {
            fill_output_page(next_page);
            written_samples += SAMPLES_PER_PAGE;
            next_page = (next_page + 1) % RING_PAGE_COUNT;
        } else {
            horizon.sleepThread(sleep_ns);
        }
    }
}

fn fill_output_page(index: usize) void {
    const data = output_data orelse return;
    const start = index * OUTPUT_PAGE_BYTES;
    const buf = data[start..][0..OUTPUT_PAGE_BYTES];
    const out: [*]i16 = @ptrCast(@alignCast(buf.ptr));

    for (0..SAMPLES_PER_PAGE) |frame| {
        var left_acc: i32 = 0;
        var right_acc: i32 = 0;

        for (&slots) |*slot| {
            var state: SlotState = @enumFromInt(slot.state.load(.acquire));
            if (state == .pending) {
                if (read_next_sample(slot)) {
                    state = .active;
                    slot.state.store(@intFromEnum(SlotState.active), .release);
                } else {
                    state = .finished;
                    slot.state.store(@intFromEnum(SlotState.finished), .release);
                }
            }
            if (state != .active) continue;

            const gain: f32 = @bitCast(slot.gain.load(.acquire));
            const pan: f32 = @bitCast(slot.pan.load(.acquire));
            const left_gain = gain * std.math.clamp(1.0 - pan, 0.0, 1.0);
            const right_gain = gain * std.math.clamp(1.0 + pan, 0.0, 1.0);
            const left_vol: i32 = @intFromFloat(std.math.clamp(left_gain, 0.0, 1.0) * 32768.0);
            const right_vol: i32 = @intFromFloat(std.math.clamp(right_gain, 0.0, 1.0) * 32768.0);

            left_acc += (@as(i32, slot.current_left) * left_vol) >> 15;
            right_acc += (@as(i32, slot.current_right) * right_vol) >> 15;

            advance_sample(slot);
        }

        const mono = clamp_i16(@divTrunc(left_acc + right_acc, 2));
        out[frame] = mono;
    }

    flush_cache_or_panic("mixed output", buf);
}

fn advance_sample(slot: *Slot) void {
    slot.phase_fp +%= slot.step_fp;
    while (slot.phase_fp >= FP_ONE) {
        slot.phase_fp -= FP_ONE;
        if (!read_next_sample(slot)) {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            return;
        }
    }
}

fn read_next_sample(slot: *Slot) bool {
    var tmp: [4]u8 = undefined;
    const frame_size = slot.format.frame_size();
    if (frame_size > tmp.len) return false;

    slot.stream.reader.readSliceAll(tmp[0..frame_size]) catch return false;

    if (slot.format.channels == 1) {
        const s = std.mem.readInt(i16, tmp[0..2], .little);
        slot.current_left = s;
        slot.current_right = s;
    } else {
        slot.current_left = std.mem.readInt(i16, tmp[0..2], .little);
        slot.current_right = std.mem.readInt(i16, tmp[2..4], .little);
    }

    return true;
}

fn start_looping_output() !void {
    const data = output_data orelse std.debug.panic("3DS audio start failed: output buffer missing", .{});
    const physical = horizon.memory.toPhysical(@intFromPtr(data.ptr));
    const physical_addr = @intFromEnum(physical);
    if (physical_addr == 0 or !is_linear_audio_ptr(@intFromPtr(data.ptr))) {
        std.debug.panic("3DS audio start failed: output buffer is not CSND-playable linear memory, ptr=0x{x} phys=0x{x}", .{
            @intFromPtr(data.ptr),
            physical_addr,
        });
    }

    const flags = channel_flags(channel, DEVICE_SAMPLE_RATE, .loop);
    const volumes = csnd_volume(1.0, 0.0);
    try execute_commands(&.{raw_command(.set_channel, SetChannelParam{
        .flags = flags,
        .channel_volume = volumes,
        .capture_volume = volumes,
        .address0 = physical_addr,
        .address1 = physical_addr,
        .size = TOTAL_OUTPUT_BYTES,
    })});
}

fn stop_channel() void {
    if (snd == null or snd_shm == null) return;
    stream_started.store(0, .release);
    execute_commands(&.{channel_command(.set_channel_playback, channel, PlaybackParam{ .operation = .stop })}) catch {};
}

fn samples_since(start_ns: u96) u64 {
    const now = horizon.time.getSystemNanoseconds();
    const elapsed_ns = if (now >= start_ns) now - start_ns else 0;
    return @intCast((elapsed_ns * DEVICE_SAMPLE_RATE) / std.time.ns_per_s);
}

fn any_active_slots() bool {
    for (&slots) |*slot| {
        const state: SlotState = @enumFromInt(slot.state.load(.acquire));
        if (state != .inactive and state != .finished) return true;
    }
    return false;
}

fn execute_commands(cmds: []const CsndCommand) !void {
    const sound = snd orelse std.debug.panic("3DS audio command failed: CSND session missing", .{});
    const shm = snd_shm orelse std.debug.panic("3DS audio command failed: CSND shared memory missing", .{});
    if (COMMAND_OFFSET + cmds.len * @sizeOf(CsndCommand) > shm.len) {
        std.debug.panic("3DS audio command failed: CSND command list exceeds shared memory, count={} shm_len={}", .{ cmds.len, shm.len });
    }

    for (cmds, 0..) |cmd_value, i| {
        const off = COMMAND_OFFSET + i * @sizeOf(CsndCommand);
        const dst: *CsndCommand = @ptrCast(@alignCast(shm[off..].ptr));
        dst.* = cmd_value;
        dst.next = if (i + 1 == cmds.len)
            COMMAND_NONE
        else
            @intCast(COMMAND_OFFSET + (i + 1) * @sizeOf(CsndCommand));
        dst.first_finished = false;
    }

    const bytes = shm[COMMAND_OFFSET..][0 .. cmds.len * @sizeOf(CsndCommand)];
    flush_cache_or_panic("CSND command list", bytes);
    try sound.sendExecuteCommands(COMMAND_OFFSET);
    _ = horizon.invalidateProcessDataCache(.current, bytes);

    const first: *const CsndCommand = @ptrCast(@alignCast(shm[COMMAND_OFFSET..].ptr));
    if (!first.first_finished) {
        const second_id = if (cmds.len > 1) @tagName((@as(*const CsndCommand, @ptrCast(@alignCast(shm[COMMAND_OFFSET + @sizeOf(CsndCommand) ..].ptr)))).id) else "none";
        std.debug.panic("CSND command chain did not mark completion; first id={s} second id={s} count={} next=0x{x}", .{
            @tagName(first.id),
            second_id,
            cmds.len,
            @as(u16, @bitCast(first.next)),
        });
    }
}

fn channel_command(id: CommandId, ch: ChannelId, payload: anytype) CsndCommand {
    var cmd_value: CsndCommand = .{
        .next = COMMAND_NONE,
        .id = id,
        .first_finished = false,
        ._padding0 = @splat(0),
        .parameters = @splat(0),
    };
    std.mem.writeInt(u32, cmd_value.parameters[0..4], @intFromEnum(ch), .little);
    const bytes = std.mem.asBytes(&payload);
    if (4 + bytes.len > cmd_value.parameters.len) {
        @compileError("CSND channel command payload is too large");
    }
    @memcpy(cmd_value.parameters[4..][0..bytes.len], bytes);
    return cmd_value;
}

fn raw_command(id: CommandId, payload: anytype) CsndCommand {
    var cmd_value: CsndCommand = .{
        .next = COMMAND_NONE,
        .id = id,
        .first_finished = false,
        ._padding0 = @splat(0),
        .parameters = @splat(0),
    };
    const bytes = std.mem.asBytes(&payload);
    if (bytes.len > cmd_value.parameters.len) {
        @compileError("CSND raw command payload is too large");
    }
    @memcpy(cmd_value.parameters[0..bytes.len], bytes);
    return cmd_value;
}

fn send_initialize(sound: ChannelSound) !ChannelSound.Handles {
    const data = horizon.tls.get();
    return switch ((try data.ipc.sendRequest(sound.session, ChannelSound.command.Initialize, .{
        .shared_memory_size = SHM_SIZE,
        .dsp_state_offset = STATUS_DSP_OFFSET,
        .channel_state_offset = STATUS_CHANNEL_OFFSET,
        .capture_unit_state_offset = STATUS_CAPTURE_OFFSET,
        .direct_sound_state_offset = STATUS_EXTRA_OFFSET,
    }, .{})).cases()) {
        .success => |s| s.value.handles.wrapped,
        .failure => |code| horizon.unexpectedResult(code),
    };
}

fn send_acquire_channels(sound: ChannelSound) !u32 {
    const data = horizon.tls.get();
    return switch ((try data.ipc.sendRequest(sound.session, AcquireSoundChannels, .{}, .{})).cases()) {
        .success => |s| s.value.available,
        .failure => |code| horizon.unexpectedResult(code),
    };
}

fn object_is_valid(obj: horizon.Object) bool {
    return @as(u32, @bitCast(obj)) != 0;
}

fn choose_channel(mask: u32) ?ChannelId {
    if (mask == 0) return null;
    return .init(@intCast(@ctz(mask)));
}

fn sample_rate_timer(rate: u32) csnd_hw.SampleRate {
    return .rate(@intCast(sample_rate_timer_raw(rate)));
}

fn sample_rate_timer_raw(rate: u32) u32 {
    return std.math.clamp(67_027_964 / rate, 0x42, 0xFFFF);
}

fn channel_flags(ch: ChannelId, rate: u32, loop_mode: csnd_hw.Channel.Repeat) u32 {
    const SOUND_LINEAR_INTERP: u32 = 1 << 6;
    const SOUND_ENABLE: u32 = 1 << 14;
    const SOUND_FORMAT_16BIT: u32 = 1 << 12;
    return (@intFromEnum(ch) & 0x1F) |
        SOUND_LINEAR_INTERP |
        (@as(u32, @intFromEnum(loop_mode)) << 10) |
        SOUND_FORMAT_16BIT |
        SOUND_ENABLE |
        (sample_rate_timer_raw(rate) << 16);
}

fn csnd_volume(volume: f32, pan: f32) u32 {
    if (volume == 1.0 and pan == 0.0) return 0x40004000;

    const vol = std.math.clamp(volume, 0.0, 1.0);
    const rpan = std.math.clamp((pan + 1.0) / 2.0, 0.0, 1.0);
    const left: u32 = @intFromFloat(vol * (1.0 - rpan) * @as(f32, 32768.0));
    const right: u32 = @intFromFloat(vol * rpan * @as(f32, 32768.0));
    return left | (right << 16);
}

fn is_linear_audio_ptr(ptr: usize) bool {
    return (ptr >= horizon.memory.old_linear_heap_begin and ptr < horizon.memory.old_linear_heap_end) or
        (ptr >= horizon.memory.linear_heap_begin and ptr < horizon.memory.linear_heap_end);
}

fn flush_output() void {
    if (output_data) |data| {
        flush_cache_or_panic("initial output", data);
    }
}

fn flush_cache_or_panic(comptime where: []const u8, data: []const u8) void {
    const rc = horizon.flushProcessDataCache(.current, data);
    if (!rc.isSuccess()) {
        std.debug.panic("3DS audio cache flush failed at {s}: rc=0x{x} ptr=0x{x} len={}", .{
            where,
            @as(u32, @bitCast(rc)),
            @intFromPtr(data.ptr),
            data.len,
        });
    }
}

fn clamp_i16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn format_supported(fmt: PcmFormat) bool {
    return fmt.bit_depth == 16 and (fmt.channels == 1 or fmt.channels == 2);
}

const CommandId = enum(u16) {
    set_channel_playback = 0x0000,
    set_channel_paused = 0x0001,
    set_channel_format = 0x0002,
    set_channel_second_buffer = 0x0003,
    set_channel_repeat = 0x0004,
    set_channel_sample_rate = 0x0008,
    set_channel_volume = 0x0009,
    set_channel_buffer = 0x000A,
    set_channel = 0x000E,
};

const AcquireSoundChannels = horizon.ipc.Command(ChannelSound.command.Id, .acquire_sound_channels, struct {}, struct {
    available: u32,
});

const CsndCommand = extern struct {
    next: i16,
    id: CommandId,
    first_finished: bool,
    _padding0: [3]u8,
    parameters: [24]u8,
};

const PlaybackParam = extern struct {
    const Operation = enum(u32) { stop = 0, start = 1 };
    operation: Operation,
    _unused0: [16]u8 = @splat(0),
};

const FormatParam = extern struct {
    format: hardware.LsbRegister(csnd_hw.Channel.Format),
    _unused0: [16]u8 = @splat(0),
};

const RepeatParam = extern struct {
    repeat: hardware.LsbRegister(csnd_hw.Channel.Repeat),
    _unused0: [16]u8 = @splat(0),
};

const SampleRateParam = extern struct {
    sample_rate: hardware.LsbRegister(csnd_hw.SampleRate),
    _unused0: [16]u8 = @splat(0),
};

const VolumeParam = extern struct {
    volume: csnd_hw.Channel.Volume,
    _unused0: [16]u8 = @splat(0),
};

const BufferParam = extern struct {
    address: hardware.PhysicalAddress,
    size: u32,
    _unused0: [12]u8 = @splat(0),
};

const SetChannelParam = extern struct {
    flags: u32,
    channel_volume: u32,
    capture_volume: u32,
    address0: u32,
    address1: u32,
    size: u32,
};

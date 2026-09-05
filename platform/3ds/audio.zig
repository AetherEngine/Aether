//! Mixes slots into a looping CSND PCM16 ring in linear memory.

const std = @import("std");
const assert = std.debug.assert;
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const audio_api = @import("../audio_api.zig");
const thread_mod = @import("../thread.zig");
const audio_fifo = @import("audio_fifo.zig");
const SlotSource = audio_api.SlotSource;
const PcmFormat = audio_api.PcmFormat;

const horizon = zitrus.horizon;
const ChannelSound = horizon.services.ChannelSound;
const CsndCommand = ChannelSound.Command;
const Thread = thread_mod.Thread;

const device_sample_rate: u32 = 44_100;
const device_channels: usize = 1;
const num_slots: usize = 16;
const samples_per_page: usize = 512;
const ring_page_count: usize = 8;
const lead_page_count: usize = 3;
const read_buf_size: usize = samples_per_page * 2 * @sizeOf(i16);
const output_page_bytes: usize = samples_per_page * device_channels * @sizeOf(i16);
const total_output_bytes: usize = output_page_bytes * ring_page_count;
const ring_samples: usize = samples_per_page * ring_page_count;
const page_ns: u64 = (@as(u64, samples_per_page) * std.time.ns_per_s) / device_sample_rate;
const fp_one: u64 = 1 << 32;

/// Filesystem operations on 3DS are latency-sensitive IPC operations. The
/// render thread consumes from these bounded FIFOs while a separate worker
/// refills them in larger chunks.
const stream_fifo_min_bytes: usize = 4 * 1024;
const stream_start_bytes: usize = 4 * 1024;
const stream_prefetch_chunk_bytes: usize = 8 * 1024;

const command_block_size: u32 = 0x2000;
const status_dsp_offset: u32 = command_block_size;
const status_channel_offset: u32 = status_dsp_offset + 8;
const status_capture_offset: u32 = status_channel_offset + 12 * 32;
const status_extra_offset: u32 = status_capture_offset + 8 * 2;
const shm_size: usize = std.mem.alignForward(usize, status_extra_offset + 0x3c, horizon.heap.page_size);
const command_offset: u32 = 0;
const command_completion_poll_count: usize = 2048;

const Channel = ChannelSound.Channel;

const SlotState = enum(u8) {
    inactive = 0,
    pending = 1,
    active = 2,
    finished = 3,
};

const StreamState = enum(u8) {
    none = 0,
    filling = 1,
    eof = 2,
    failed = 3,
};

const Slot = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(SlotState.inactive)),
    gain: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0))),
    pan: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0))),
    source: SlotSource = undefined,
    format: PcmFormat = .{ .sample_rate = device_sample_rate, .channels = 1, .bit_depth = 16 },
    step_fp: u64 = fp_one,
    phase_fp: u64 = 0,
    current_left: i16 = 0,
    current_right: i16 = 0,
    has_current_sample: bool = false,
    read_buf: [read_buf_size]u8 = undefined,
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // The worker publishes this only after it has moved on from the previous
    // stream generation. The render thread can then discard stale FIFO bytes
    // without racing either FIFO endpoint.
    producer_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    stream_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(StreamState.none)),
    stream_state_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // Owned exclusively by the render thread.
    render_generation: u32 = 0,
    consumer_generation: u32 = 0,
};

var slots: [num_slots]Slot = @splat(.{});
var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;
var snd: ?ChannelSound = null;
var snd_mutex: horizon.Mutex = .none;
var snd_shm_block: horizon.MemoryBlock = .none;
var snd_shm: ?[]align(horizon.heap.page_size) u8 = null;
var output_data: ?[]align(horizon.heap.page_size) u8 = null;
var channel: Channel.Id = .channel(0);
var audio_thread: ?Thread = null;
var stream_io_thread: ?Thread = null;
var running: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var stream_io_running: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var applet_suspended: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var stream_started: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var command_lock: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var stream_wakeup: std.Io.Event = .unset;
var stream_wakeup_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var stream_cache: ?[]u8 = null;
var stream_fifo_bytes: usize = 0;
var stream_fifos: [num_slots]audio_fifo.ByteFifo = undefined;
var stream_underflows: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var output_underruns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var initialized = false;

pub fn init(alloc: std.mem.Allocator, io: std.Io) audio_api.InitError!void {
    audio_alloc = alloc;
    audio_io = io;
    const app = app_3ds.current_application() orelse std.debug.panic("3DS audio init failed: no current application", .{});

    snd = ChannelSound.open(app.srv) catch |err| return init_failed("open csnd:SND", err);
    errdefer {
        snd.?.close();
        snd = null;
    }

    const shm_ptr = horizon.heap.allocShared(shm_size);
    const shm_slice = shm_ptr[0..shm_size];

    const init_handles = snd.?.sendInitialize(shm_size, status_dsp_offset, status_channel_offset, status_capture_offset, status_extra_offset) catch |err| return init_failed("initialize CSND", err);
    snd_mutex = init_handles.mutex;
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

    const mask: u32 = @bitCast(snd.?.sendAcquireSoundChannels() catch |err| return init_failed("acquire CSND channels", err));
    channel = choose_channel(mask) orelse {
        std.debug.panic("3DS audio init failed: no CSND channel available, mask=0x{x:0>8}", .{mask});
    };
    errdefer snd.?.sendReleaseSoundChannels() catch {};

    output_data = horizon.heap.linear_page_allocator.alignedAlloc(
        u8,
        .fromByteUnits(horizon.heap.page_size),
        total_output_bytes,
    ) catch |err| return init_failed("allocate CSND output buffer", err);
    errdefer {
        horizon.heap.linear_page_allocator.free(output_data.?);
        output_data = null;
    }
    @memset(output_data.?, 0);
    flush_output();
    stream_started.store(0, .release);

    init_stream_cache(app_3ds.audio_stream_cache_bytes()) catch |err| return init_failed("reserve stream cache from audio pool", err);
    errdefer deinit_stream_cache();

    stream_wakeup.reset();
    stream_wakeup_sequence.store(0, .release);
    stream_underflows.store(0, .release);
    output_underruns.store(0, .release);
    applet_suspended.store(0, .release);

    start_stream_worker() catch |err| return init_failed("start stream I/O worker", err);
    errdefer stop_stream_worker();

    running.store(1, .release);
    audio_thread = Thread.spawn(
        .{ .allocator = audio_alloc, .name = "aether_audio", .priority = .highest, .stack_size = 24 * 1024 },
        audio_thread_fn,
        .{},
    ) catch |err| return init_failed("start audio thread", err);
    errdefer stop_audio_thread();

    initialized = true;

    std.log.info("3DS audio stream cache: {} KiB total ({} slots x {} KiB) from the engine audio pool", .{
        stream_cache.?.len / 1024,
        num_slots,
        stream_fifo_bytes / 1024,
    });
}

fn init_failed(comptime stage: []const u8, err: anyerror) audio_api.InitError {
    std.log.err("3DS audio init failed at {s}: {s}", .{ stage, @errorName(err) });
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AudioInitFailed,
    };
}

fn init_stream_cache(total_bytes: usize) !void {
    if (total_bytes < num_slots * stream_fifo_min_bytes or total_bytes % num_slots != 0) {
        return error.InvalidStreamCacheSize;
    }

    const bytes = try audio_alloc.alloc(u8, total_bytes);
    errdefer audio_alloc.free(bytes);

    const fifo_bytes = total_bytes / num_slots;
    for (&stream_fifos, 0..) |*fifo, i| {
        const start = i * fifo_bytes;
        fifo.* = audio_fifo.ByteFifo.init(bytes[start..][0..fifo_bytes]);
    }

    stream_cache = bytes;
    stream_fifo_bytes = fifo_bytes;
}

fn deinit_stream_cache() void {
    if (stream_cache) |bytes| {
        audio_alloc.free(bytes);
        stream_cache = null;
    }
    stream_fifo_bytes = 0;
}

fn start_stream_worker() !void {
    stream_io_running.store(1, .release);
    errdefer stream_io_running.store(0, .release);

    stream_io_thread = try Thread.spawn(
        .{ .allocator = audio_alloc, .name = "aether_audio_io", .priority = .normal, .stack_size = 16 * 1024 },
        stream_io_thread_fn,
        .{},
    );
}

fn stop_audio_thread() void {
    running.store(0, .release);
    if (audio_thread) |thread| {
        thread.join();
        audio_thread = null;
    }
}

fn stop_stream_worker() void {
    stream_io_running.store(0, .release);
    notify_stream_worker();
    if (stream_io_thread) |thread| {
        thread.join();
        stream_io_thread = null;
    }
}

pub fn deinit() void {
    if (!initialized and snd == null) return;

    stop_audio_thread();
    stop_stream_worker();

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
    if (object_is_valid(snd_mutex.sync.obj)) {
        snd_mutex.close();
        snd_mutex = .none;
    }

    if (output_data) |data| {
        horizon.heap.linear_page_allocator.free(data);
        output_data = null;
    }
    deinit_stream_cache();

    const underflows = stream_underflows.load(.acquire);
    const output_underflow_count = output_underruns.load(.acquire);
    if (underflows != 0 or output_underflow_count != 0) {
        std.log.warn("3DS audio diagnostics: stream underflows={} output underruns={}", .{ underflows, output_underflow_count });
    }

    for (&slots) |*slot| {
        slot.state.store(@intFromEnum(SlotState.inactive), .release);
        slot.producer_generation.store(0, .release);
        slot.stream_state.store(@intFromEnum(StreamState.none), .release);
        slot.stream_state_generation.store(0, .release);
        slot.render_generation = 0;
        slot.consumer_generation = 0;
        slot.has_current_sample = false;
    }

    initialized = false;
}

pub fn suspend_for_applet() void {
    if (!initialized) return;
    applet_suspended.store(1, .release);
    notify_stream_worker();
    stop_channel();
}

pub fn resume_from_applet() void {
    if (!initialized) return;
    applet_suspended.store(0, .release);
    notify_stream_worker();
}

pub fn update() void {}

pub fn max_voices() u32 {
    return num_slots;
}

pub fn play_slot(slot: u8, source: SlotSource) audio_api.PlaySlotError!void {
    if (slot >= num_slots) return error.InvalidArgs;
    const format = source.format();
    if (!format_supported(format)) return error.UnsupportedFormat;

    const i: usize = slot;
    slots[i].source = source;
    slots[i].format = format;
    slots[i].step_fp = (@as(u64, format.sample_rate) << 32) / device_sample_rate;
    _ = slots[i].generation.fetchAdd(1, .acq_rel);
    switch (source) {
        .buffer => {
            slots[i].stream_state.store(@intFromEnum(StreamState.none), .release);
            slots[i].stream_state_generation.store(0, .release);
        },
        .stream => {
            slots[i].stream_state.store(@intFromEnum(StreamState.filling), .release);
            slots[i].stream_state_generation.store(0, .release);
        },
    }
    slots[i].state.store(@intFromEnum(SlotState.pending), .release);
    if (source == .stream) notify_stream_worker();
}

pub fn stop_slot(slot: u8) void {
    if (slot >= num_slots) return;
    _ = slots[slot].generation.fetchAdd(1, .acq_rel);
    slots[slot].stream_state.store(@intFromEnum(StreamState.none), .release);
    slots[slot].stream_state_generation.store(0, .release);
    slots[slot].state.store(@intFromEnum(SlotState.inactive), .release);
    notify_stream_worker();
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= num_slots) return;
    slots[slot].gain.store(@bitCast(gain), .release);
    slots[slot].pan.store(@bitCast(pan), .release);
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= num_slots) return false;
    const state: SlotState = @enumFromInt(slots[slot].state.load(.acquire));
    return state != .inactive and state != .finished;
}

fn audio_thread_fn() void {
    var next_page: usize = 0;
    var written_samples: u64 = 0;
    var start_ns: u96 = 0;
    const lead_target_samples: u64 = samples_per_page * lead_page_count;
    const sleep_ns: i64 = @intCast(@max(page_ns / 4, @as(u64, std.time.ns_per_ms)));

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
            for (0..ring_page_count) |page| {
                fill_output_page(page);
            }
            start_looping_output() catch |err| {
                std.debug.panic("3DS audio start failed: {s}", .{@errorName(err)});
            };
            stream_started.store(1, .release);
            start_ns = horizon.time.getSystemNanoseconds();
            written_samples = ring_samples;
            next_page = 0;
        }

        const played_samples = samples_since(start_ns);
        if (played_samples > written_samples) {
            if (any_active_slots()) {
                _ = output_underruns.fetchAdd(1, .monotonic);
                std.log.warn("3DS audio underrun: played={} written={} page={} lead_target={}", .{
                    played_samples,
                    written_samples,
                    next_page,
                    lead_target_samples,
                });
            }
            reset_looping_output() catch |err| {
                std.debug.panic("3DS audio underrun recovery failed: {s}", .{@errorName(err)});
            };
            start_ns = horizon.time.getSystemNanoseconds();
            written_samples = ring_samples;
            next_page = 0;
            horizon.sleepThread(sleep_ns);
            continue;
        }

        while (written_samples - played_samples <= lead_target_samples) {
            fill_output_page(next_page);
            written_samples += samples_per_page;
            next_page = (next_page + 1) % ring_page_count;
        }

        if (written_samples - played_samples > lead_target_samples) {
            horizon.sleepThread(sleep_ns);
        }
    }
}

fn fill_output_page(index: usize) void {
    const data = output_data orelse return;
    const start = index * output_page_bytes;
    const buf = data[start..][0..output_page_bytes];
    const out: [*]i16 = @ptrCast(@alignCast(buf.ptr));
    var accum: [samples_per_page]i32 = @splat(0);

    for (&slots, 0..) |*slot, slot_index| {
        var state: SlotState = @enumFromInt(slot.state.load(.acquire));
        if (state == .pending) {
            reset_render_state_for_generation(slot);
            if (!pending_slot_ready(slot, slot_index)) continue;
            state = .active;
            slot.state.store(@intFromEnum(SlotState.active), .release);
        }
        if (state != .active) continue;

        const gain: f32 = @bitCast(slot.gain.load(.acquire));
        const pan: f32 = @bitCast(slot.pan.load(.acquire));
        const left_gain = gain * std.math.clamp(1.0 - pan, 0.0, 1.0);
        const right_gain = gain * std.math.clamp(1.0 + pan, 0.0, 1.0);
        const left_vol: i32 = @intFromFloat(std.math.clamp(left_gain, 0.0, 1.0) * 32768.0);
        const right_vol: i32 = @intFromFloat(std.math.clamp(right_gain, 0.0, 1.0) * 32768.0);

        if (can_bulk_mix(slot)) {
            mix_slot_page(slot, slot_index, &accum, left_vol, right_vol);
        } else {
            mix_slot_page_resampled(slot, slot_index, &accum, left_vol, right_vol);
        }
    }

    for (0..samples_per_page) |frame| {
        out[frame] = clamp_i16(accum[frame]);
    }

    flush_cache_or_panic("mixed output", buf);
}

fn can_bulk_mix(slot: *const Slot) bool {
    return slot.format.sample_rate == device_sample_rate and slot.step_fp == fp_one;
}

const SourceReadStatus = enum {
    ok,
    underflow,
    end,
};

const SourceRead = struct {
    bytes_read: usize,
    status: SourceReadStatus,
};

fn reset_render_state_for_generation(slot: *Slot) void {
    const generation = slot.generation.load(.acquire);
    if (slot.render_generation == generation) return;

    slot.phase_fp = 0;
    slot.current_left = 0;
    slot.current_right = 0;
    slot.has_current_sample = false;
    slot.render_generation = generation;
}

fn pending_slot_ready(slot: *Slot, slot_index: usize) bool {
    return switch (slot.source) {
        .buffer => true,
        .stream => {
            const generation = slot.generation.load(.acquire);
            if (slot.producer_generation.load(.acquire) != generation) return false;

            const fifo = &stream_fifos[slot_index];
            if (slot.consumer_generation != generation) {
                // The worker has finished any prior generation before it
                // publishes `producer_generation`, so this can only discard
                // stale bytes (or an early chunk from this generation).
                fifo.discard_all();
                slot.consumer_generation = generation;
                notify_stream_worker();
            }
            if (slot.generation.load(.acquire) != generation) return false;

            if (slot.stream_state_generation.load(.acquire) != generation) return false;
            const stream_state: StreamState = @enumFromInt(slot.stream_state.load(.acquire));
            if (stream_state == .failed) {
                slot.state.store(@intFromEnum(SlotState.finished), .release);
                return false;
            }

            const frame_size: usize = slot.format.frame_size();
            const start_bytes = @min(stream_start_bytes, fifo.capacity());
            const available = fifo.readable();
            if (stream_state == .eof and available < frame_size) {
                slot.state.store(@intFromEnum(SlotState.finished), .release);
                return false;
            }
            return available >= start_bytes or (stream_state == .eof and available >= frame_size);
        },
    };
}

fn mix_slot_page(slot: *Slot, slot_index: usize, accum: *[samples_per_page]i32, left_vol: i32, right_vol: i32) void {
    const fmt = slot.format;
    const frame_size = fmt.frame_size();
    const bytes_needed: usize = samples_per_page * frame_size;
    if (bytes_needed > read_buf_size) {
        slot.state.store(@intFromEnum(SlotState.finished), .release);
        return;
    }

    const read_buf = slot.read_buf[0..bytes_needed];
    const read = read_source_short(slot, slot_index, read_buf);
    const frames_read = read.bytes_read / frame_size;

    if (fmt.channels == 1) {
        const mono_vol = @divTrunc(left_vol + right_vol, 2);
        for (0..frames_read) |frame| {
            const s: i32 = std.mem.readInt(i16, read_buf[frame * 2 ..][0..2], .little);
            accum[frame] += (s * mono_vol) >> 15;
        }
    } else {
        for (0..frames_read) |frame| {
            const l: i32 = std.mem.readInt(i16, read_buf[frame * 4 ..][0..2], .little);
            const r: i32 = std.mem.readInt(i16, read_buf[frame * 4 + 2 ..][0..2], .little);
            const left = (l * left_vol) >> 15;
            const right = (r * right_vol) >> 15;
            accum[frame] += @divTrunc(left + right, 2);
        }
    }

    if (read.status == .end) {
        slot.state.store(@intFromEnum(SlotState.finished), .release);
    }
}

fn mix_slot_page_resampled(slot: *Slot, slot_index: usize, accum: *[samples_per_page]i32, left_vol: i32, right_vol: i32) void {
    if (!slot.has_current_sample) {
        switch (read_next_sample(slot, slot_index)) {
            .ok => slot.has_current_sample = true,
            .underflow => return,
            .end => {
                slot.state.store(@intFromEnum(SlotState.finished), .release);
                return;
            },
        }
    }

    for (0..samples_per_page) |frame| {
        const left = (@as(i32, slot.current_left) * left_vol) >> 15;
        const right = (@as(i32, slot.current_right) * right_vol) >> 15;
        accum[frame] += @divTrunc(left + right, 2);
        switch (advance_sample(slot, slot_index)) {
            .ok => {},
            .underflow => {
                slot.has_current_sample = false;
                return;
            },
            .end => {
                slot.has_current_sample = false;
                slot.state.store(@intFromEnum(SlotState.finished), .release);
                return;
            },
        }
    }
}

fn advance_sample(slot: *Slot, slot_index: usize) SourceReadStatus {
    slot.phase_fp +%= slot.step_fp;
    while (slot.phase_fp >= fp_one) {
        slot.phase_fp -= fp_one;
        switch (read_next_sample(slot, slot_index)) {
            .ok => {},
            .underflow => return .underflow,
            .end => return .end,
        }
    }
    return .ok;
}

fn read_next_sample(slot: *Slot, slot_index: usize) SourceReadStatus {
    var tmp: [4]u8 = undefined;
    const frame_size = slot.format.frame_size();
    if (frame_size > tmp.len) return .end;

    switch (read_source_exact(slot, slot_index, tmp[0..frame_size])) {
        .ok => {},
        .underflow => return .underflow,
        .end => return .end,
    }

    if (slot.format.channels == 1) {
        const s = std.mem.readInt(i16, tmp[0..2], .little);
        slot.current_left = s;
        slot.current_right = s;
    } else {
        slot.current_left = std.mem.readInt(i16, tmp[0..2], .little);
        slot.current_right = std.mem.readInt(i16, tmp[2..4], .little);
    }

    return .ok;
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

    const volumes: Channel.Volume = csnd_volume(1.0, 1.0);
    try execute_commands(&.{.setChannelSound(.none, .{
        .control = .{
            .channel = channel,
            .linearly_interpolate = true,
            .repeat = .loop,
            .format = .pcm16,
            .disable_pause = true,
            .sample_rate = .rate(device_sample_rate),
        },
        .channel_volume = volumes,
        .capture_volume = volumes,
        .address = physical,
        .second_address = physical,
        .size = total_output_bytes,
    })});
}

fn reset_looping_output() !void {
    stop_channel();
    if (output_data) |data| @memset(data, 0);
    for (0..ring_page_count) |page| {
        fill_output_page(page);
    }
    try start_looping_output();
    stream_started.store(1, .release);
}

fn stop_channel() void {
    if (snd == null or snd_shm == null) return;
    stream_started.store(0, .release);
    execute_commands(&.{.setChannelPlayback(.none, .playback(channel, .stop))}) catch {};
}

fn samples_since(start_ns: u96) u64 {
    const now = horizon.time.getSystemNanoseconds();
    const elapsed_ns = if (now >= start_ns) now - start_ns else 0;
    return @intCast((elapsed_ns * device_sample_rate) / std.time.ns_per_s);
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
    if (command_offset + cmds.len * @sizeOf(CsndCommand) > shm.len) {
        std.debug.panic("3DS audio command failed: CSND command list exceeds shared memory, count={} shm_len={}", .{ cmds.len, shm.len });
    }

    const bytes = shm[command_offset..][0 .. cmds.len * @sizeOf(CsndCommand)];
    lock_command_buffer();
    defer unlock_command_buffer();

    lock_csnd_mutex();
    for (cmds, 0..) |cmd_value, i| {
        const off = command_offset + i * @sizeOf(CsndCommand);
        const dst: *CsndCommand = @ptrCast(@alignCast(shm[off..].ptr));
        dst.* = cmd_value;
        dst.next = if (i + 1 == cmds.len)
            .none
        else
            .offset(@intCast(command_offset + (i + 1) * @sizeOf(CsndCommand)));
        dst.first_finished = false;
    }
    flush_cache_or_panic("CSND command list", bytes);
    unlock_csnd_mutex();

    try sound.sendExecuteCommands(command_offset);
    wait_command_completion_or_panic(shm, bytes, cmds.len);
}

fn lock_command_buffer() void {
    while (command_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        horizon.sleepThread(0);
    }
}

fn unlock_command_buffer() void {
    command_lock.store(0, .release);
}

fn lock_csnd_mutex() void {
    snd_mutex.wait(.none) catch |err| {
        std.debug.panic("3DS audio command failed: wait CSND mutex: {s}", .{@errorName(err)});
    };
}

fn unlock_csnd_mutex() void {
    snd_mutex.release();
}

fn wait_command_completion_or_panic(shm: []align(horizon.heap.page_size) u8, bytes: []u8, cmd_count: usize) void {
    for (0..command_completion_poll_count) |_| {
        invalidate_cache_or_panic("CSND command completion", bytes);
        const first: *const CsndCommand = @ptrCast(@alignCast(shm[command_offset..].ptr));
        if (first.first_finished) return;
        horizon.sleepThread(0);
    }

    const first: *const CsndCommand = @ptrCast(@alignCast(shm[command_offset..].ptr));
    const second_id = if (cmd_count > 1) @tagName((@as(*const CsndCommand, @ptrCast(@alignCast(shm[command_offset + @sizeOf(CsndCommand) ..].ptr)))).id) else "none";
    std.debug.panic("CSND command chain did not mark completion after {} polls; first id={s} second id={s} count={} next=0x{x}", .{
        command_completion_poll_count,
        @tagName(first.id),
        second_id,
        cmd_count,
        @as(u16, @intFromEnum(first.next)),
    });
}

fn object_is_valid(obj: horizon.Object) bool {
    return @as(u32, @bitCast(obj)) != 0;
}

fn choose_channel(mask: u32) ?Channel.Id {
    if (mask == 0) return null;
    return .channel(@intCast(@ctz(mask)));
}

fn csnd_volume(volume: f32, pan: f32) Channel.Volume {
    const vol_norm: u15 = @trunc(std.math.clamp(volume * 32767.0, 0, std.math.maxInt(i16)));
    const pan_norm: i16 = @trunc(std.math.clamp(pan * 32767.0, std.math.minInt(i16), std.math.maxInt(i16)));
    return .init(vol_norm, pan_norm);
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

fn invalidate_cache_or_panic(comptime where: []const u8, data: []u8) void {
    const rc = horizon.invalidateProcessDataCache(.current, data);
    if (!rc.isSuccess()) {
        std.debug.panic("3DS audio cache invalidate failed at {s}: rc=0x{x} ptr=0x{x} len={}", .{
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

fn read_source_short(slot: *Slot, slot_index: usize, dst: []u8) SourceRead {
    return switch (slot.source) {
        .buffer => |buffer| blk: {
            const cursor = buffer.cursor.load(.acquire);
            if (cursor >= buffer.pcm.len) break :blk .{ .bytes_read = 0, .status = .end };
            const remaining = buffer.pcm.len - cursor;
            const n = @min(dst.len, remaining);
            @memcpy(dst[0..n], buffer.pcm[cursor..][0..n]);
            buffer.cursor.store(cursor + n, .release);
            break :blk .{
                .bytes_read = n,
                .status = if (n == dst.len) .ok else .end,
            };
        },
        .stream => blk: {
            const fifo = &stream_fifos[slot_index];
            const frame_size: usize = @intCast(slot.format.frame_size());
            const available = fifo.readable();
            const n = (@min(dst.len, available) / frame_size) * frame_size;
            const copied = fifo.read(dst[0..n]);
            assert(copied == n);
            if (fifo.readable() < fifo.capacity() / 2) notify_stream_worker();

            if (copied == dst.len) break :blk .{ .bytes_read = copied, .status = .ok };
            break :blk .{
                .bytes_read = copied,
                .status = stream_short_read_status(slot),
            };
        },
    };
}

fn read_source_exact(slot: *Slot, slot_index: usize, dst: []u8) SourceReadStatus {
    switch (slot.source) {
        .buffer => |buffer| {
            const cursor = buffer.cursor.load(.acquire);
            if (dst.len > buffer.pcm.len -| cursor) return .end;
            @memcpy(dst, buffer.pcm[cursor..][0..dst.len]);
            buffer.cursor.store(cursor + dst.len, .release);
            return .ok;
        },
        .stream => {
            const fifo = &stream_fifos[slot_index];
            if (fifo.readable() < dst.len) return stream_short_read_status(slot);
            const copied = fifo.read(dst);
            assert(copied == dst.len);
            if (fifo.readable() < fifo.capacity() / 2) notify_stream_worker();
            return .ok;
        },
    }
}

fn stream_short_read_status(slot: *Slot) SourceReadStatus {
    const generation = slot.generation.load(.acquire);
    if (slot.producer_generation.load(.acquire) != generation or
        slot.stream_state_generation.load(.acquire) != generation)
    {
        _ = stream_underflows.fetchAdd(1, .monotonic);
        notify_stream_worker();
        return .underflow;
    }

    const state: StreamState = @enumFromInt(slot.stream_state.load(.acquire));
    return switch (state) {
        .eof, .failed, .none => .end,
        .filling => blk: {
            _ = stream_underflows.fetchAdd(1, .monotonic);
            notify_stream_worker();
            break :blk .underflow;
        },
    };
}

fn format_supported(fmt: PcmFormat) bool {
    return fmt.sample_rate != 0 and fmt.bit_depth == 16 and (fmt.channels == 1 or fmt.channels == 2);
}

fn stream_refill_needed(slot_index: usize) bool {
    const fifo = &stream_fifos[slot_index];
    const minimum_write = @min(stream_prefetch_chunk_bytes / 2, fifo.capacity() / 2);
    return fifo.writable() >= minimum_write and fifo.readable() < (fifo.capacity() * 3) / 4;
}

fn notify_stream_worker() void {
    _ = stream_wakeup_sequence.fetchAdd(1, .release);
    stream_wakeup.set(audio_io);
}

const StreamWorkerProgress = struct {
    generation: u32 = 0,
    bytes_read: u64 = 0,
    initialized: bool = false,
};

fn stream_slot_is_current(slot: *const Slot, generation: u32) bool {
    if (slot.generation.load(.acquire) != generation) return false;
    const state: SlotState = @enumFromInt(slot.state.load(.acquire));
    return state == .pending or state == .active;
}

fn set_stream_state_if_current(slot: *Slot, generation: u32, state: StreamState) void {
    if (!stream_slot_is_current(slot, generation)) return;
    slot.stream_state_generation.store(generation, .release);
    slot.stream_state.store(@intFromEnum(state), .release);
}

fn worker_refill_slot(slot_index: usize, scratch: []u8, progress: *StreamWorkerProgress) bool {
    const slot = &slots[slot_index];
    const state: SlotState = @enumFromInt(slot.state.load(.acquire));
    if (state != .pending and state != .active) return false;

    const generation = slot.generation.load(.acquire);
    const stream = switch (slot.source) {
        .buffer => return false,
        .stream => |value| value,
    };

    const fifo = &stream_fifos[slot_index];
    if (!progress.initialized or progress.generation != generation) {
        progress.* = .{ .generation = generation, .initialized = true };

        // A prior read can finish after a game-thread slot replacement. Do
        // not let the render thread consume its FIFO bytes: publish this
        // generation only after that older work has completed.
        if (slot.generation.load(.acquire) != generation) return true;
        slot.stream_state_generation.store(generation, .release);
        slot.stream_state.store(@intFromEnum(StreamState.filling), .release);
        slot.producer_generation.store(generation, .release);

        // If this FIFO belongs to a previous stream, wait for the sole
        // consumer to discard it before putting new PCM behind it.
        if (fifo.readable() != 0) return false;
    }

    if (!stream_slot_is_current(slot, generation)) return false;
    if (slot.stream_state_generation.load(.acquire) != generation) return false;
    const stream_state: StreamState = @enumFromInt(slot.stream_state.load(.acquire));
    if (stream_state != .filling or !stream_refill_needed(slot_index)) return false;

    const frame_size: usize = stream.format.frame_size();
    const bytes_read = progress.bytes_read;
    const max_by_length: usize = if (stream.byte_length) |length|
        @intCast(@min(length -| bytes_read, @as(u64, std.math.maxInt(usize))))
    else
        scratch.len;
    const max_read = @min(@min(scratch.len, fifo.writable()), max_by_length);
    const request_len = (max_read / frame_size) * frame_size;
    if (request_len == 0) {
        if (stream.byte_length) |length| {
            if (bytes_read >= length) {
                set_stream_state_if_current(slot, generation, .eof);
            }
        }
        return false;
    }

    const n = stream.reader.readSliceShort(scratch[0..request_len]) catch {
        set_stream_state_if_current(slot, generation, .failed);
        return true;
    };

    if (!stream_slot_is_current(slot, generation)) return n != 0;

    const copied = fifo.write(scratch[0..n]);
    assert(copied == n);
    progress.bytes_read += n;

    if (n == 0 or (stream.byte_length != null and progress.bytes_read >= stream.byte_length.?)) {
        set_stream_state_if_current(slot, generation, .eof);
    }
    return true;
}

fn stream_io_thread_fn() void {
    var scratch: [stream_prefetch_chunk_bytes]u8 = undefined;
    var progress: [num_slots]StreamWorkerProgress = @splat(.{});
    var next_slot: usize = 0;
    var observed_wakeup = stream_wakeup_sequence.load(.acquire);

    while (stream_io_running.load(.acquire) != 0) {
        if (applet_suspended.load(.acquire) == 0) {
            var did_work = false;
            for (0..num_slots) |offset| {
                const slot_index = (next_slot + offset) % num_slots;
                if (worker_refill_slot(slot_index, &scratch, &progress[slot_index])) {
                    next_slot = (slot_index + 1) % num_slots;
                    did_work = true;
                    break;
                }
            }
            if (did_work) continue;
        }

        stream_wakeup.reset();
        const current_wakeup = stream_wakeup_sequence.load(.acquire);
        if (current_wakeup != observed_wakeup or stream_io_running.load(.acquire) == 0) {
            observed_wakeup = current_wakeup;
            continue;
        }
        stream_wakeup.waitUncancelable(audio_io);
        observed_wakeup = stream_wakeup_sequence.load(.acquire);
    }
}

//! Public compatibility facade for the Core API and Platform contracts.

const std = @import("std");
const options = @import("options");

pub const Core = @import("core.zig");
pub const Util = Core.Util;
pub const Rendering = Core.Rendering;
pub const Ui = Core.Ui;
pub const Audio = Core.Audio;
pub const System = Core.System;
pub const Network = Core.Network;
pub const FileExport = Core.FileExport;
pub const Storage = Core.Storage;
pub const Jobs = Core.Jobs;
pub const Resources = Core.Resources;
pub const Math = Core.Math;
pub const Engine = Core.Engine;
pub const AppOptions = Core.AppOptions;
pub const Options = AppOptions.Options;
pub const PspOptions = AppOptions.PspOptions;
pub const PspModuleMode = AppOptions.PspModuleMode;
pub const Nintendo3dsOptions = AppOptions.Nintendo3dsOptions;
pub const ctx_to_self = Util.ctx_to_self;
pub const PlatformApi = struct {
    pub const gfx = @import("platform").gfx_api;
    pub const audio = @import("platform").audio_api;
    pub const input = @import("platform").input_api;
    pub const surface = @import("platform").surface;
    pub const thread = @import("platform").thread_api;
    pub const graphics = @import("platform").graphics;
    pub const system = @import("platform").system.api;
    pub const network = @import("platform").network.api;
};

/// PSP system dialogs (keyboard and network configuration).
pub const Psp = if (platform == .psp) @import("platform").Psp else void;
pub const N3ds = if (platform == .nintendo_3ds) @import("platform").N3ds else void;
pub const Cio = if (platform == .nintendo_switch) @import("platform").Cio else void;
pub const CProcessInit = if (platform == .nintendo_switch) @import("platform").CProcessInit else void;

/// Build-selected platform and graphics backend.
pub const Platform = @TypeOf(options.config.platform);
pub const Gfx = @TypeOf(options.config.gfx);
pub const platform: Platform = options.config.platform;
pub const gfx: Gfx = options.config.gfx;
pub const mesh_indexing: bool = options.config.mesh_indexing;

comptime {
    if (platform != .wasm) std.testing.refAllDecls(@This());
}

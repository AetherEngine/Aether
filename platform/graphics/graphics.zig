//! Platform-owned graphics contracts. These declarations describe resources
//! and commands without depending on Core resource ownership or engine policy.
pub const mesh = @import("mesh.zig");
pub const texture = @import("texture.zig");
pub const vertex = @import("vertex.zig");
pub const PixelFormat = @import("pixel_format.zig").PixelFormat;
pub const Vertex = vertex.Vertex;
const render_state = @import("render_state.zig");
pub const RenderState = render_state.RenderState;
pub const BlendMode = render_state.BlendMode;
pub const FogState = render_state.FogState;

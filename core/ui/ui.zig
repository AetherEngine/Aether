const std = @import("std");

pub const Color = @import("Color.zig").Color;
pub const layout = @import("layout.zig");
pub const texture_region = @import("texture_region.zig");
pub const Scaling = @import("Scaling.zig");
pub const TextureAtlas = @import("TextureAtlas.zig").TextureAtlas;
pub const SpriteBatcher = @import("SpriteBatcher.zig");
pub const FontBatcher = @import("FontBatcher.zig");
pub const CustomRenderable = @import("custom_renderable.zig");
pub const FlowLayout = @import("FlowLayout.zig");
pub const Context = @import("Context.zig");
pub const State = Context.State;
pub const WidgetStyle = @import("WidgetStyle.zig");
pub const Theme = Context.Style;
pub const DrawList = @import("DrawList.zig");
pub const InputAdapter = @import("InputAdapter.zig");
pub const PromptStrip = @import("PromptStrip.zig");
pub const GlyphProvider = PromptStrip.GlyphProvider;
pub const TextWrap = @import("TextWrap.zig");

pub const Anchor = layout.Anchor;
pub const Point = layout.Point;
pub const LogicalRect = layout.LogicalRect;
pub const TextureRegion = texture_region.TextureRegion;
pub const CenterElide = texture_region.CenterElide;
pub const NineSlice = texture_region.NineSlice;
pub const TextureSizing = texture_region.TextureSizing;

comptime {
    std.testing.refAllDecls(@This());
}

test {
    inline for (.{ FlowLayout, Context, DrawList, InputAdapter, PromptStrip, TextWrap, WidgetStyle }) |module| std.testing.refAllDecls(module);
}

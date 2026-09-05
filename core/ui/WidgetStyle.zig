//! Optional textured widget themes. Coordinates and artwork are application data.
const Color = @import("Color.zig").Color;
const regions = @import("texture_region.zig");
const Rendering = @import("../rendering/rendering.zig");
const DrawList = @import("DrawList.zig");
const layout = @import("layout.zig");

pub const Image = struct { texture: *const Rendering.Texture, region: regions.TextureRegion, sizing: regions.TextureSizing = .stretch };
pub const Paint = struct {
    color: Color = Color.rgba(255, 255, 255, 255),
    image: ?Image = null,
    pub fn draw(self: Paint, list: *DrawList, bounds: layout.LogicalRect) DrawList.Error!void {
        if (self.image) |image| try list.add_region(image.texture, image.region, bounds, self.color, 0, image.sizing) else try list.add_rect(bounds, self.color, 0);
    }
};
pub const Button = struct {
    normal: Paint,
    focused: Paint,
    active: Paint,
    disabled: Paint,
    pub fn paint(self: Button, enabled: bool, focused: bool, active: bool) Paint {
        return if (!enabled) self.disabled else if (active) self.active else if (focused) self.focused else self.normal;
    }
};
pub const Slider = struct { track: Button, knob: Button };
pub const TextField = struct { background: Button };

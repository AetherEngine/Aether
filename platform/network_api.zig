const std = @import("std");
pub const Error = error{ UnsupportedPlatform, UnsupportedOption, NetworkUnavailable, ConfigureFailed, TooManySessions };
pub const StreamOptions = struct {
    /// Null preserves the socket's existing setting.
    no_delay: ?bool = null,
};

pub const Interface = struct {
    prepare: fn () Error!void,
    release: fn () void,
    configure_stream: fn (std.Io.net.Stream, StreamOptions) Error!void,
};

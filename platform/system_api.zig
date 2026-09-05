//! Hardware facts and implemented services, independent of game budgets/policy.
pub const Hardware = enum { desktop, browser, psp_phat, psp_slim, old_3ds, new_3ds, nintendo_switch };

pub const Input = struct {
    pointer: bool = false,
    keyboard: bool = false,
    native_text_entry: bool = false,
    /// Built-in controls only; does not describe hot-plugged controllers.
    built_in_sticks: u2 = 0,
};

pub const Info = struct {
    hardware: Hardware,
    input: Input = .{},
    background_workers: bool = true,
    native_thread_priority: bool = false,
    /// ThreadConfig.io enables explicit inheritance when this is false.
    worker_inherits_cwd: bool = true,
    rename_replaces_destination: bool = true,
    stream_networking: bool = true,
    browser_file_export: bool = false,
};

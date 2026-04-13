// Public API for the macro / unit-cell recognition module.

pub const Transform = @import("types.zig").Transform;
pub const MacroConfig = @import("types.zig").MacroConfig;
pub const MacroTemplate = @import("types.zig").MacroTemplate;
pub const MacroInstance = @import("types.zig").MacroInstance;
pub const MacroArrays = @import("types.zig").MacroArrays;

pub const detectMacros = @import("detect.zig").detectMacros;
pub const detectNamed = @import("detect.zig").detectNamed;
pub const detectStructural = @import("detect.zig").detectStructural;

pub const computeBbox = @import("stamp.zig").computeBbox;
pub const stampAll = @import("stamp.zig").stampAll;

// idx.zig — typed integer index newtype pattern for Zig.
//
// Zig 0.15 does not support `usingnamespace` inside enum bodies, so a shared
// mixin function cannot be injected into multiple enum types.  The idiomatic
// approach is to define each index type explicitly with inline toInt/fromInt:
//
//   pub const DeviceIdx = enum(u32) {
//       _,
//       pub inline fn toInt(self: DeviceIdx) u32 { return @intFromEnum(self); }
//       pub inline fn fromInt(v: u32) DeviceIdx { return @enumFromInt(v); }
//   };
//
// Each declaration at a different source location creates a distinct type, so
// DeviceIdx and NetIdx are incompatible even though both are enum(u32).
//
// The generic Csr(V) in csr.zig accepts any enum(Int) produced this way as
// its value type V.

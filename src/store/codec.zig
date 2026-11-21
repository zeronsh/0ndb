const core_codec = @import("../core/codec.zig");

pub const DecodeError = core_codec.DecodeError;
pub const crc32c = core_codec.crc32c;
pub const Writer = core_codec.Writer;
pub const Reader = core_codec.Reader;

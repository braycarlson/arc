const buffer_module = @import("buffer.zig");
const console = @import("console.zig");
const core_module = @import("core.zig");
const encoding_module = @import("encoding.zig");
const field_module = @import("field.zig");
const json = @import("json.zig");
const level_module = @import("level.zig");
const logger_module = @import("logger.zig");
const observer_module = @import("observer.zig");
const rotating_file_module = @import("rotating_file.zig");
const writer_module = @import("writer.zig");

pub const Core = core_module.Core;
pub const Encoding = encoding_module.Encoding;
pub const Field = field_module.Field;
pub const Level = level_module.Level;
pub const Logger = logger_module.Logger;
pub const Observer = observer_module.Observer;
pub const RotatingFile = rotating_file_module.RotatingFile;
pub const Writer = writer_module.Writer;

pub const limits = struct {
    pub const console_prefix_bytes_max: u32 = console.prefix_bytes_max;
    pub const context_bytes_max: u32 = logger_module.context_bytes_max;
    pub const context_field_count_max: u32 = logger_module.context_field_count_max;
    pub const entry_bytes_max: u32 = buffer_module.entry_bytes_max;
    pub const field_count_max: u32 = field_module.field_count_max;
    pub const key_bytes_max: u32 = field_module.key_bytes_max;
    pub const list_count_max: u32 = field_module.list_count_max;
    pub const name_bytes_max: u32 = logger_module.name_bytes_max;
    pub const namespace_depth_max: u32 = json.namespace_depth_max;
    pub const object_level_max: u32 = json.object_level_max;
    pub const observer_record_count_max: u32 = observer_module.record_count_max;
    pub const rotating_backup_count_max: u32 = rotating_file_module.backup_count_max;
    pub const rotating_path_bytes_max: u32 = rotating_file_module.path_bytes_max;
    pub const sink_count_max: u32 = core_module.sink_count_max;
    pub const text_bytes_max: u32 = field_module.text_bytes_max;
};

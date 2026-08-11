pub const base64 = @import("base64.zig");
pub const config = @import("config.zig");
pub const console = @import("console.zig");
pub const datetime = @import("datetime.zig");
pub const encoder = @import("encoder.zig");
pub const json = @import("json.zig");

pub const encode_base64 = base64.encode_base64;

pub const CallerEncoding = config.CallerEncoding;
pub const ConsoleFieldFormat = config.ConsoleFieldFormat;
pub const DurationEncoding = config.DurationEncoding;
pub const EncoderConfig = config.EncoderConfig;
pub const EncoderConfigError = config.EncoderConfigError;
pub const LevelEncoding = config.LevelEncoding;
pub const LineEnding = config.LineEnding;
pub const TimeEncoding = config.TimeEncoding;
pub const key_name_bytes_max = config.key_name_bytes_max;
pub const omit_key = config.omit_key;

pub const ConsoleEncoder = console.ConsoleEncoder;

pub const write_duration_string = datetime.write_duration_string;
pub const write_epoch_scaled = datetime.write_epoch_scaled;
pub const write_iso8601 = datetime.write_iso8601;
pub const write_iso8601_nano = datetime.write_iso8601_nano;

pub const Encoder = encoder.Encoder;
pub const Encoding = encoder.Encoding;

pub const ArrayEncoder = json.ArrayEncoder;
pub const JsonEncoder = json.JsonEncoder;
pub const ObjectEncoder = json.ObjectEncoder;
pub const marshal_depth_max = json.marshal_depth_max;
pub const namespace_depth_max = json.namespace_depth_max;
pub const reflect_array_max = json.reflect_array_max;
pub const truncation_message = json.truncation_message;

const std = @import("std");
const arc = @import("arc");

const EncoderConfig = arc.EncoderConfig;

test "production encoder config defaults" {
    const cfg = EncoderConfig.production();

    try std.testing.expectEqualStrings("msg", cfg.key_message);
    try std.testing.expectEqualStrings("level", cfg.key_level);
    try std.testing.expectEqualStrings("ts", cfg.key_time);
    try std.testing.expectEqualStrings("logger", cfg.key_name);
    try std.testing.expectEqualStrings("caller", cfg.key_caller);
    try std.testing.expect(!cfg.should_omit_message());
    try std.testing.expect(!cfg.should_omit_level());
    try std.testing.expect(!cfg.should_omit_time());

    std.debug.assert(cfg.key_message.len > 0);
    std.debug.assert(cfg.key_level.len > 0);
}

test "development encoder config defaults" {
    const cfg = EncoderConfig.development();

    try std.testing.expectEqualStrings("M", cfg.key_message);
    try std.testing.expectEqualStrings("L", cfg.key_level);
    try std.testing.expectEqualStrings("T", cfg.key_time);
    try std.testing.expect(cfg.level_uses_color());

    std.debug.assert(cfg.key_message.len > 0);
    std.debug.assert(cfg.level_uses_color());
}

test "omit checks detect empty keys" {
    const cfg = EncoderConfig.production()
        .with_message_key("");

    try std.testing.expect(cfg.should_omit_message());
    try std.testing.expect(!cfg.should_omit_level());

    std.debug.assert(cfg.should_omit_message());
    std.debug.assert(!cfg.should_omit_level());
}

test "validate accepts valid config" {
    const cfg = EncoderConfig.production();

    try cfg.validate();

    std.debug.assert(cfg.key_message.len <= arc.encoder_config_mod.key_name_max);
    std.debug.assert(cfg.key_level.len <= arc.encoder_config_mod.key_name_max);
}

test "level_string returns correct representation" {
    const prod = EncoderConfig.production();
    const dev = EncoderConfig.development();

    try std.testing.expectEqualStrings("info", prod.level_string(.info));
    try std.testing.expectEqualStrings("INFO", dev.level_string(.info));
    try std.testing.expectEqualStrings("error", prod.level_string(.err));
    try std.testing.expectEqualStrings("ERROR", dev.level_string(.err));

    std.debug.assert(prod.level_string(.info).len > 0);
    std.debug.assert(dev.level_string(.info).len > 0);
}

test "color config detection" {
    const prod = EncoderConfig.production();
    const dev = EncoderConfig.development();

    try std.testing.expect(!prod.level_uses_color());
    try std.testing.expect(dev.level_uses_color());

    try std.testing.expectEqualStrings("", prod.level_color_prefix(.info));
    try std.testing.expect(dev.level_color_prefix(.info).len > 0);
    try std.testing.expect(dev.level_color_suffix().len > 0);

    std.debug.assert(!prod.level_uses_color());
    std.debug.assert(dev.level_uses_color());
}

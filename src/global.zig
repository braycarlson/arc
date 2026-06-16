const std = @import("std");
const entry_mod = @import("core/entry.zig");
const sugar_mod = @import("sugar.zig");

const Logger = @import("logger.zig").Logger;
const SugaredLogger = sugar_mod.SugaredLogger;

var default_logger: Logger = Logger.init_nop();
var current_logger: std.atomic.Value(*Logger) = std.atomic.Value(*Logger).init(&default_logger);
var previous_logger: std.atomic.Value(?*Logger) = std.atomic.Value(?*Logger).init(null);
var global_mutex: std.Io.Mutex = .init;

pub fn replace(io: std.Io, new_logger: *Logger) void {
    std.debug.assert(new_logger.name_length <= entry_mod.name_max);

    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    const prior = current_logger.load(.acquire);
    previous_logger.store(prior, .release);
    current_logger.store(new_logger, .release);

    std.debug.assert(current_logger.load(.acquire) == new_logger);
}

pub fn restore(io: std.Io) void {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    const prior = previous_logger.load(.acquire);

    std.debug.assert(prior != null);

    if (prior) |logger_pointer| {
        current_logger.store(logger_pointer, .release);
        previous_logger.store(null, .release);
    }
}

pub fn can_restore(io: std.Io) bool {
    global_mutex.lockUncancelable(io);
    defer global_mutex.unlock(io);

    return previous_logger.load(.acquire) != null;
}

pub fn l() *Logger {
    const logger_pointer = current_logger.load(.acquire);

    std.debug.assert(logger_pointer.name_length <= entry_mod.name_max);

    return logger_pointer;
}

pub fn s() SugaredLogger {
    const logger_pointer = current_logger.load(.acquire);

    std.debug.assert(logger_pointer.name_length <= entry_mod.name_max);

    return SugaredLogger.init(logger_pointer);
}

const std = @import("std");

const bounded = @import("bounded.zig");

const assert = std.debug.assert;
const path = std.Io.Dir.path;

const assert_alias = "const assert = std.debug" ++ ".assert;";
const column_count_max: u32 = 100;
const entry_count_max: u32 = 4096;
const file_bytes_max: u32 = 1024 * 1024;
const file_count_max: u32 = 256;
const finding_count_max: u32 = 1024;
const function_line_count_max: u32 = 70;
const import_count_max: u32 = 128;
const path_bytes_max: u32 = 256;
const registry_path = "src/unit_tests.zig";
const type_suffix = "Type";

const banned_texts = [_][]const u8{
    "!= " ++ "error.",
    "== " ++ "error.",
    "@c" ++ "Import",
    "FIX" ++ "ME",
    "Self = " ++ "@This()",
    "catch " ++ "unreachable",
    "catch " ++ "{}",
    "db" ++ "g(",
    "std.debug" ++ ".assert(",
    "using" ++ "namespace",
};

const control_openers = [_][]const u8{
    "for ",
    "if ",
    "return",
    "switch ",
    "try ",
    "while ",
};

const root_paths = [_][]const u8{
    "benchmarks/bench.zig",
    "benchmarks/soak.zig",
    "examples/log.zig",
    "src/arc.zig",
    "src/fuzz_tests.zig",
    registry_path,
};

const source_directories = [_][]const u8{ "benchmarks", "examples", "src" };

comptime {
    assert(file_count_max <= entry_count_max);
    assert(path_bytes_max < file_bytes_max);
    assert(source_directories.len == 3);
    assert(banned_texts.len == 10);
}

const File = struct {
    imports: Set,
    path: bounded.BoundedArrayType(u8, path_bytes_max),
    tested: bool,
};

const Files = bounded.BoundedArrayType(File, file_count_max);

const Finding = struct {
    line: u32,
    rule: Rule,
    value: u32,
};

const Window = struct {
    before: []const u8,
    previous: []const u8,
};

const ImportStage = enum {
    builtin,
    none,
    parenthesis,
};

const Report = struct {
    findings: bounded.BoundedArrayType(Finding, finding_count_max),
    overflow_count: u32,

    const empty: Report = .{ .findings = .empty, .overflow_count = 0 };

    fn add(report: *Report, finding: Finding) void {
        assert(finding.line > 0);
        assert(report.findings.count <= finding_count_max);

        if (report.findings.full()) {
            report.overflow_count += 1;
        } else {
            report.findings.push_slot_assume_capacity().* = finding;
        }
    }

    fn total(report: *const Report) u32 {
        assert(report.findings.count <= finding_count_max);

        const result = report.findings.count + report.overflow_count;

        assert(result >= report.findings.count);

        return result;
    }
};

const Rule = enum {
    assert_alias,
    banned_text,
    carriage_return,
    column_count,
    dead_file,
    declaration_crowded,
    doc_comment,
    file_name,
    final_newline,
    function_length,
    guard_crowded,
    invalid_utf8,
    parse_error,
    tab,
    test_unregistered,
    trailing_whitespace,
    type_function_name,
};

const Scan = struct {
    imports: bounded.BoundedArrayType([]const u8, import_count_max),
    stage: ImportStage,
    tested: bool,

    const empty: Scan = .{ .imports = .empty, .stage = .none, .tested = false };

    fn token_feed(scan: *Scan, token: std.zig.Token, source: []const u8) bounded.Error!void {
        assert(token.loc.start <= token.loc.end);
        assert(token.loc.end <= source.len);

        const text = source[token.loc.start..token.loc.end];

        switch (token.tag) {
            .builtin => scan.stage = if (std.mem.eql(u8, text, "@import")) .builtin else .none,
            .keyword_test => {
                scan.stage = .none;
                scan.tested = true;
            },
            .l_paren => scan.stage = if (scan.stage == .builtin) .parenthesis else .none,
            .string_literal => {
                if (scan.stage == .parenthesis) try scan.import_record(text);

                scan.stage = .none;
            },
            else => scan.stage = .none,
        }
    }

    fn import_record(scan: *Scan, literal: []const u8) bounded.Error!void {
        assert(literal.len >= 2);
        assert(literal[0] == '"');

        const name = literal[1 .. literal.len - 1];
        if (!std.mem.endsWith(u8, name, ".zig")) return;

        const slot = try scan.imports.push_slot();

        slot.* = name;
    }
};

const Set = std.StaticBitSet(file_count_max);

const Tidy = struct {
    buffer: [file_bytes_max + 2]u8,
    files: Files,
    gpa: std.mem.Allocator,
    io: std.Io,
    report: Report,
    scan: Scan,

    fn files_tidy(tidy: *Tidy) !u32 {
        assert(tidy.files.count > 0);
        assert(tidy.files.count <= file_count_max);

        var finding_count: u32 = 0;

        for (0..tidy.files.count) |position| {
            const index: u32 = @intCast(position);
            const file = tidy.files.get_mutable(index);

            finding_count += try tidy.file_tidy(file.path.slice());
            file.tested = tidy.scan.tested;

            try imports_resolve(tidy.gpa, &tidy.files, index, tidy.scan.imports.slice());
        }

        return finding_count;
    }

    fn file_tidy(tidy: *Tidy, file_path: []const u8) !u32 {
        assert(file_path.len > 0);
        assert(file_path.len < path_bytes_max);

        const source = try source_read(tidy.io, file_path, &tidy.buffer);

        tidy.report = .empty;
        tidy.scan = .empty;

        try source_check(tidy.gpa, source, &tidy.report, &tidy.scan);

        file_name_check(path.basenamePosix(file_path), &tidy.report);
        report_print(&tidy.report, file_path);

        return tidy.report.total();
    }
};

fn files_collect(gpa: std.mem.Allocator, io: std.Io, files: *Files) !void {
    assert(files.count == 0);
    assert(files.buffer.len == file_count_max);

    for (source_directories) |source_directory| {
        try directory_collect(gpa, io, files, source_directory);
    }

    assert(files.count > 0);
}

fn directory_collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    files: *Files,
    source_directory: []const u8,
) !void {
    assert(source_directory.len > 0);
    assert(files.count <= file_count_max);

    const directory = try std.Io.Dir.cwd().openDir(io, source_directory, .{
        .access_sub_paths = true,
        .follow_symlinks = true,
        .iterate = true,
    });

    defer directory.close(io);

    var walker = try directory.walk(gpa);
    defer walker.deinit();

    var entry_count: u32 = 0;

    while (try walker.next(io)) |entry| {
        entry_count += 1;

        if (entry_count > entry_count_max) return error.EntriesTooMany;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const file = try files.push_slot();

        file.* = .{ .imports = .empty, .path = .empty, .tested = false };

        try file.path.print("{s}/{s}", .{ source_directory, entry.path });
        std.mem.replaceScalar(u8, file.path.slice_mutable(), path.sep, '/');
    }
}

fn graph_check(files: *const Files) u32 {
    assert(files.count > 0);
    assert(files.count <= file_count_max);

    const reached = reachable(files, &root_paths);
    const registered = reachable(files, &.{registry_path});

    var finding_count: u32 = 0;

    for (files.slice(), 0..) |*file, index| {
        if (!reached.isSet(index)) {
            std.debug.print("{s}: {t}\n", .{ file.path.slice(), Rule.dead_file });
            finding_count += 1;
        }

        if (file.tested) {
            if (!registered.isSet(index)) {
                std.debug.print("{s}: {t}\n", .{ file.path.slice(), Rule.test_unregistered });
                finding_count += 1;
            }
        }
    }

    return finding_count;
}

fn reachable(files: *const Files, roots: []const []const u8) Set {
    assert(roots.len > 0);
    assert(files.count <= file_count_max);

    var result: Set = .empty;

    for (roots) |root| {
        if (file_find(files, root)) |index| result.set(index);
    }

    var round: u32 = 0;

    while (round < files.count) : (round += 1) {
        const before = result.count();

        for (files.slice(), 0..) |*file, index| {
            if (result.isSet(index)) result.setUnion(file.imports);
        }

        if (result.count() == before) break;
    }

    assert(result.count() <= files.count);

    return result;
}

fn imports_resolve(
    gpa: std.mem.Allocator,
    files: *Files,
    index: u32,
    imports: []const []const u8,
) !void {
    assert(index < files.count);
    assert(imports.len <= import_count_max);

    const file = files.get_mutable(index);
    const directory = path.dirnamePosix(file.path.slice()) orelse ".";

    for (imports) |import| {
        const resolved = try path.resolveAllocPosix(gpa, &.{ directory, import });
        defer gpa.free(resolved);

        if (file_find(files, resolved)) |target| file.imports.set(target);
    }
}

fn file_find(files: *const Files, file_path: []const u8) ?u32 {
    assert(file_path.len > 0);
    assert(files.count <= file_count_max);

    for (files.slice(), 0..) |*file, index| {
        if (std.mem.eql(u8, file.path.slice(), file_path)) {
            const result: u32 = @intCast(index);

            assert(result < files.count);

            return result;
        }
    }

    return null;
}

fn source_read(io: std.Io, file_path: []const u8, buffer: *[file_bytes_max + 2]u8) ![:0]const u8 {
    assert(file_path.len > 0);
    assert(file_path.len < path_bytes_max);

    const content = try std.Io.Dir.cwd().readFile(io, file_path, buffer[0 .. file_bytes_max + 1]);
    if (content.len > file_bytes_max) return error.FileTooLarge;

    buffer[content.len] = 0;

    const result = buffer[0..content.len :0];

    assert(result.len <= file_bytes_max);

    return result;
}

fn source_check(gpa: std.mem.Allocator, source: [:0]const u8, report: *Report, scan: *Scan) !void {
    assert(source.len <= file_bytes_max);
    assert(report.total() == 0);

    lines_check(source, report);
    banned_check(source, report);
    assert_alias_check(source, report);
    breathing_check(source, report);

    try tokens_check(source, report, scan);
    try functions_check(gpa, source, report);
}

fn lines_check(source: []const u8, report: *Report) void {
    assert(source.len <= file_bytes_max);
    assert(report.findings.count <= finding_count_max);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 0;

    while (lines.next()) |line| {
        line_number += 1;

        assert(line_number <= source.len + 1);

        line_check(line, line_number, report);
    }

    if (!std.mem.endsWith(u8, source, "\n")) {
        report.add(.{ .line = line_number, .rule = .final_newline, .value = 0 });
    } else if (std.mem.endsWith(u8, source, "\n\n")) {
        report.add(.{ .line = line_number - 1, .rule = .final_newline, .value = 0 });
    } else {}
}

fn line_check(line: []const u8, line_number: u32, report: *Report) void {
    assert(line.len <= file_bytes_max);
    assert(line_number > 0);

    if (std.mem.findScalar(u8, line, '\t') != null) {
        report.add(.{ .line = line_number, .rule = .tab, .value = 0 });
    }

    if (std.mem.findScalar(u8, line, '\r') != null) {
        report.add(.{ .line = line_number, .rule = .carriage_return, .value = 0 });
    }

    if (std.mem.endsWith(u8, line, " ")) {
        report.add(.{ .line = line_number, .rule = .trailing_whitespace, .value = 0 });
    }

    const column_count = std.unicode.utf8CountCodepoints(line) catch {
        report.add(.{ .line = line_number, .rule = .invalid_utf8, .value = 0 });

        return;
    };

    if (column_count > column_count_max) {
        const value: u32 = @intCast(column_count);

        report.add(.{ .line = line_number, .rule = .column_count, .value = value });
    }
}

fn banned_check(source: []const u8, report: *Report) void {
    assert(source.len <= file_bytes_max);
    assert(report.findings.count <= finding_count_max);

    for (banned_texts) |banned| {
        var cursor: u32 = 0;

        while (std.mem.findPos(u8, source, cursor, banned)) |offset| {
            assert(offset >= cursor);

            const line = line_of(source, @intCast(offset));

            report.add(.{ .line = line, .rule = .banned_text, .value = 0 });
            cursor = @intCast(offset + banned.len);
        }
    }
}

fn assert_alias_check(source: []const u8, report: *Report) void {
    assert(source.len <= file_bytes_max);
    assert(assert_alias.len > 0);

    if (std.mem.find(u8, source, "assert(") == null) return;
    if (std.mem.find(u8, source, assert_alias) != null) return;

    report.add(.{ .line = 1, .rule = .assert_alias, .value = 0 });
}

fn breathing_check(source: []const u8, report: *Report) void {
    assert(source.len <= file_bytes_max);
    assert(report.findings.count <= finding_count_max);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var window: Window = .{ .before = "", .previous = "" };
    var line_number: u32 = 0;

    while (lines.next()) |line| {
        line_number += 1;

        assert(line_number <= source.len + 1);

        if (indent_of(line) == indent_of(window.previous)) {
            if (declaration_crowds(&window, line)) {
                report.add(.{ .line = line_number, .rule = .declaration_crowded, .value = 0 });
            }

            if (guard_is(window.previous)) {
                if (statement_follows_guard(line)) {
                    report.add(.{ .line = line_number, .rule = .guard_crowded, .value = 0 });
                }
            }
        }

        window = .{ .before = window.previous, .previous = line };
    }
}

fn declaration_crowds(window: *const Window, line: []const u8) bool {
    assert(line.len <= file_bytes_max);
    assert(window.previous.len <= file_bytes_max);

    if (!declaration_is(window.previous)) return false;
    if (!control_is(line)) return false;

    const trimmed = std.mem.trim(u8, line, " ");

    if (std.mem.startsWith(u8, trimmed, "if ")) {
        if (std.mem.endsWith(u8, trimmed, ";")) return std.mem.findScalar(u8, trimmed, '{') != null;
    }

    if (std.mem.startsWith(u8, trimmed, "return")) {
        if (indent_of(window.before) != indent_of(line)) return false;
        return declaration_is(window.before);
    }

    return true;
}

fn indent_of(line: []const u8) u32 {
    assert(line.len <= file_bytes_max);

    const result: u32 = @intCast(line.len - std.mem.trimStart(u8, line, " ").len);

    assert(result <= line.len);

    return result;
}

fn declaration_is(line: []const u8) bool {
    assert(line.len <= file_bytes_max);

    const trimmed = std.mem.trim(u8, line, " ");
    if (!std.mem.endsWith(u8, trimmed, ";")) return false;
    if (std.mem.startsWith(u8, trimmed, "const ")) return true;
    return std.mem.startsWith(u8, trimmed, "var ");
}

fn control_is(line: []const u8) bool {
    assert(line.len <= file_bytes_max);

    const trimmed = std.mem.trim(u8, line, " ");

    for (control_openers) |opener| {
        if (std.mem.startsWith(u8, trimmed, opener)) return true;
    }

    return false;
}

fn guard_is(line: []const u8) bool {
    assert(line.len <= file_bytes_max);

    const trimmed = std.mem.trim(u8, line, " ");
    if (!std.mem.endsWith(u8, trimmed, ";")) return false;
    if (std.mem.startsWith(u8, trimmed, "defer ")) return true;
    return std.mem.startsWith(u8, trimmed, "errdefer ");
}

fn statement_follows_guard(line: []const u8) bool {
    assert(line.len <= file_bytes_max);

    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '}') return false;
    return !guard_is(line);
}

fn file_name_check(basename: []const u8, report: *Report) void {
    assert(basename.len > 0);
    assert(basename.len < path_bytes_max);

    if (!std.mem.endsWith(u8, basename, ".zig")) return;

    const stem = basename[0 .. basename.len - ".zig".len];

    for (stem) |byte| {
        if (std.ascii.isLower(byte)) continue;
        if (std.ascii.isDigit(byte)) continue;
        if (byte == '_') continue;

        report.add(.{ .line = 1, .rule = .file_name, .value = 0 });

        return;
    }
}

fn tokens_check(source: [:0]const u8, report: *Report, scan: *Scan) bounded.Error!void {
    assert(source.len <= file_bytes_max);
    assert(scan.imports.count == 0);

    var tokenizer = std.zig.Tokenizer.init(source);
    var token_count: u32 = 0;
    var function_keyword = false;

    while (token_count <= source.len) : (token_count += 1) {
        const token = tokenizer.next();
        const text = source[token.loc.start..token.loc.end];

        switch (token.tag) {
            .container_doc_comment, .doc_comment => report.add(.{
                .line = line_of(source, @intCast(token.loc.start)),
                .rule = .doc_comment,
                .value = 0,
            }),
            .eof => break,
            .identifier => if (function_keyword) type_function_check(source, token, report),
            else => {},
        }

        function_keyword = token.tag == .keyword_fn;

        assert(text.len <= source.len);

        try scan.token_feed(token, source);
    }

    assert(token_count <= source.len);
}

fn type_function_check(source: []const u8, token: std.zig.Token, report: *Report) void {
    assert(token.tag == .identifier);
    assert(token.loc.end <= source.len);

    const name = source[token.loc.start..token.loc.end];
    if (!std.ascii.isUpper(name[0])) return;
    if (std.mem.endsWith(u8, name, type_suffix)) return;

    report.add(.{
        .line = line_of(source, @intCast(token.loc.start)),
        .rule = .type_function_name,
        .value = 0,
    });
}

fn functions_check(
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    report: *Report,
) error{OutOfMemory}!void {
    assert(source.len <= file_bytes_max);
    assert(report.findings.count <= finding_count_max);

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig, .recover = true });
    defer tree.deinit(gpa);

    if (tree.errors.len > 0) {
        const line = token_line(&tree, tree.errors[0].token);

        report.add(.{ .line = line, .rule = .parse_error, .value = 0 });

        return;
    }

    for (tree.nodes.items(.tag), 0..) |tag, index| {
        if (tag != .fn_decl) continue;

        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (function_returns_type(&tree, node)) continue;

        const line_first = token_line(&tree, tree.firstToken(node));
        const line_last = token_line(&tree, tree.lastToken(node));
        const line_count = line_last - line_first + 1;

        if (line_count > function_line_count_max) {
            report.add(.{ .line = line_first, .rule = .function_length, .value = line_count });
        }
    }
}

fn function_returns_type(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    assert(tree.nodeTag(node) == .fn_decl);
    assert(tree.errors.len == 0);

    var buffer: [1]std.zig.Ast.Node.Index = undefined;

    const prototype = tree.fullFnProto(&buffer, node) orelse return false;
    const return_type = prototype.ast.return_type.unwrap() orelse return false;
    if (tree.nodeTag(return_type) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_type)), "type");
}

fn token_line(tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) u32 {
    assert(token < tree.tokens.len);
    assert(tree.source.len <= file_bytes_max);

    const result = line_of(tree.source, tree.tokenStart(token));

    assert(result > 0);

    return result;
}

fn line_of(source: []const u8, offset: u32) u32 {
    assert(offset <= source.len);
    assert(source.len <= file_bytes_max);

    const result: u32 = @intCast(std.mem.countScalar(u8, source[0..offset], '\n') + 1);

    assert(result <= offset + 1);

    return result;
}

fn report_print(report: *const Report, file_path: []const u8) void {
    assert(file_path.len > 0);
    assert(report.findings.count <= finding_count_max);

    for (report.findings.slice()) |*finding| {
        if (finding.value == 0) {
            std.debug.print("{s}:{d}: {t}\n", .{ file_path, finding.line, finding.rule });
        } else {
            std.debug.print("{s}:{d}: {t} {d}\n", .{
                file_path,
                finding.line,
                finding.rule,
                finding.value,
            });
        }
    }

    if (report.overflow_count > 0) {
        std.debug.print("{s}: {d} more findings\n", .{ file_path, report.overflow_count });
    }
}

const testing = std.testing;

const test_source_bytes_max: u32 = 16 * 1024;

fn test_check(source: [:0]const u8, report: *Report, scan: *Scan) !void {
    assert(source.len > 0);
    assert(source.len <= test_source_bytes_max);

    report.* = .empty;
    scan.* = .empty;

    try source_check(testing.allocator, source, report, scan);
}

fn test_expect(report: *const Report, expected: []const Finding) !void {
    assert(expected.len > 0);
    assert(report.overflow_count == 0);

    try testing.expectEqualSlices(Finding, expected, report.findings.slice());
}

fn test_terminate(writer: *std.Io.Writer) ![:0]const u8 {
    assert(writer.buffer.len > 0);
    assert(writer.buffered().len < writer.buffer.len);

    try writer.writeByte(0);

    const written = writer.buffered();
    const result = written[0 .. written.len - 1 :0];

    assert(result.len + 1 == written.len);

    return result;
}

test "build.zig and every source file are tidy" {
    const tidy = try testing.allocator.create(Tidy);
    defer testing.allocator.destroy(tidy);

    tidy.files = .empty;
    tidy.gpa = testing.allocator;
    tidy.io = testing.io;

    try files_collect(testing.allocator, testing.io, &tidy.files);

    const build_finding_count = try tidy.file_tidy("build.zig");
    const source_finding_count = try tidy.files_tidy();
    const graph_finding_count = graph_check(&tidy.files);

    try testing.expectEqual(@as(u32, 0), build_finding_count);
    try testing.expectEqual(@as(u32, 0), source_finding_count);
    try testing.expectEqual(@as(u32, 0), graph_finding_count);
}

test "a doc comment is found between tokens and never inside a string" {
    const source =
        \\//! container
        \\const url = "https://example.com";
        \\const text =
        \\    \\/// inside a multiline string
        \\;
        \\const value = 1; // trailing
        \\/// documentation
        \\const other = 2;
        \\
    ;

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 1, .rule = .doc_comment, .value = 0 },
        .{ .line = 7, .rule = .doc_comment, .value = 0 },
    });
}

test "tabs, carriage returns, trailing spaces, wide lines, and a missing newline are found" {
    var buffer: [test_source_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("const\ttab = 1;\n");
    try writer.writeAll("const carriage = 2;\r\n");
    try writer.writeAll("const trailing = 3; \n");
    try writer.writeAll("const wide = \"");
    try writer.splatByteAll('x', 85);
    try writer.writeAll("\";\nconst narrow = \"");
    try writer.splatBytesAll("\u{21b5}", 82);
    try writer.writeAll("\";");

    const source = try test_terminate(&writer);

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 1, .rule = .tab, .value = 0 },
        .{ .line = 2, .rule = .carriage_return, .value = 0 },
        .{ .line = 3, .rule = .trailing_whitespace, .value = 0 },
        .{ .line = 4, .rule = .column_count, .value = 101 },
        .{ .line = 5, .rule = .final_newline, .value = 0 },
    });
}

test "a file ends with exactly one newline" {
    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check("const value = 1;\n", &report, &scan);
    try testing.expectEqual(@as(u32, 0), report.total());

    try test_check("const value = 1;\n\n", &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 2, .rule = .final_newline, .value = 0 },
    });
}

test "a function over seventy lines is found and one of exactly seventy is not" {
    var buffer: [test_source_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("fn seventy() void {\n");
    try writer.splatBytesAll("    _ = 0;\n", 68);
    try writer.writeAll("}\n\nfn seventy_one() void {\n");
    try writer.splatBytesAll("    _ = 0;\n", 69);
    try writer.writeAll("}\n");

    const source = try test_terminate(&writer);

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 72, .rule = .function_length, .value = 71 },
    });
}

test "a function that returns a type is measured by its methods rather than as a whole" {
    var buffer: [test_source_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("fn GenericType() type {\n    return struct {\n");
    try writer.writeAll("        fn method() void {\n");
    try writer.splatBytesAll("            _ = 0;\n", 69);
    try writer.writeAll("        }\n    };\n}\n");

    const source = try test_terminate(&writer);

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 3, .rule = .function_length, .value = 71 },
    });
}

test "banned text is found anywhere in the source, strings included" {
    const source = "const a = std.debug" ++ ".assert(true);\n" ++
        "const b = c catch " ++ "unreachable;\n" ++
        "const Self = " ++ "@This();\n" ++
        "const d = \"using" ++ "namespace\";\n" ++
        "const e = f == " ++ "error.Bad;\n";

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 5, .rule = .banned_text, .value = 0 },
        .{ .line = 3, .rule = .banned_text, .value = 0 },
        .{ .line = 2, .rule = .banned_text, .value = 0 },
        .{ .line = 1, .rule = .banned_text, .value = 0 },
        .{ .line = 4, .rule = .banned_text, .value = 0 },
        .{ .line = 1, .rule = .assert_alias, .value = 0 },
    });
}

test "a declaration or a defer crowded by the next step is found" {
    const source =
        \\fn crowded() u32 {
        \\    const value = 1;
        \\    if (value > 0) return 0;
        \\    defer cleanup();
        \\    work();
        \\    defer cleanup();
        \\    errdefer undo();
        \\
        \\    const other = 2;
        \\    for (items) |item| work(item);
        \\
        \\    const first = 3;
        \\    const second = 4;
        \\    return first + second;
        \\
        \\    const fed = 5;
        \\    return fed;
        \\}
        \\
    ;

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    try test_expect(&report, &.{
        .{ .line = 5, .rule = .guard_crowded, .value = 0 },
        .{ .line = 10, .rule = .declaration_crowded, .value = 0 },
        .{ .line = 14, .rule = .declaration_crowded, .value = 0 },
    });
}

test "a type function must end in Type and a file name must be snake case" {
    const source =
        \\fn ListType(comptime T: type) type {
        \\    return []T;
        \\}
        \\
        \\fn Buffer(comptime T: type) type {
        \\    return []T;
        \\}
        \\
    ;

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);

    file_name_check("TitleCase.zig", &report);
    file_name_check("snake_case_2.zig", &report);

    try test_expect(&report, &.{
        .{ .line = 5, .rule = .type_function_name, .value = 0 },
        .{ .line = 1, .rule = .file_name, .value = 0 },
    });
}

test "imports of zig files and test declarations are recorded" {
    const source =
        \\const std = @import("std");
        \\const contract = @import("../contract.zig");
        \\const menu = @import("menu.zig");
        \\const text = "@import(\"fake.zig\")";
        \\test "a test" {}
        \\
    ;

    var report: Report = undefined;
    var scan: Scan = undefined;

    try test_check(source, &report, &scan);
    try testing.expectEqual(@as(u32, 0), report.total());
    try testing.expect(scan.tested);
    try testing.expectEqual(@as(u32, 2), scan.imports.count);
    try testing.expectEqualStrings("../contract.zig", scan.imports.get(0).*);
    try testing.expectEqualStrings("menu.zig", scan.imports.get(1).*);
}

test "imports resolve against the importing directory and reach files transitively" {
    const files = try testing.allocator.create(Files);
    defer testing.allocator.destroy(files);

    files.* = .empty;

    const file_paths = [_][]const u8{
        "src/main.zig",
        "src/menu.zig",
        "src/platform/contract.zig",
        "src/platform/linux/process.zig",
        "src/orphan.zig",
    };

    for (file_paths) |file_path| {
        const file = try files.push_slot();

        file.* = .{ .imports = .empty, .path = .empty, .tested = false };

        try file.path.set(file_path);
    }

    try imports_resolve(testing.allocator, files, 0, &.{"menu.zig"});
    try imports_resolve(testing.allocator, files, 1, &.{"platform/linux/process.zig"});
    try imports_resolve(testing.allocator, files, 3, &.{ "../contract.zig", "../../menu.zig" });
    try imports_resolve(testing.allocator, files, 4, &.{"main.zig"});

    const reached = reachable(files, &.{"src/main.zig"});

    try testing.expect(files.get(3).imports.isSet(1));
    try testing.expect(files.get(3).imports.isSet(2));
    try testing.expect(reached.isSet(0));
    try testing.expect(reached.isSet(1));
    try testing.expect(reached.isSet(2));
    try testing.expect(reached.isSet(3));
    try testing.expect(!reached.isSet(4));
}

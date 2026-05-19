//! HBCF — Hash-Block Configuration Format parser.
//! Zero-allocation. Two APIs:
//!   * `parse`          — streaming, callback-based, runtime.
//!   * `parseInto(T,..)`— typed, field-driven, no callbacks; uses `>blocks` as
//!                        nested structs and `key = value` as fields.
//!   * `parseComptime`  — same as `parseInto` but evaluated at comptime.

const std = @import("std");

pub const Error = error{
    OrphanKeyValue,
    InvalidSyntax,
    UnknownBlock,
    UnknownKey,
    DuplicateBlock,
    InvalidValue,
    ListTooLong,
};

pub const Entry = struct {
    block: []const u8,
    key: []const u8,
    value: []const u8,
    /// 1-indexed line of the key in the source.
    line: u32,
};

// ─────────────────────────────────────────────────────────────────────────────
// Utility functions
// ─────────────────────────────────────────────────────────────────────────────

fn trimLine(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    if (start >= end) return "";
    return s[start..end];
}

// ─────────────────────────────────────────────────────────────────────────────
// Low-level line iterator. Zero-alloc. Branch-light.
// ─────────────────────────────────────────────────────────────────────────────

pub const Iterator = struct {
    src: []const u8,
    cursor: usize = 0,
    line: u32 = 0,
    block: []const u8 = "",
    /// Tracks whether we've seen a `>block` header yet. Used to flag orphans.
    in_block: bool = false,

    pub const Item = union(enum) {
        block: []const u8,
        pair: Entry,
    };

    pub fn init(source: []const u8) Iterator {
        return .{ .src = source };
    }

    /// Returns the next semantic item, or null at EOF. Errors on malformed input.
    pub fn next(self: *Iterator) Error!?Item {
        while (self.cursor < self.src.len) {
            self.line += 1;

            // Find end of physical line.
            const nl = std.mem.indexOfScalarPos(u8, self.src, self.cursor, '\n') orelse self.src.len;
            var raw_line = self.src[self.cursor..nl];
            self.cursor = nl + 1;

            // Strip CR for CRLF.
            if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') raw_line = raw_line[0 .. raw_line.len - 1];

            // Strip inline comment.
            if (std.mem.indexOfScalar(u8, raw_line, '#')) |h| raw_line = raw_line[0..h];

            // Trim horizontal whitespace.
            const line = trimLine(raw_line);
            if (line.len == 0) continue;

            if (line[0] == '>') {
                const ident = trimLine(line[1..]);
                if (ident.len == 0) return Error.InvalidSyntax;
                if (!isValidIdent(ident)) return Error.InvalidSyntax;
                self.block = ident;
                self.in_block = true;
                return Item{ .block = ident };
            }

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return Error.InvalidSyntax;
            const key = trimLine(line[0..eq]);
            const val = trimLine(line[eq + 1 ..]);
            if (key.len == 0) return Error.InvalidSyntax;
            if (!isValidIdent(key)) return Error.InvalidSyntax;

            // Allow root-level pairs; assign them to a default "" block
            if (!self.in_block) {
                self.block = "";
            }

            return Item{ .pair = .{
                .block = self.block,
                .key = key,
                .value = val,
                .line = self.line,
            } };
        }
        return null;
    }
};

inline fn isValidIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    // First char must be a letter (per EBNF: `char`).
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Callback API — closest to the spec's reference implementation, but with
// validation and a line counter.
// ─────────────────────────────────────────────────────────────────────────────

pub const Callback = *const fn (entry: Entry) void;

pub fn parse(source: []const u8, cb: Callback) Error!void {
    var it = Iterator.init(source);
    while (try it.next()) |item| switch (item) {
        .block => {},
        .pair => |e| cb(e),
    };
}

/// Stateful callback (closure-style without allocations).
pub fn parseCtx(
    source: []const u8,
    comptime Ctx: type,
    ctx: Ctx,
    comptime cb: fn (Ctx, Entry) Error!void,
) Error!void {
    var it = Iterator.init(source);
    while (try it.next()) |item| switch (item) {
        .block => {},
        .pair => |e| try cb(ctx, e),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Value coercion.
// ─────────────────────────────────────────────────────────────────────────────

pub fn parseValue(comptime T: type, raw: []const u8) Error!T {
    const info = @typeInfo(T);
    return switch (info) {
        .bool => parseBool(raw),
        .int => std.fmt.parseInt(T, raw, 0) catch Error.InvalidValue,
        .float => std.fmt.parseFloat(T, raw) catch Error.InvalidValue,
        .@"enum" => std.meta.stringToEnum(T, raw) orelse Error.InvalidValue,
        .pointer => |p| blk: {
            // Only []const u8 is supported as a "string" target.
            if (p.size == .slice and p.child == u8 and p.is_const) break :blk raw;
            @compileError("unsupported pointer type: " ++ @typeName(T));
        },
        .optional => |o| if (raw.len == 0) null else try parseValue(o.child, raw),
        else => @compileError("unsupported field type: " ++ @typeName(T)),
    };
}

fn parseBool(raw: []const u8) Error!bool {
    // Lowercase compare — small fixed set, no alloc.
    if (eqIgnoreAscii(raw, "true") or eqIgnoreAscii(raw, "yes") or std.mem.eql(u8, raw, "1"))
        return true;
    if (eqIgnoreAscii(raw, "false") or eqIgnoreAscii(raw, "no") or std.mem.eql(u8, raw, "0"))
        return false;
    return Error.InvalidValue;
}

fn eqIgnoreAscii(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Parse a comma-separated value into a caller-provided fixed-size buffer.
/// Returns the populated slice (a sub-slice of `out`). No allocation.
pub fn parseList(out: [][]const u8, raw: []const u8) Error![][]const u8 {
    if (raw.len == 0) return out[0..0];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        if (n == out.len) return Error.ListTooLong;
        out[n] = trimLine(part);
        n += 1;
    }
    return out[0..n];
}

// ─────────────────────────────────────────────────────────────────────────────
// Typed API — `parseInto(T, source, &out)`.
//
// `T` describes the schema. Top-level fields are *blocks*; each block field
// must be a struct whose fields are the keys. Field types may be any type
// supported by `parseValue` plus arrays of those. List values use comma
// separation; the array length caps the maximum list size.
// ─────────────────────────────────────────────────────────────────────────────

pub fn parseInto(comptime T: type, source: []const u8, out: *T) Error!void {
    const ti = @typeInfo(T);
    if (ti != .@"struct") @compileError("parseInto target must be a struct");

    // Track which blocks have been opened (to reject duplicates per spec §2.2).
    var seen_block = [_]bool{false} ** ti.@"struct".fields.len;
    // Per-block counts for array fields (so each comma-list lands in order).
    // We re-zero on every fresh block open.

    var it = Iterator.init(source);
    var active_block: i32 = -1;

    while (try it.next()) |item| switch (item) {
        .block => |name| {
            active_block = -1;
            inline for (ti.@"struct".fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) {
                    if (seen_block[i]) return Error.DuplicateBlock;
                    seen_block[i] = true;
                    active_block = @intCast(i);
                }
            }
            if (active_block < 0) return Error.UnknownBlock;
        },
        .pair => |e| {
            // Dispatch into the matching block struct.
            var matched = false;
            inline for (ti.@"struct".fields, 0..) |bf, bi| {
                if (active_block == @as(i32, @intCast(bi))) {
                    try assignField(bf.type, &@field(out.*, bf.name), e.key, e.value);
                    matched = true;
                }
            }
            if (!matched) unreachable; // active_block is always set by .block branch
        },
    };
}

fn assignField(
    comptime Block: type,
    block_ptr: *Block,
    key: []const u8,
    raw: []const u8,
) Error!void {
    const bi = @typeInfo(Block);
    if (bi != .@"struct") @compileError("block field must be a struct: " ++ @typeName(Block));

    inline for (bi.@"struct".fields) |kf| {
        if (std.mem.eql(u8, kf.name, key)) {
            const FT = kf.type;
            const fti = @typeInfo(FT);
            switch (fti) {
                .array => |arr| {
                    // Fixed-size list. Fill in declaration order.
                    var buf: [arr.len][]const u8 = undefined;
                    const parts = try parseList(buf[0..], raw);
                    if (parts.len > arr.len) return Error.ListTooLong;
                    var dst: [arr.len]arr.child = undefined;
                    for (parts, 0..) |p, idx| dst[idx] = try parseValue(arr.child, p);
                    // Zero/empty-fill the tail so the consumer can detect length
                    // via a sentinel if `arr.child == []const u8`.
                    if (arr.child == []const u8) {
                        var idx = parts.len;
                        while (idx < arr.len) : (idx += 1) dst[idx] = "";
                    }
                    @field(block_ptr.*, kf.name) = dst;
                    return;
                },
                else => {
                    @field(block_ptr.*, kf.name) = try parseValue(FT, raw);
                    return;
                },
            }
        }
    }
    return Error.UnknownKey;
}

/// Same as `parseInto`, but the source is known at comptime so the result
/// itself is a comptime value. Useful for embedding a config blob:
///   const cfg = comptime hbcf.parseComptime(Config, @embedFile("project.hbcf"));
pub fn parseComptime(comptime T: type, comptime source: []const u8) T {
    comptime {
        var out: T = undefined;
        // Zero-initialize defaults: any field without a default will be left
        // undefined and must be set by the source.
        // (We rely on field defaults in the user's struct definition.)
        parseInto(T, source, &out) catch |e| @compileError(
            "HBCF parse error at comptime: " ++ @errorName(e),
        );
        return out;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dynamic / allocating API — `parseIntoAlloc(T, allocator, source, &out)`.
//
// Same schema convention as `parseInto`, but slice fields are heap-allocated
// so list sizes are unbounded:
//
//   []const u8         → string (borrowed from `source`, not allocated)
//   [N]T               → fixed-size list (no allocation, as in `parseInto`)
//   [][]const u8       → dynamic list of strings (one allocation)
//   []T (T ≠ u8)       → dynamic list of values  (one allocation)
//
// Strings always borrow from `source`; keep the source buffer alive for the
// lifetime of the parsed struct. Free everything with `freeAlloc`.
// ─────────────────────────────────────────────────────────────────────────────

pub const AllocError = Error || std.mem.Allocator.Error;

/// Returns true for `[]T` where T is anything *other than* `u8` w/ const.
/// I.e. a slice we want to treat as a dynamic list, not a borrowed string.
fn isDynamicList(comptime FT: type) bool {
    const ti = @typeInfo(FT);
    if (ti != .pointer) return false;
    if (ti.pointer.size != .slice) return false;
    // `[]const u8` is reserved for strings.
    if (ti.pointer.child == u8 and ti.pointer.is_const) return false;
    return true;
}

pub fn parseIntoAlloc(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: []const u8,
    out: *T,
) AllocError!void {
    const ti = @typeInfo(T);
    if (ti != .@"struct") @compileError("parseIntoAlloc target must be a struct");

    var seen_block = [_]bool{false} ** ti.@"struct".fields.len;
    var it = Iterator.init(source);
    var active_block: i32 = -1;

    while (try it.next()) |item| switch (item) {
        .block => |name| {
            active_block = -1;
            inline for (ti.@"struct".fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, name)) {
                    if (seen_block[i]) return Error.DuplicateBlock;
                    seen_block[i] = true;
                    active_block = @intCast(i);
                }
            }
            if (active_block < 0) return Error.UnknownBlock;
        },
        .pair => |e| {
            var matched = false;
            inline for (ti.@"struct".fields, 0..) |bf, bi| {
                if (active_block == @as(i32, @intCast(bi))) {
                    try assignFieldAlloc(bf.type, &@field(out.*, bf.name), allocator, e.key, e.value);
                    matched = true;
                }
            }
            if (!matched) unreachable;
        },
    };
}

fn assignFieldAlloc(
    comptime Block: type,
    block_ptr: *Block,
    allocator: std.mem.Allocator,
    key: []const u8,
    raw: []const u8,
) AllocError!void {
    const bi = @typeInfo(Block);
    if (bi != .@"struct") @compileError("block field must be a struct: " ++ @typeName(Block));

    inline for (bi.@"struct".fields) |kf| {
        if (std.mem.eql(u8, kf.name, key)) {
            const FT = kf.type;
            const fti = @typeInfo(FT);

            if (comptime isDynamicList(FT)) {
                const Child = fti.pointer.child;
                // Count parts first to size the allocation exactly.
                const n = countParts(raw);
                const buf = try allocator.alloc(Child, n);
                errdefer allocator.free(buf);
                if (n > 0) {
                    var idx: usize = 0;
                    var sit = std.mem.splitScalar(u8, raw, ',');
                    while (sit.next()) |part| : (idx += 1) {
                        const trimmed = trimLine(part);
                        buf[idx] = try parseValue(Child, trimmed);
                    }
                }
                @field(block_ptr.*, kf.name) = buf;
                return;
            }

            switch (fti) {
                .array => |arr| {
                    var tmp: [arr.len][]const u8 = undefined;
                    const parts = try parseList(tmp[0..], raw);
                    var dst: [arr.len]arr.child = undefined;
                    for (parts, 0..) |p, idx| dst[idx] = try parseValue(arr.child, p);
                    if (arr.child == []const u8) {
                        var idx = parts.len;
                        while (idx < arr.len) : (idx += 1) dst[idx] = "";
                    }
                    @field(block_ptr.*, kf.name) = dst;
                    return;
                },
                else => {
                    @field(block_ptr.*, kf.name) = try parseValue(FT, raw);
                    return;
                },
            }
        }
    }
    return Error.UnknownKey;
}

fn countParts(raw: []const u8) usize {
    if (raw.len == 0) return 0;
    var n: usize = 1;
    for (raw) |c| if (c == ',') {
        n += 1;
    };
    return n;
}

/// Recursively free every slice allocated by `parseIntoAlloc`.
/// Safe to call on a partially-populated struct as long as un-set slice
/// fields default to an empty slice (e.g. `= &.{}`).
pub fn freeAlloc(comptime T: type, allocator: std.mem.Allocator, out: *T) void {
    const ti = @typeInfo(T);
    if (ti != .@"struct") return;
    inline for (ti.@"struct".fields) |bf| {
        const BT = bf.type;
        const bti = @typeInfo(BT);
        if (bti == .@"struct") {
            inline for (bti.@"struct".fields) |kf| {
                if (comptime isDynamicList(kf.type)) {
                    const slice = @field(@field(out.*, bf.name), kf.name);
                    if (slice.len != 0) allocator.free(slice);
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "iterator: basic blocks and pairs" {
    const src =
        \\# top comment
        \\>build
        \\cmd = zig build --release
        \\target = x86_64-linux # inline
        \\
        \\>deps
        \\changed = src/, package.json
    ;
    var it = Iterator.init(src);

    const a = (try it.next()).?;
    try testing.expectEqualStrings("build", a.block);

    const b = (try it.next()).?;
    try testing.expectEqualStrings("build", b.pair.block);
    try testing.expectEqualStrings("cmd", b.pair.key);
    try testing.expectEqualStrings("zig build --release", b.pair.value);

    const c = (try it.next()).?;
    try testing.expectEqualStrings("target", c.pair.key);
    try testing.expectEqualStrings("x86_64-linux", c.pair.value);

    const d = (try it.next()).?;
    try testing.expectEqualStrings("deps", d.block);

    const e = (try it.next()).?;
    try testing.expectEqualStrings("changed", e.pair.key);
    try testing.expectEqualStrings("src/, package.json", e.pair.value);

    try testing.expect((try it.next()) == null);
}

test "iterator: root key" {
    const src =
        \\# This is a comment
        \\root_key = 1
        \\another_key = this is a test
    ;
    var it = Iterator.init(src);
    const p1 = (try it.next()).?;
    try testing.expectEqualStrings("root_key", p1.pair.key);
    try testing.expectEqualStrings("1", p1.pair.value);
    const p2 = (try it.next()).?;
    try testing.expectEqualStrings("another_key", p2.pair.key);
    try testing.expectEqualStrings("this is a test", p2.pair.value);
}

test "iterator: root key (with space)" {
    const src =
        \\# This is a comment
        \\
        \\root_key = 1
        \\
        \\another_key = this is a test
    ;
    var it = Iterator.init(src);
    const p1 = (try it.next()).?;
    try testing.expectEqualStrings("root_key", p1.pair.key);
    try testing.expectEqualStrings("1", p1.pair.value);
    const p2 = (try it.next()).?;
    try testing.expectEqualStrings("another_key", p2.pair.key);
    try testing.expectEqualStrings("this is a test", p2.pair.value);
}

test "iterator: root and block keys" {
    const src = "root_key = root_value\n>blk\nblk_key = blk_value\n";
    var it = Iterator.init(src);
    const p1 = (try it.next()).?;
    try testing.expectEqualStrings("", p1.pair.block);
    try testing.expectEqualStrings("root_key", p1.pair.key);
    const b = (try it.next()).?;
    try testing.expectEqualStrings("blk", b.block);
    const p2 = (try it.next()).?;
    try testing.expectEqualStrings("blk", p2.pair.block);
    try testing.expectEqualStrings("blk_key", p2.pair.key);
}

test "iterator: invalid syntax — missing =" {
    const src = ">blk\nbad line\n";
    var it = Iterator.init(src);
    _ = try it.next();
    try testing.expectError(Error.InvalidSyntax, it.next());
}

test "iterator: invalid ident" {
    const src = ">blk\n1bad = x\n";
    var it = Iterator.init(src);
    _ = try it.next();
    try testing.expectError(Error.InvalidSyntax, it.next());
}

test "parseList" {
    var buf: [4][]const u8 = undefined;
    const parts = try parseList(buf[0..], "  src/ ,package.json,  README.md");
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("src/", parts[0]);
    try testing.expectEqualStrings("package.json", parts[1]);
    try testing.expectEqualStrings("README.md", parts[2]);
}

test "parseList: empty" {
    var buf: [4][]const u8 = undefined;
    const parts = try parseList(buf[0..], "");
    try testing.expectEqual(@as(usize, 0), parts.len);
}

test "parseList: too long" {
    var buf: [2][]const u8 = undefined;
    try testing.expectError(Error.ListTooLong, parseList(buf[0..], "a,b,c"));
}

test "parseInto: typed schema" {
    const Config = struct {
        build: struct {
            cmd: []const u8 = "",
            jobs: u32 = 1,
            release: bool = false,
        } = .{},
        deps: struct {
            changed: [4][]const u8 = .{ "", "", "", "" },
        } = .{},
    };

    const src =
        \\>build
        \\cmd = zig build
        \\jobs = 8
        \\release = true
        \\>deps
        \\changed = src/, build.zig, README.md
    ;

    var cfg: Config = .{};
    try parseInto(Config, src, &cfg);

    try testing.expectEqualStrings("zig build", cfg.build.cmd);
    try testing.expectEqual(@as(u32, 8), cfg.build.jobs);
    try testing.expectEqual(true, cfg.build.release);
    try testing.expectEqualStrings("src/", cfg.deps.changed[0]);
    try testing.expectEqualStrings("build.zig", cfg.deps.changed[1]);
    try testing.expectEqualStrings("README.md", cfg.deps.changed[2]);
    try testing.expectEqualStrings("", cfg.deps.changed[3]);
}

test "parseInto: duplicate block" {
    const Config = struct { a: struct { x: u32 = 0 } = .{} };
    const src = ">a\nx = 1\n>a\nx = 2\n";
    var cfg: Config = .{};
    try testing.expectError(Error.DuplicateBlock, parseInto(Config, src, &cfg));
}

test "parseInto: unknown block / key" {
    const Config = struct { a: struct { x: u32 = 0 } = .{} };
    var cfg: Config = .{};
    try testing.expectError(Error.UnknownBlock, parseInto(Config, ">zzz\n", &cfg));
    try testing.expectError(Error.UnknownKey, parseInto(Config, ">a\ny = 1\n", &cfg));
}

test "parseInto: enum" {
    const Mode = enum { debug, release, safe };
    const Config = struct { build: struct { mode: Mode = .debug } = .{} };
    var cfg: Config = .{};
    try parseInto(Config, ">build\nmode = release\n", &cfg);
    try testing.expectEqual(Mode.release, cfg.build.mode);
}

test "parseComptime" {
    const Config = struct {
        app: struct {
            name: []const u8 = "",
            port: u16 = 0,
        } = .{},
    };
    const cfg = comptime parseComptime(Config,
        \\>app
        \\name = hbcf
        \\port = 8080
    );
    try testing.expectEqualStrings("hbcf", cfg.app.name);
    try testing.expectEqual(@as(u16, 8080), cfg.app.port);
}

test "crlf line endings" {
    const src = ">a\r\nx = 1\r\n";
    const Config = struct { a: struct { x: u32 = 0 } = .{} };
    var cfg: Config = .{};
    try parseInto(Config, src, &cfg);
    try testing.expectEqual(@as(u32, 1), cfg.a.x);
}

test "parseIntoAlloc: dynamic string list" {
    const Config = struct {
        deps: struct {
            changed: [][]const u8 = &.{},
        } = .{},
    };
    const src =
        \\>deps
        \\changed = src/, build.zig, README.md, package.json, foo.zig
    ;
    var cfg: Config = .{};
    try parseIntoAlloc(Config, testing.allocator, src, &cfg);
    defer freeAlloc(Config, testing.allocator, &cfg);

    try testing.expectEqual(@as(usize, 5), cfg.deps.changed.len);
    try testing.expectEqualStrings("src/", cfg.deps.changed[0]);
    try testing.expectEqualStrings("foo.zig", cfg.deps.changed[4]);
}

test "parseIntoAlloc: dynamic int list" {
    const Config = struct {
        ports: struct {
            tcp: []u16 = &.{},
        } = .{},
    };
    const src = ">ports\ntcp = 80, 443, 8080, 8443, 9000\n";
    var cfg: Config = .{};
    try parseIntoAlloc(Config, testing.allocator, src, &cfg);
    defer freeAlloc(Config, testing.allocator, &cfg);

    try testing.expectEqualSlices(u16, &.{ 80, 443, 8080, 8443, 9000 }, cfg.ports.tcp);
}

test "parseIntoAlloc: empty list" {
    const Config = struct {
        deps: struct { changed: [][]const u8 = &.{} } = .{},
    };
    var cfg: Config = .{};
    try parseIntoAlloc(Config, testing.allocator, ">deps\nchanged =\n", &cfg);
    defer freeAlloc(Config, testing.allocator, &cfg);
    try testing.expectEqual(@as(usize, 0), cfg.deps.changed.len);
}

test "parseIntoAlloc: mixed fixed + dynamic + scalar" {
    const Mode = enum { debug, release };
    const Config = struct {
        build: struct {
            mode: Mode = .debug,
            jobs: u32 = 1,
            flags: [][]const u8 = &.{},
            tags: [3][]const u8 = .{ "", "", "" }, // fixed-size still works
        } = .{},
    };
    const src =
        \\>build
        \\mode = release
        \\jobs = 16
        \\flags = -O3, -flto, -fno-rtti, -fno-exceptions
        \\tags = ci, prod
    ;
    var cfg: Config = .{};
    try parseIntoAlloc(Config, testing.allocator, src, &cfg);
    defer freeAlloc(Config, testing.allocator, &cfg);

    try testing.expectEqual(Mode.release, cfg.build.mode);
    try testing.expectEqual(@as(u32, 16), cfg.build.jobs);
    try testing.expectEqual(@as(usize, 4), cfg.build.flags.len);
    try testing.expectEqualStrings("-flto", cfg.build.flags[1]);
    try testing.expectEqualStrings("ci", cfg.build.tags[0]);
    try testing.expectEqualStrings("prod", cfg.build.tags[1]);
    try testing.expectEqualStrings("", cfg.build.tags[2]);
}

//! Network locations through rclone: every remote configured in rclone (SFTP, SMB,
//! WebDAV, FTP, S3, Google Drive, … — whatever `rclone config` set up) appears in the
//! sidebar, and opening one mounts it with `rclone mount` under the runtime dir, after
//! which it's an ordinary folder. "Connect to Server" adds any kind rclone has: its
//! backends and their settings come from rclone itself (`config/providers`), and
//! rclone's own setup questions (a browser sign-in, which drive, …) are asked in the
//! dialog (rcd.zig runs them). The process work runs on worker threads; this file is
//! the pure part (parsing, paths, config text) plus argv shapes. Unit-tested.

const std = @import("std");

pub const Remote = struct {
    name: []u8, // without the trailing ':' (owned)
    kind: []u8, // rclone backend type, e.g. "sftp" (owned)
};

/// parseRemotes reads `rclone listremotes --long` output ("name: type" per line).
pub fn parseRemotes(alloc: std.mem.Allocator, text: []const u8) ![]Remote {
    var out = std.ArrayList(Remote).empty;
    errdefer {
        for (out.items) |r| freeRemote(alloc, r);
        out.deinit(alloc);
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        // rclone logs NOTICE lines here too ("2026/10/22 18:00:00 NOTICE: Config file
        // … not found"): anything that isn't a valid remote name is skipped.
        if (colon == 0 or !validName(line[0..colon])) continue;
        const name = try alloc.dupe(u8, line[0..colon]);
        errdefer alloc.free(name);
        const kind = try alloc.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t"));
        try out.append(alloc, .{ .name = name, .kind = kind });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeRemotes(alloc: std.mem.Allocator, rs: []Remote) void {
    for (rs) |r| freeRemote(alloc, r);
    if (rs.len > 0) alloc.free(rs);
}

fn freeRemote(alloc: std.mem.Allocator, r: Remote) void {
    alloc.free(r.name);
    alloc.free(r.kind);
}

pub fn dupRemotes(alloc: std.mem.Allocator, rs: []const Remote) ![]Remote {
    const out = try alloc.alloc(Remote, rs.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |r| freeRemote(alloc, r);
        alloc.free(out);
    }
    for (rs) |r| {
        const name = try alloc.dupe(u8, r.name);
        errdefer alloc.free(name);
        out[n] = .{ .name = name, .kind = try alloc.dupe(u8, r.kind) };
        n += 1;
    }
    return out;
}

/// mountpoint is where remote `name` is mounted: <base>/<name> (owned).
pub fn mountpoint(alloc: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ base, name });
}

/// isMounted reports whether `mp` is a mount point in /proc/self/mounts text.
pub fn isMounted(mounts: []const u8, mp: []const u8) bool {
    var it = std.mem.splitScalar(u8, mounts, '\n');
    while (it.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next() orelse continue;
        const target = f.next() orelse continue;
        if (std.mem.eql(u8, target, mp)) return true;
    }
    return false;
}

/// validName reports whether `name` is usable as a remote name (rclone's rule:
/// letters, digits, '_', '-', '.', '+', '@' and space, not starting with '-' or space).
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-' or name[0] == ' ') return false;
    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-.+@ ", ch) != null;
        if (!ok) return false;
    }
    return true;
}

/// Kind is a server type "Connect to Server" can add.
pub const Kind = enum {
    sftp,
    smb,
    webdav,
    ftp,

    pub fn label(k: Kind) [:0]const u8 {
        return switch (k) {
            .sftp => "SFTP (SSH)",
            .smb => "SMB (Windows / Samba share)",
            .webdav => "WebDAV (Nextcloud, ownCloud, …)",
            .ftp => "FTP",
        };
    }
};

/// errorText picks the useful line out of rclone's output: the CRITICAL/ERROR/Fatal
/// one (NOTICE lines come first and are just advice), without its timestamp.
pub fn errorText(text: []const u8) []const u8 {
    var fallback: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        for ([_][]const u8{ "CRITICAL: ", "ERROR : ", "ERROR: ", "Fatal error: " }) |tag| {
            if (std.mem.indexOf(u8, line, tag)) |i| return line[i + tag.len ..];
        }
        if (fallback.len == 0 and std.mem.indexOf(u8, line, "NOTICE:") == null) fallback = line;
    }
    return if (fallback.len > 0) fallback else std.mem.trim(u8, text, " \t\r\n");
}

// --- rclone's backends and setup questions ---------------------------------

/// Choice is one of an option's suggested values.
pub const Choice = struct { value: []const u8, help: []const u8, provider: []const u8 };

/// Option is one setting of a backend, as rclone describes it.
pub const Option = struct {
    name: []const u8,
    help: []const u8,
    default: []const u8, // as text ("" = none)
    typ: []const u8, // "string", "bool", "int", "SizeSuffix", …
    required: bool,
    password: bool, // shown masked; rclone obscures it
    advanced: bool,
    exclusive: bool, // only the choices are allowed
    provider: []const u8, // S3 and friends: which providers it's for ("" = all)
    choices: []Choice,

    /// helpLine is the help's first line (the rest is detail).
    pub fn helpLine(o: Option) []const u8 {
        const nl = std.mem.indexOfScalar(u8, o.help, '\n') orelse return o.help;
        return o.help[0..nl];
    }
};

/// Backend is a kind of storage rclone can use, with its settings.
pub const Backend = struct {
    name: []const u8, // e.g. "drive"
    description: []const u8, // e.g. "Google Drive"
    options: []Option, // the ones a person sets up (not hidden from configuring)

    /// shortName is the description up to its first aside (" (", ",", " including "):
    /// "Koofr, Digi Storage and other …" → "Koofr", "OpenStack Swift (Rackspace …)" →
    /// "OpenStack Swift". The whole description is the tooltip.
    pub fn shortName(b: Backend) []const u8 {
        var end = b.description.len;
        for ([_][]const u8{ " (", ",", " including " }) |sep| {
            if (std.mem.indexOf(u8, b.description, sep)) |i| end = @min(end, i);
        }
        const s = std.mem.trimEnd(u8, b.description[0..end], " .");
        return if (s.len > 0) s else b.name;
    }
};

/// parseProviders reads `config/providers` (or `rclone config providers`) output. All
/// of it is allocated in `arena`.
pub fn parseProviders(arena: std.mem.Allocator, text: []const u8) ![]Backend {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, jsonPart(text), .{});
    const list = switch (v) {
        .array => |a| a.items,
        .object => |o| (o.get("providers") orelse return error.BadJson).array.items,
        else => return error.BadJson,
    };
    var out = std.ArrayList(Backend).empty;
    for (list) |b| {
        if (b != .object) continue;
        if (boolField(b, "Hide")) continue;
        var opts = std.ArrayList(Option).empty;
        if (b.object.get("Options")) |os| if (os == .array) for (os.array.items) |o| {
            if (o != .object) continue;
            // Hide bit 2: not offered when configuring.
            if (intField(o, "Hide") & 2 != 0) continue;
            try opts.append(arena, try parseOption(arena, o));
        };
        try out.append(arena, .{ .name = strField(b, "Name"), .description = strField(b, "Description"), .options = opts.items });
    }
    std.mem.sort(Backend, out.items, {}, struct {
        fn lt(_: void, a: Backend, b: Backend) bool {
            const ta = groupOf(a.name);
            const tb = groupOf(b.name);
            if (ta != tb) return @intFromEnum(ta) < @intFromEnum(tb);
            return std.ascii.lessThanIgnoreCase(a.shortName(), b.shortName());
        }
    }.lt);
    return out.items;
}

/// Group is where a kind is listed: the ones most people use first, then the other
/// storage services, then rclone's tools (kinds made of other remotes or of nothing).
pub const Group = enum { popular, other, tools };

/// groupOf places rclone type `name`. Only the order depends on it: a kind rclone
/// adds later is listed with the other services.
pub fn groupOf(name: []const u8) Group {
    const popular = [_][]const u8{ "drive", "onedrive", "dropbox", "iclouddrive", "protondrive", "mega", "box", "pcloud", "google photos", "s3", "b2", "azureblob", "azurefiles", "google cloud storage", "smb", "sftp", "ftp", "webdav" };
    const tools = [_][]const u8{ "alias", "archive", "cache", "chunker", "combine", "compress", "crypt", "hasher", "local", "memory", "union" };
    for (popular) |p| if (std.mem.eql(u8, name, p)) return .popular;
    for (tools) |t| if (std.mem.eql(u8, name, t)) return .tools;
    return .other;
}

fn parseOption(arena: std.mem.Allocator, o: std.json.Value) !Option {
    var choices = std.ArrayList(Choice).empty;
    if (o.object.get("Examples")) |ex| if (ex == .array) for (ex.array.items) |e| {
        if (e != .object) continue;
        try choices.append(arena, .{ .value = strField(e, "Value"), .help = strField(e, "Help"), .provider = strField(e, "Provider") });
    };
    return .{
        .name = strField(o, "Name"),
        .help = strField(o, "Help"),
        .default = strField(o, "DefaultStr"),
        .typ = strField(o, "Type"),
        .required = boolField(o, "Required"),
        .password = boolField(o, "IsPassword"),
        .advanced = boolField(o, "Advanced"),
        .exclusive = boolField(o, "Exclusive"),
        .provider = strField(o, "Provider"),
        .choices = choices.items,
    };
}

/// Step is where rclone's setup is after a create/update: another question to ask
/// (`option`, carrying on from `state`), or done (`option` null). `err` is rclone's
/// complaint about the last answer, if any.
pub const Step = struct { state: []const u8, option: ?Option, err: []const u8 };

/// parseStep reads a config/create or config/update answer (arena-allocated).
pub fn parseStep(arena: std.mem.Allocator, text: []const u8) !Step {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, jsonPart(text), .{});
    if (v != .object) return error.BadJson;
    const opt = v.object.get("Option");
    return .{
        .state = strField(v, "State"),
        .option = if (opt != null and opt.? == .object) try parseOption(arena, opt.?) else null,
        .err = strField(v, "Error"),
    };
}

/// rcError is the message in an rc error reply ({"error": "…", "status": 500}).
pub fn rcError(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, jsonPart(text), .{}) catch return std.mem.trim(u8, text, " \r\n");
    return if (v == .object) strField(v, "error") else "";
}

/// providerMatches reports whether an option (or choice) marked for providers
/// `filter` ("AWS,Ceph", or "!AWS,Ceph" for all but those; "" for all) applies when
/// the backend's provider is `provider`.
pub fn providerMatches(filter: []const u8, provider: []const u8) bool {
    if (filter.len == 0) return true;
    const neg = filter[0] == '!';
    var it = std.mem.splitScalar(u8, if (neg) filter[1..] else filter, ',');
    while (it.next()) |p| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, p, " "), provider)) return !neg;
    return neg;
}

/// jsonPart skips anything rclone printed before its JSON (NOTICE lines).
fn jsonPart(text: []const u8) []const u8 {
    const i = std.mem.indexOfAny(u8, text, "{[") orelse return text;
    return text[i..];
}

fn strField(v: std.json.Value, key: []const u8) []const u8 {
    const f = v.object.get(key) orelse return "";
    return switch (f) {
        .string => |s| s,
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        else => "",
    };
}

fn boolField(v: std.json.Value, key: []const u8) bool {
    const f = v.object.get(key) orelse return false;
    return f == .bool and f.bool;
}

fn intField(v: std.json.Value, key: []const u8) i64 {
    const f = v.object.get(key) orelse return 0;
    return if (f == .integer) f.integer else 0;
}

/// isServerType reports an rclone type that's a server at an address (the sidebar
/// draws it as a network place; everything else is cloud storage).
pub fn isServerType(t: []const u8) bool {
    for ([_][]const u8{ "sftp", "smb", "ftp", "webdav", "http", "nfs", "hdfs", "local", "alias" }) |k| if (std.mem.eql(u8, t, k)) return true;
    return false;
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parseRemotes reads listremotes --long" {
    const got = try parseRemotes(testing.allocator, "2026/10/22 18:31:00 NOTICE: Config file not found\nnas: sftp  \ngdrive:  drive\n\n");
    defer freeRemotes(testing.allocator, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("nas", got[0].name);
    try testing.expectEqualStrings("sftp", got[0].kind);
    try testing.expectEqualStrings("drive", got[1].kind);
}

test "errorText skips NOTICE lines and timestamps" {
    const out =
        \\2026/10/22 18:26:48 NOTICE: box: No host key validation is being performed.
        \\2026/10/22 18:26:49 CRITICAL: Failed to create file system for "box:": couldn't connect SSH: no such host
    ;
    try testing.expectEqualStrings("Failed to create file system for \"box:\": couldn't connect SSH: no such host", errorText(out));
    try testing.expectEqualStrings("plain failure", errorText("plain failure\n"));
}

test "isMounted finds a mount point" {
    const m = "nas: /run/user/1000/zfd-net/nas fuse.rclone rw 0 0\n";
    try testing.expect(isMounted(m, "/run/user/1000/zfd-net/nas"));
    try testing.expect(!isMounted(m, "/run/user/1000/zfd-net/na"));
}

test "parseProviders reads backends and their options" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\{"providers":[
        \\ {"Name":"mega","Description":"Mega","Hide":false,"Options":[
        \\   {"Name":"user","Help":"User name.\nMore.","DefaultStr":"","Type":"string","Required":true,"IsPassword":false,"Advanced":false,"Exclusive":false,"Hide":0},
        \\   {"Name":"pass","Help":"Password.","DefaultStr":"","Type":"string","Required":true,"IsPassword":true,"Advanced":false,"Exclusive":false,"Hide":0},
        \\   {"Name":"session_id","Help":"x","DefaultStr":"","Type":"string","Hide":3}]},
        \\ {"Name":"s3","Description":"Amazon S3","Options":[
        \\   {"Name":"region","Help":"Region","Provider":"AWS,Ceph","Examples":[{"Value":"us-east-1","Help":"Virginia","Provider":"AWS"}],"Hide":0}]},
        \\ {"Name":"tardigrade","Description":"old","Hide":true,"Options":[]}]}
    ;
    const bs = try parseProviders(arena.allocator(), "NOTICE: x\n" ++ text);
    try testing.expectEqual(@as(usize, 2), bs.len);
    try testing.expectEqualStrings("Amazon S3", bs[0].description); // sorted by description
    const mega = bs[1];
    try testing.expectEqual(@as(usize, 2), mega.options.len); // session_id is hidden from setup
    try testing.expect(mega.options[1].password and mega.options[0].required);
    try testing.expectEqualStrings("User name.", mega.options[0].helpLine());
    try testing.expectEqualStrings("us-east-1", bs[0].options[0].choices[0].value);
}

test "parseStep reads a question and the end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try parseStep(arena.allocator(), "{\"State\":\"*oauth\",\"Option\":{\"Name\":\"config_is_local\",\"Help\":\"Use a browser?\",\"DefaultStr\":\"true\",\"Type\":\"bool\",\"Examples\":[{\"Value\":\"true\",\"Help\":\"Yes\"}]},\"Error\":\"\"}");
    try testing.expectEqualStrings("*oauth", q.state);
    try testing.expectEqualStrings("config_is_local", q.option.?.name);
    const done = try parseStep(arena.allocator(), "{\"State\":\"\",\"Option\":null,\"Error\":\"\",\"Result\":\"\"}");
    try testing.expect(done.option == null);
    try testing.expectEqualStrings("couldn't find backend", rcError(arena.allocator(), "{\"error\":\"couldn't find backend\",\"status\":500}"));
}

test "providerMatches lists and negations" {
    try testing.expect(providerMatches("", "AWS"));
    try testing.expect(providerMatches("AWS,Ceph", "ceph"));
    try testing.expect(!providerMatches("AWS,Ceph", "Minio"));
    try testing.expect(providerMatches("!AWS", "Minio") and !providerMatches("!AWS,Ceph", "AWS"));
}

test "shortName squashes long descriptions" {
    const b = struct {
        fn n(d: []const u8) []const u8 {
            return (Backend{ .name = "x", .description = d, .options = &.{} }).shortName();
        }
    }.n;
    try testing.expectEqualStrings("Koofr", b("Koofr, Digi Storage and other Koofr-compatible storage providers"));
    try testing.expectEqualStrings("OpenStack Swift", b("OpenStack Swift (Rackspace Cloud Files, OVH)"));
    try testing.expectEqualStrings("Amazon S3 Compliant Storage Providers", b("Amazon S3 Compliant Storage Providers including AWS, Ceph"));
    try testing.expectEqualStrings("In memory object storage system", b("In memory object storage system."));
    try testing.expectEqualStrings("Google Drive", b("Google Drive"));
}

test "groupOf puts the common kinds first and the tools last" {
    try testing.expectEqual(Group.popular, groupOf("drive"));
    try testing.expectEqual(Group.popular, groupOf("smb"));
    try testing.expectEqual(Group.tools, groupOf("crypt"));
    try testing.expectEqual(Group.other, groupOf("koofr"));
    try testing.expectEqual(Group.other, groupOf("some-future-backend"));
}

//! The servers on the local network, for the Network page: what `avahi-browse -t -r
//! -p -a` (mDNS / DNS-SD, as Finder's Bonjour) finds offering a file service ZFD can
//! connect to: SMB, SFTP/SSH, WebDAV, FTP. avahi reports each service once per
//! network interface and IP version; they're merged into one server, keeping the
//! address on the most ordinary interface (wired or wireless LAN before VPNs, and
//! container bridges last) and IPv4 over IPv6 (a link-local one needs its interface
//! to be usable). This computer's own services are left out, as Finder does. Pure:
//! `parse` takes the tool's output; the devices worker runs it.

const std = @import("std");
const rclone = @import("rclone.zig");

// -k: service types as such (_smb._tcp), not their descriptions ("Microsoft Windows Network").
pub const argv = [_][]const u8{ "avahi-browse", "-t", "-r", "-p", "-k", "-a" };

pub const Server = struct {
    name: []u8, // the service's name, as the machine announces it ("NAS", "Niels's MacBook")
    kind: rclone.Kind,
    host: []u8, // the address to connect to (IPv4 when there is one)
    port: u16,
    secure: bool = false, // WebDAV over https
};

/// kindOf maps a DNS-SD service type to what Connect to Server makes of it.
fn kindOf(t: []const u8) ?struct { rclone.Kind, bool } {
    const types = [_]struct { []const u8, rclone.Kind, bool }{
        .{ "_smb._tcp", .smb, false },     .{ "_sftp-ssh._tcp", .sftp, false }, .{ "_ssh._tcp", .sftp, false },
        .{ "_webdav._tcp", .webdav, false }, .{ "_webdavs._tcp", .webdav, true }, .{ "_ftp._tcp", .ftp, false },
    };
    for (types) |x| if (std.mem.eql(u8, t, x[0])) return .{ x[1], x[2] };
    return null;
}

/// rank orders a sighting's address: lower is the one to connect to.
fn rank(iface: []const u8, v4: bool) u8 {
    const virtual = [_][]const u8{ "docker", "br-", "veth", "virbr", "lxc", "podman", "cni", "flannel", "vmnet", "vboxnet" };
    const lan = [_][]const u8{ "en", "eth", "wl" };
    var r: u8 = 2;
    for (lan) |p| if (std.mem.startsWith(u8, iface, p)) {
        r = 0;
    };
    for (virtual) |p| if (std.mem.startsWith(u8, iface, p)) {
        r = 4;
    };
    return r + @intFromBool(!v4);
}

/// parse reads avahi-browse's parsable output (`=;iface;proto;name;type;domain;host;
/// address;port;txt` per resolved service) into servers, merged and sorted by name.
/// Services of the host named `own_host` (this computer, "loudy") are skipped.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, own_host: []const u8) ![]Server {
    var out = std.ArrayList(Server).empty;
    errdefer {
        free(alloc, out.items);
        out.deinit(alloc);
    }
    var ranks = std.ArrayList(u8).empty;
    defer ranks.deinit(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or line[0] != '=') continue;
        var f = std.mem.splitScalar(u8, line, ';');
        _ = f.next(); // "="
        const iface = f.next() orelse continue;
        const proto = f.next() orelse continue;
        const raw_name = f.next() orelse continue;
        const kind, const secure = kindOf(f.next() orelse continue) orelse continue;
        _ = f.next() orelse continue; // domain
        const hostname = f.next() orelse continue;
        const addr = f.next() orelse continue;
        const port = std.fmt.parseInt(u16, f.next() orelse continue, 10) catch continue;
        if (addr.len == 0) continue;
        if (own_host.len > 0 and std.ascii.startsWithIgnoreCase(hostname, own_host) and
            (hostname.len == own_host.len or hostname[own_host.len] == '.')) continue;
        var nb: [256]u8 = undefined;
        const name = unescape(&nb, raw_name);
        const rk = rank(iface, std.mem.eql(u8, proto, "IPv4"));
        // One server per name and kind, at its best-ranked address.
        var dup: ?usize = null;
        for (out.items, 0..) |sv, i| if (sv.kind == kind and std.mem.eql(u8, sv.name, name)) {
            dup = i;
        };
        if (dup) |i| {
            if (rk < ranks.items[i]) {
                const h = try alloc.dupe(u8, addr);
                alloc.free(out.items[i].host);
                out.items[i].host = h;
                out.items[i].port = port;
                ranks.items[i] = rk;
            }
            continue;
        }
        const n = try alloc.dupe(u8, name);
        errdefer alloc.free(n);
        const h = try alloc.dupe(u8, addr);
        errdefer alloc.free(h);
        try ranks.append(alloc, rk);
        try out.append(alloc, .{ .name = n, .kind = kind, .host = h, .port = port, .secure = secure });
    }
    // (the ranks are done with: the sort reorders the servers alone)
    std.mem.sort(Server, out.items, {}, struct {
        fn lt(_: void, a: Server, b: Server) bool {
            const o = std.ascii.orderIgnoreCase(a.name, b.name);
            return o == .lt or (o == .eq and @backingInt(a.kind) < @backingInt(b.kind));
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

/// unescape decodes avahi's `\DDD` (a byte in decimal) and `\c` escapes.
fn unescape(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) {
        if (s[i] == '\\' and i + 4 <= s.len) if (std.fmt.parseInt(u8, s[i + 1 .. i + 4], 10)) |b| {
            buf[n] = b;
            n += 1;
            i += 4;
            continue;
        } else |_| {};
        if (s[i] == '\\' and i + 1 < s.len) {
            buf[n] = s[i + 1];
            n += 1;
            i += 2;
            continue;
        }
        buf[n] = s[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

pub fn free(alloc: std.mem.Allocator, servers: []const Server) void {
    for (servers) |s| {
        alloc.free(s.name);
        alloc.free(s.host);
    }
}

pub fn freeSlice(alloc: std.mem.Allocator, servers: []Server) void {
    free(alloc, servers);
    alloc.free(servers);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

test "parse keeps file services, merges sightings, prefers IPv4" {
    const text =
        \\+;eth0;IPv4;NAS;_smb._tcp;local
        \\=;eth0;IPv6;NAS;_smb._tcp;local;nas.local;fe80::1;445;
        \\=;eth0;IPv4;NAS;_smb._tcp;local;nas.local;192.168.1.5;445;
        \\=;wlan0;IPv4;NAS;_smb._tcp;local;nas.local;192.168.1.5;445;
        \\=;eth0;IPv4;Niels\226\128\153s\032MacBook;_sftp-ssh._tcp;local;mac.local;192.168.1.9;22;
        \\=;eth0;IPv4;Printer;_ipp._tcp;local;prn.local;192.168.1.7;631;
        \\=;eth0;IPv4;Cloud;_webdavs._tcp;local;cloud.local;192.168.1.3;443;"path=/dav"
        \\=;docker0;IPv4;Box;_smb._tcp;local;box.local;172.17.0.1;445;
        \\=;enp1s0;IPv4;Box;_smb._tcp;local;box.local;192.168.1.200;445;
        \\=;br-1234;IPv4;Box;_smb._tcp;local;box.local;172.21.0.1;445;
        \\=;enp1s0;IPv4;Me;_smb._tcp;local;myhost.local;192.168.1.10;445;
        \\
    ;
    const ss = try parse(testing.allocator, text, "myhost");
    defer freeSlice(testing.allocator, ss);
    // The printer isn't a file service, and "Me" is this computer.
    try testing.expectEqual(@as(usize, 4), ss.len);
    try testing.expectEqualStrings("Box", ss[0].name);
    try testing.expectEqualStrings("192.168.1.200", ss[0].host); // the LAN, not a container bridge
    try testing.expectEqualStrings("Cloud", ss[1].name);
    try testing.expect(ss[1].secure and ss[1].kind == .webdav);
    try testing.expectEqualStrings("NAS", ss[2].name);
    try testing.expectEqualStrings("192.168.1.5", ss[2].host);
    try testing.expectEqual(rclone.Kind.smb, ss[2].kind);
    try testing.expectEqualStrings("Niels\u{2019}s MacBook", ss[3].name);
    try testing.expectEqual(@as(u16, 22), ss[3].port);
}

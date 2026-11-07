//! "Connect to Server": add any kind of location rclone has, servers (SFTP, SMB,
//! WebDAV, FTP, …) and cloud storage (MEGA, Google Drive, S3, …) alike. The list of
//! kinds and each one's settings come from rclone (core/rcd.zig asks it), so whatever
//! the installed rclone supports is offered. After the settings, rclone's own setup
//! questions follow in the same dialog, one at a time: signing in through the browser,
//! choosing a drive, and so on. When rclone is done the location is mounted and opened
//! like any other.

const std = @import("std");
const cimgui = @import("cimgui.zig");
const c = cimgui.c;
const core = @import("core");
const theme = @import("theme.zig");

const rclone = core.rclone;

pub const title = "Connect to Server";

/// Prefill is what the Network page found about a server.
pub const Prefill = struct { typ: []const u8, name: []const u8, values: []const [2][]const u8 };

const value_len = 512;

pub const Connect = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    pending: bool = false, // open next frame
    setup: ?*core.rcd.Setup = null, // while the dialog is open
    sock_dir: []const u8 = "", // where rcd's socket goes (borrowed)
    home: []const u8 = "", // (borrowed) whose ~/.ssh to use
    known_hosts: [std.fs.max_path_bytes]u8 = undefined, // ~/.ssh/known_hosts (SFTP)
    known_hosts_len: usize = 0,
    ssh_host: [128]u8 = @splat(0), // SFTP through `ssh <this>` (a ~/.ssh/config host); "" = typed in

    // Editing a location that's there already (Edit…): its name, and its settings as
    // saved, so only what's changed is sent. Passwords aren't shown (rclone keeps them
    // obscured): left blank, they stay as they are.
    editing: [64]u8 = @splat(0),
    orig: [][value_len]u8 = &.{},
    orig_ssh_host: [128]u8 = @splat(0),
    edit_loaded: bool = false,

    arena: std.heap.ArenaAllocator, // the parsed backend list
    backends: ?[]rclone.Backend = null,
    backend: ?usize = null,
    search: [64]u8 = @splat(0),
    name: [64]u8 = @splat(0),
    values: [][value_len]u8 = &.{}, // per option of the chosen backend ("" = its default)
    advanced: bool = false,
    prefill_typ: [32]u8 = @splat(0), // applied once the backend list is in
    prefill_vals: [4][2][value_len]u8 = undefined,
    prefill_n: usize = 0,

    // rclone's questions
    step_arena: std.heap.ArenaAllocator,
    step: ?rclone.Step = null,
    answer_buf: [value_len]u8 = @splat(0),
    creating: [64]u8 = @splat(0), // the location being set up (named when Connect was pressed)
    err: [400]u8 = @splat(0), // rclone's last complaint

    pub fn init(alloc: std.mem.Allocator, io: std.Io, sock_dir: []const u8, home: []const u8) Connect {
        var self = Connect{ .alloc = alloc, .io = io, .sock_dir = sock_dir, .home = home, .arena = .init(alloc), .step_arena = .init(alloc) };
        const kh = std.mem.print(&self.known_hosts, "{s}/.ssh/known_hosts", .{home}) catch "";
        self.known_hosts_len = kh.len;
        return self;
    }

    pub fn deinit(self: *Connect) void {
        self.close();
        self.arena.deinit();
        self.step_arena.deinit();
    }

    /// open shows the dialog (filled in from `pre`, a server the Network page found).
    pub fn open(self: *Connect, pre: ?Prefill) void {
        self.pending = true;
        self.prefill_n = 0;
        @memset(&self.prefill_typ, 0);
        if (pre) |p| {
            setField(&self.prefill_typ, p.typ);
            setField(&self.name, p.name);
            for (p.values) |kv| {
                if (self.prefill_n == self.prefill_vals.len) break;
                setField(&self.prefill_vals[self.prefill_n][0], kv[0]);
                setField(&self.prefill_vals[self.prefill_n][1], kv[1]);
                self.prefill_n += 1;
            }
        }
    }

    /// openEdit shows the dialog for location `name`, filled in with its settings.
    pub fn openEdit(self: *Connect, name: []const u8) void {
        self.open(null);
        setField(&self.editing, name);
        setField(&self.name, name);
        self.edit_loaded = false;
    }

    fn isEditing(self: *const Connect) bool {
        return self.editing[0] != 0;
    }

    /// close ends the dialog's rcd and forgets what was typed.
    fn close(self: *Connect) void {
        if (self.setup) |s| s.destroy();
        self.setup = null;
        self.clearValues();
        self.resetStep();
        @memset(&self.err, 0);
        @memset(&self.editing, 0);
        @memset(&self.orig_ssh_host, 0);
        self.edit_loaded = false;
        self.backend = null;
        @memset(&self.name, 0);
    }

    fn clearValues(self: *Connect) void {
        for (self.values) |*v| std.crypto.secureZero(u8, v); // passwords among them
        if (self.values.len > 0) self.alloc.free(self.values);
        self.values = &.{};
        for (self.orig) |*v| std.crypto.secureZero(u8, v);
        if (self.orig.len > 0) self.alloc.free(self.orig);
        self.orig = &.{};
    }

    fn resetStep(self: *Connect) void {
        self.step = null;
        _ = self.step_arena.reset(.retain_capacity);
        std.crypto.secureZero(u8, &self.answer_buf);
    }

    fn choose(self: *Connect, i: usize) void {
        self.clearValues();
        self.backend = i;
        const b = self.backends.?[i];
        self.values = self.alloc.alloc([value_len]u8, b.options.len) catch &.{};
        for (self.values) |*v| v[0] = 0;
        @memset(&self.err, 0);
        @memset(&self.ssh_host, 0);
    }

    fn valueOf(self: *Connect, opt_name: []const u8) []const u8 {
        const b = self.backends.?[self.backend orelse return ""];
        for (b.options, self.values) |o, *v| if (std.mem.eql(u8, o.name, opt_name)) return std.mem.sliceTo(v, 0);
        return "";
    }

    fn setValue(self: *Connect, opt_name: []const u8, val: []const u8) void {
        const b = self.backends.?[self.backend orelse return];
        for (b.options, self.values) |o, *v| if (std.mem.eql(u8, o.name, opt_name)) setField(v, val);
    }

    /// Done is a location rclone finished setting up: mount it and open it (a new
    /// one), or reconnect it with its new settings (an edited one).
    pub const Done = struct { name: [64]u8, len: usize, edited: bool = false };

    /// draw runs the dialog; it returns the location's name when one is ready.
    pub fn draw(self: *Connect) ?Done {
        if (self.pending) {
            self.pending = false;
            c.igOpenPopup_Str(title, 0);
            if (self.setup == null) {
                std.Io.Dir.cwd().createDirPath(self.io, self.sock_dir) catch {};
                self.setup = core.rcd.Setup.create(self.io, self.alloc, self.sock_dir, wakeUi) catch null;
                if (self.setup) |s| {
                    s.home = self.home;
                    s.edit_name = std.mem.sliceTo(&self.editing, 0);
                }
            }
            if (self.setup) |s| s.loadProviders();
        }
        const vp = c.igGetMainViewport();
        // Kept centred: it grows and shrinks as the kind and rclone's questions change.
        c.igSetNextWindowPos(cimgui.vec2(vp.*.WorkPos.x + vp.*.WorkSize.x * 0.5, vp.*.WorkPos.y + vp.*.WorkSize.y * 0.5), c.ImGuiCond_Always, cimgui.vec2(0.5, 0.5));
        if (!c.igBeginPopupModal(title, null, c.ImGuiWindowFlags_AlwaysAutoResize)) {
            if (self.setup != null) self.close(); // closed some other way
            return null;
        }
        defer c.igEndPopup();
        const s = self.setup orelse {
            dim("Could not start rclone.");
            if (c.igButton("Close", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) c.igCloseCurrentPopup();
            return null;
        };
        // The backend list, once rclone has sent it.
        if (self.backends == null) if (s.providersJson()) |json| {
            self.backends = rclone.parseProviders(self.arena.allocator(), json) catch &.{};
            self.applyPrefill();
        };
        if (self.isEditing() and !self.edit_loaded and self.backends != null) {
            self.edit_loaded = true;
            if (s.savedJson()) |sv| self.applySaved(sv) else setField(&self.err, "rclone couldn't read this location's settings.");
        }
        var done: ?Done = null;
        if (s.take()) |reply| {
            defer reply.deinit(self.alloc);
            switch (reply) {
                .failed => |msg| setField(&self.err, msg),
                .json => |json| {
                    self.resetStep();
                    const st = rclone.parseStep(self.step_arena.allocator(), json) catch null;
                    if (st) |step| {
                        setField(&self.err, step.err);
                        if (step.option) |o| {
                            self.step = step;
                            setField(&self.answer_buf, if (o.password) "" else o.default);
                        } else done = self.finish();
                    } else setField(&self.err, "rclone's answer made no sense");
                },
            }
        }
        if (done) |d| {
            c.igCloseCurrentPopup();
            self.close();
            return d;
        }

        const fs = c.igGetFontSize();
        const busy = s.isBusy();
        if (self.step != null) {
            self.drawQuestion(s, busy);
        } else if (self.backends) |bs| {
            self.drawForm(s, bs, busy);
        } else {
            dim("Asking rclone what it can connect to\u{2026}");
            c.igDummy(cimgui.vec2(fs * 30, 0));
            if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
                c.igCloseCurrentPopup();
                self.close();
            }
        }
        return null;
    }

    fn finish(self: *Connect) Done {
        var d = Done{ .name = undefined, .len = 0, .edited = self.isEditing() };
        const n = std.mem.sliceTo(&self.creating, 0);
        @memcpy(d.name[0..n.len], n);
        d.len = n.len;
        return d;
    }

    fn applyPrefill(self: *Connect) void {
        const typ = std.mem.sliceTo(&self.prefill_typ, 0);
        if (typ.len == 0) return;
        for (self.backends.?, 0..) |b, i| if (std.mem.eql(u8, b.name, typ)) {
            self.choose(i);
            for (self.prefill_vals[0..self.prefill_n]) |*kv| self.setValue(std.mem.sliceTo(&kv[0], 0), std.mem.sliceTo(&kv[1], 0));
            return;
        };
    }

    /// applySaved fills the form in from the location's saved settings (config/get's
    /// JSON object), and remembers them to tell what changed.
    fn applySaved(self: *Connect, json: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch return setField(&self.err, "rclone's answer made no sense");
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const obj = parsed.value.object;
        const typ = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";
        const bi = for (self.backends.?, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, typ)) break i;
        } else return setField(&self.err, "This rclone doesn't know this location's kind any more.");
        self.choose(bi);
        const b = self.backends.?[bi];
        var it = obj.iterator();
        while (it.next()) |kv| {
            var vb: [value_len]u8 = undefined;
            const val: []const u8 = switch (kv.value_ptr.*) {
                .string => |t| t,
                .bool => |on| if (on) "true" else "false",
                .integer => |n| std.mem.print(&vb, "{d}", .{n}) catch continue,
                else => continue,
            };
            for (b.options) |o| if (std.mem.eql(u8, o.name, kv.key_ptr.*)) {
                if (!o.password) self.setValue(o.name, val);
                break;
            };
            // SFTP through a ~/.ssh/config host: `ssh <host>`.
            if (std.mem.eql(u8, b.name, "sftp") and std.mem.eql(u8, kv.key_ptr.*, "ssh") and std.mem.startsWith(u8, val, "ssh ")) {
                const h = std.mem.trim(u8, val[4..], " ");
                if (std.mem.indexOfScalar(u8, h, ' ') == null) {
                    setField(&self.ssh_host, h);
                    setField(&self.orig_ssh_host, h);
                }
            }
        }
        self.orig = self.alloc.alloc([value_len]u8, self.values.len) catch &.{};
        if (self.orig.len == self.values.len) @memcpy(self.orig, self.values);
    }

    /// changesJson is what the edit changed, as a JSON object (owned): the settings
    /// that differ from the saved ones ("" clears one); a blank password is unchanged.
    fn changesJson(self: *Connect, b: rclone.Backend) ?[]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        out.append(self.alloc, '{') catch return null;
        var first = true;
        const via = std.mem.sliceTo(&self.ssh_host, 0);
        const was_via = std.mem.sliceTo(&self.orig_ssh_host, 0);
        const sftp = std.mem.eql(u8, b.name, "sftp");
        if (sftp and via.len > 0) {
            if (!std.mem.eql(u8, via, was_via)) {
                addKv(self.alloc, &out, &first, "host", via) catch return null;
                var sb: [160]u8 = undefined;
                addKv(self.alloc, &out, &first, "ssh", std.mem.print(&sb, "ssh {s}", .{via}) catch return null) catch return null;
            }
        } else {
            if (sftp and was_via.len > 0) addKv(self.alloc, &out, &first, "ssh", "") catch return null; // typed in now
            for (b.options, self.values, 0..) |o, *v, i| {
                const val = std.mem.sliceTo(v, 0);
                if (o.password and val.len == 0) continue;
                const old = if (i < self.orig.len) std.mem.sliceTo(&self.orig[i], 0) else "";
                if (std.mem.eql(u8, val, old)) continue;
                addKv(self.alloc, &out, &first, o.name, val) catch return null;
            }
        }
        out.append(self.alloc, '}') catch return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    // --- the settings form --------------------------------------------------

    fn drawForm(self: *Connect, s: *core.rcd.Setup, bs: []rclone.Backend, busy: bool) void {
        const fs = c.igGetFontSize();
        const label_w = fs * 11;
        const field_w = fs * 18;
        const hint_w = fs * 16;
        theme.pushFields();
        defer theme.popFields();

        // The kind: every backend rclone has, searchable.
        formLabel("Type", label_w);
        c.igSetNextItemWidth(field_w);
        var pb: [200]u8 = undefined;
        const preview: [:0]const u8 = if (self.backend) |i| (std.mem.printSentinel(&pb, "{s}", .{bs[i].shortName()}, 0) catch "") else "Choose\u{2026}";
        fitDropdown();
        // An edited location keeps its kind and name (rclone can't change either).
        c.igBeginDisabled(self.isEditing());
        if (c.igBeginCombo("##cstype", preview.ptr, 0)) {
            if (c.igIsWindowAppearing()) c.igSetKeyboardFocusHere(0);
            c.igSetNextItemWidth(-1);
            _ = c.igInputTextWithHint("##cssearch", "Search\u{2026}", &self.search, self.search.len, 0, null, null);
            const q = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " ");
            var group: ?rclone.Group = null;
            for (bs, 0..) |b, i| {
                if (q.len > 0 and std.ascii.findIgnoreCase(b.description, q) == null and std.ascii.findIgnoreCase(b.name, q) == null) continue;
                // A heading where the group changes (the list is sorted by group).
                const g = rclone.groupOf(b.name);
                if (group != g) {
                    group = g;
                    c.igSeparatorText(switch (g) {
                        .popular => "Popular",
                        .other => "Other services",
                        .tools => "rclone tools",
                    });
                }
                // The short name, then rclone's code for the kind, dim (what `rclone
                // config` calls it); the whole description on hover.
                const short = b.shortName();
                var lb: [240]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}##{s}", .{ short, b.name }, 0) catch continue;
                if (c.igSelectable_Bool(label.ptr, self.backend == i, 0, cimgui.vec2(0, 0))) self.choose(i);
                if (!std.mem.eql(u8, short, b.description) and c.igBeginItemTooltip()) {
                    c.igPushTextWrapPos(c.igGetFontSize() * 30);
                    cimgui.textUnformatted(b.description);
                    c.igPopTextWrapPos();
                    c.igEndTooltip();
                }
                c.igSameLine(0, -1);
                c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
                cimgui.textUnformatted(b.name); // one line: no wrapping here
                c.igPopStyleColor(1);
            }
            c.igEndCombo();
        }
        c.igEndDisabled();
        formLabel("Name", label_w);
        c.igSetNextItemWidth(field_w);
        _ = c.igInputTextWithHint("##csname", "e.g. nas, mega", &self.name, self.name.len, if (self.isEditing()) c.ImGuiInputTextFlags_ReadOnly else 0, null, null);
        const name = std.mem.trim(u8, std.mem.sliceTo(&self.name, 0), " ");
        const hint_x = c.igGetStyle().*.WindowPadding.x + label_w + field_w + c.igGetStyle().*.ItemSpacing.x;
        if (name.len > 0 and !rclone.validName(name))
            formHint(hint_x, "Letters, digits, space and _ - . + @ only.", hint_w, theme.err())
        else
            formHint(hint_x, "How it's listed in the sidebar.", hint_w, theme.dim());

        var missing = false;
        if (self.backend) |bi| {
            const b = bs[bi];
            const provider = self.valueOf("provider");
            var any_advanced = false;
            c.igSeparatorText("Settings");
            // A long list scrolls rather than growing past the screen.
            const max_h = c.igGetMainViewport().*.WorkSize.y * 0.5;
            c.igSetNextWindowSizeConstraints(cimgui.vec2(0, 0), cimgui.vec2(std.math.floatMax(f32), max_h), null, null);
            _ = c.igBeginChild_Str("##csopts", cimgui.vec2(label_w + field_w + hint_w + c.igGetStyle().*.WindowPadding.x * 2 + c.igGetStyle().*.ItemSpacing.x, 0), c.ImGuiChildFlags_AutoResizeY | c.ImGuiChildFlags_AlwaysUseWindowPadding, 0);
            const sftp = std.mem.eql(u8, b.name, "sftp");
            const via_ssh = sftp and self.drawSshHost(label_w - c.igGetStyle().*.WindowPadding.x, field_w, hint_x - c.igGetStyle().*.WindowPadding.x, hint_w);
            for (b.options, 0..) |o, i| {
                if (via_ssh) break; // ssh does it all: rclone ignores the rest
                if (!rclone.providerMatches(o.provider, provider)) continue;
                if (o.advanced or (sftp and !sftpBasic(o.name))) {
                    any_advanced = true;
                    if (!self.advanced) continue;
                }
                const v = &self.values[i];
                if (o.required and o.default.len == 0 and v[0] == 0) missing = true;
                c.igPushID_Int(@intCast(i));
                defer c.igPopID();
                var nb: [96]u8 = undefined;
                // (The list is padded inside, so its column starts that much later.)
                formLabel(prettyName(&nb, o.name, o.required), label_w - c.igGetStyle().*.WindowPadding.x);
                optionField(o, v, field_w, provider, self.isEditing());
                if (c.igIsItemHovered(c.ImGuiHoveredFlags_ForTooltip) and o.help.len > 0) {
                    if (c.igBeginTooltip()) {
                        c.igPushTextWrapPos(fs * 30);
                        cimgui.textUnformatted(o.help);
                        c.igPopTextWrapPos();
                        c.igEndTooltip();
                    }
                }
                formHint(hint_x - c.igGetStyle().*.WindowPadding.x, o.helpLine(), hint_w, theme.dim());
            }
            c.igEndChild();
            if (any_advanced) _ = c.igCheckbox("Show advanced settings", &self.advanced);
        } else {
            c.igSpacing();
            dim("Servers (SFTP, SMB, WebDAV, FTP) and cloud storage (MEGA, Google Drive, S3, \u{2026}): whatever your rclone can reach.");
        }

        self.drawError();
        c.igSeparator();
        const ok = self.backend != null and rclone.validName(name) and !missing and !busy;
        c.igBeginDisabled(!ok);
        const go = c.igButton(if (self.isEditing()) "Save" else "Connect", cimgui.vec2(0, 0));
        c.igEndDisabled();
        c.igSameLine(0, -1);
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            c.igCloseCurrentPopup();
            self.close();
            return;
        }
        if (busy) {
            c.igSameLine(0, -1);
            dim("Working\u{2026}");
        }
        if (go) {
            const b = bs[self.backend.?];
            const json = (if (self.isEditing()) self.changesJson(b) else self.paramsJson(b)) orelse return setField(&self.err, "Out of memory");
            defer {
                std.crypto.secureZero(u8, json);
                self.alloc.free(json);
            }
            @memset(&self.err, 0);
            setField(&self.creating, name);
            if (self.isEditing()) s.update(name, json) else s.begin(name, b.name, json);
        }
    }

    /// drawSshHost is SFTP's first row, when ~/.ssh/config names hosts: connect as
    /// `ssh <host>` does (the config's user, port, keys, ProxyJump, … all apply), or
    /// type the server in. Returns whether a config host is chosen.
    fn drawSshHost(self: *Connect, label_w: f32, field_w: f32, hint_x: f32, hint_w: f32) bool {
        const s = self.setup orelse return false;
        const hosts = s.sshHosts();
        if (hosts.len == 0) {
            @memset(&self.ssh_host, 0);
            return false;
        }
        const cur = std.mem.sliceTo(&self.ssh_host, 0);
        formLabel("SSH config", label_w);
        c.igSetNextItemWidth(field_w);
        fitDropdown();
        var pb: [140]u8 = undefined;
        const preview = if (cur.len > 0) (std.mem.printSentinel(&pb, "{s}", .{cur}, 0) catch "") else "Don't use (type it in)";
        if (c.igBeginCombo("##sshhost", preview.ptr, 0)) {
            if (c.igSelectable_Bool("Don't use (type it in)", cur.len == 0, 0, cimgui.vec2(0, 0))) @memset(&self.ssh_host, 0);
            for (hosts, 0..) |h, k| {
                c.igPushID_Int(@intCast(k));
                defer c.igPopID();
                var lb: [140]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}", .{h}, 0) catch continue;
                if (c.igSelectable_Bool(label.ptr, std.mem.eql(u8, h, cur), 0, cimgui.vec2(0, 0))) {
                    setField(&self.ssh_host, h);
                    // Named after it, unless a name was typed already.
                    if (std.mem.sliceTo(&self.name, 0).len == 0 and rclone.validName(h)) setField(&self.name, h);
                }
            }
            c.igEndCombo();
        }
        const chosen = std.mem.sliceTo(&self.ssh_host, 0);
        // Say what it runs: the Name above is only what the sidebar calls it.
        var hb: [256]u8 = undefined;
        const hint = if (chosen.len > 0)
            (std.mem.print(&hb, "Connects with \u{201C}ssh {s}\u{201D}, as set in ~/.ssh/config. It must log in without a password (a key or the SSH agent).", .{chosen}) catch "")
        else
            "A host from ~/.ssh/config, set up as you use it with ssh.";
        formHint(hint_x, hint, hint_w, theme.dim());
        return chosen.len > 0;
    }

    /// paramsJson is the settings filled in, as a JSON object (owned). SFTP through a
    /// ~/.ssh/config host is just `ssh <host>`; typed in, it checks the host key against
    /// ~/.ssh/known_hosts when there is one (and rclone tries the SSH agent itself when
    /// there's no password or key).
    fn paramsJson(self: *Connect, b: rclone.Backend) ?[]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        out.append(self.alloc, '{') catch return null;
        var first = true;
        const provider = self.valueOf("provider");
        for (b.options, self.values) |o, *v| {
            const val = std.mem.sliceTo(v, 0);
            if (val.len == 0 or std.mem.eql(u8, val, o.default) or !rclone.providerMatches(o.provider, provider)) continue;
            addKv(self.alloc, &out, &first, o.name, val) catch return null;
        }
        if (std.mem.eql(u8, b.name, "sftp")) {
            const via = std.mem.sliceTo(&self.ssh_host, 0);
            if (via.len > 0) {
                out.shrinkRetainingCapacity(1); // only these: rclone ignores the rest
                first = true;
                addKv(self.alloc, &out, &first, "host", via) catch return null;
                var sb: [160]u8 = undefined;
                addKv(self.alloc, &out, &first, "ssh", std.mem.print(&sb, "ssh {s}", .{via}) catch return null) catch return null;
            } else if (self.valueOf("known_hosts_file").len == 0 and self.known_hosts_len > 0 and self.setup != null and self.setup.?.hasKnownHosts())
                addKv(self.alloc, &out, &first, "known_hosts_file", self.known_hosts[0..self.known_hosts_len]) catch return null;
        }
        out.append(self.alloc, '}') catch return null;
        return out.toOwnedSlice(self.alloc) catch null;
    }

    // --- rclone's questions -------------------------------------------------

    fn drawQuestion(self: *Connect, s: *core.rcd.Setup, busy: bool) void {
        const fs = c.igGetFontSize();
        const step = self.step.?;
        const o = step.option.?;
        const name = std.mem.sliceTo(&self.creating, 0);
        var tb: [128]u8 = undefined;
        c.igSeparatorText(std.mem.printSentinel(&tb, "Setting up \u{201C}{s}\u{201D}", .{name}, 0) catch "Setting up");
        c.igPushTextWrapPos(fs * 34);
        cimgui.textUnformatted(o.help);
        c.igPopTextWrapPos();
        c.igSpacing();
        theme.pushFields();
        if (o.choices.len > 0 and o.choices.len <= 12) {
            // A few choices (yes/no, which drive): each spelled out, one click.
            const cur = std.mem.sliceTo(&self.answer_buf, 0);
            for (o.choices, 0..) |ch, k| {
                c.igPushID_Int(@intCast(k));
                defer c.igPopID();
                var lb: [value_len]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}", .{if (ch.help.len > 0) firstLine(ch.help) else ch.value}, 0) catch continue;
                if (c.igRadioButton_Bool(label.ptr, std.mem.eql(u8, ch.value, cur))) setField(&self.answer_buf, ch.value);
            }
        } else optionField(o, &self.answer_buf, fs * 22, "", false);
        theme.popFields();
        if (busy) {
            c.igSpacing();
            // A browser sign-in holds the answer until it's done.
            dim(if (std.mem.eql(u8, o.name, "config_is_local")) "Finish signing in in your web browser\u{2026}" else "Working\u{2026}");
        }
        self.drawError();
        c.igSeparator();
        c.igBeginDisabled(busy);
        const go = c.igButton("Continue", cimgui.vec2(0, 0)) or (!busy and c.igIsKeyPressed_Bool(c.ImGuiKey_Enter, false));
        c.igEndDisabled();
        c.igSameLine(0, -1);
        if (c.igButton("Cancel", cimgui.vec2(0, 0)) or c.igIsKeyPressed_Bool(c.ImGuiKey_Escape, false)) {
            // Give up: stop rclone (a sign-in waiting in the browser too) and remove the
            // half-made location (not one being edited: that one was there before).
            var nb: [64]u8 = undefined;
            const n = nb[0..name.len];
            @memcpy(n, name);
            const made_here = !self.isEditing();
            c.igCloseCurrentPopup();
            self.close();
            if (made_here) core.fsops.launch(self.io, self.alloc, &.{ "rclone", "config", "delete", n }, null);
            return;
        }
        if (go) {
            @memset(&self.err, 0);
            s.answer(name, step.state, std.mem.sliceTo(&self.answer_buf, 0));
            std.crypto.secureZero(u8, &self.answer_buf);
        }
    }

    fn drawError(self: *Connect) void {
        const e = std.mem.sliceTo(&self.err, 0);
        if (e.len == 0) return;
        c.igSpacing();
        c.igPushTextWrapPos(c.igGetFontSize() * 34);
        c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.err());
        cimgui.textUnformatted(e);
        c.igPopStyleColor(1);
        c.igPopTextWrapPos();
    }
};

/// optionField is the input for one rclone option: a choice list, yes/no, a masked
/// password, or text with the default as its hint.
fn optionField(o: rclone.Option, v: *[value_len]u8, w: f32, provider: []const u8, editing: bool) void {
    const cur = std.mem.sliceTo(v, 0);
    if (std.mem.eql(u8, o.typ, "bool")) {
        var on = std.mem.eql(u8, if (cur.len > 0) cur else o.default, "true");
        if (c.igCheckbox("##v", &on)) setField(v, if (on) "true" else "false");
        return;
    }
    if (o.choices.len > 0 and o.exclusive) {
        var pb: [value_len + 8]u8 = undefined;
        const shown = if (cur.len > 0) cur else o.default;
        const preview = std.mem.printSentinel(&pb, "{s}", .{if (shown.len > 0) choiceHelp(o, shown) else "(none)"}, 0) catch "";
        c.igSetNextItemWidth(w);
        fitDropdown();
        if (c.igBeginCombo("##v", preview.ptr, 0)) {
            for (o.choices, 0..) |ch, k| {
                if (!rclone.providerMatches(ch.provider, provider)) continue;
                c.igPushID_Int(@intCast(k));
                var lb: [value_len]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}", .{if (ch.help.len > 0) firstLine(ch.help) else ch.value}, 0) catch "";
                if (c.igSelectable_Bool(label.ptr, std.mem.eql(u8, ch.value, shown), 0, cimgui.vec2(0, 0))) setField(v, ch.value);
                c.igPopID();
            }
            c.igEndCombo();
        }
        return;
    }
    var hb: [value_len + 1]u8 = undefined;
    // The default as the hint; with none, say a blank is fine (it isn't a must).
    // (Editing, a blank password keeps the saved one.)
    const hint = std.mem.printSentinel(&hb, "{s}", .{if (editing and o.password) "unchanged" else if (o.default.len > 0 or o.required) o.default else "optional"}, 0) catch "";
    const free_choices = o.choices.len > 0;
    c.igSetNextItemWidth(if (free_choices) w - c.igGetFrameHeight() else w);
    _ = c.igInputTextWithHint("##v", hint.ptr, v, v.len, if (o.password) c.ImGuiInputTextFlags_Password else 0, null, null);
    if (free_choices) {
        // Suggestions for a field that takes anything.
        c.igSameLine(0, 0);
        fitDropdown();
        if (c.igBeginCombo("##vs", "", c.ImGuiComboFlags_NoPreview | c.ImGuiComboFlags_PopupAlignLeft)) {
            for (o.choices, 0..) |ch, k| {
                if (!rclone.providerMatches(ch.provider, provider)) continue;
                c.igPushID_Int(@intCast(k));
                var lb: [value_len * 2]u8 = undefined;
                const label = std.mem.printSentinel(&lb, "{s}: {s}", .{ ch.value, firstLine(ch.help) }, 0) catch "";
                if (c.igSelectable_Bool(label.ptr, false, 0, cimgui.vec2(0, 0))) setField(v, ch.value);
                c.igPopID();
            }
            c.igEndCombo();
        }
    }
}

/// sftpBasic: the SFTP settings shown without "Show advanced settings" (the rest,
/// rclone's raw keys and ciphers, are seldom needed).
fn sftpBasic(name: []const u8) bool {
    const basic = [_][]const u8{ "host", "user", "port", "pass", "key_file" };
    for (basic) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn choiceHelp(o: rclone.Option, value: []const u8) []const u8 {
    for (o.choices) |ch| if (std.mem.eql(u8, ch.value, value)) return if (ch.help.len > 0) firstLine(ch.help) else ch.value;
    return value;
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

/// prettyName turns an option name into a label: "access_key_id" → "Access key id".
/// Abbreviations are capitalised ("2fa" → "2FA", "client_id" → "Client ID"). Kept to
/// 18 characters (with an ellipsis), so it fits the label column.
fn prettyName(buf: []u8, name: []const u8, required: bool) []const u8 {
    const max = 18;
    const n = @min(name.len, buf.len - 8);
    for (name[0..n], 0..) |ch, i| buf[i] = if (ch == '_') ' ' else if (i == 0) std.ascii.toUpper(ch) else ch;
    const abbrevs = [_][]const u8{ "2fa", "id", "url", "uri", "api", "acl", "sso", "tls", "ssl", "http", "https", "ftp", "sftp", "smb", "kms", "sse", "ip", "dns", "md5", "sha1", "crc", "oauth", "jwt", "ca" };
    var w: usize = 0;
    while (w < n) {
        const e = std.mem.indexOfScalarPos(u8, buf[0..n], w, ' ') orelse n;
        for (abbrevs) |a| if (std.ascii.eqlIgnoreCase(buf[w..e], a)) {
            for (buf[w..e]) |*ch| ch.* = std.ascii.toUpper(ch.*);
        };
        w = e + 1;
    }
    var len = n;
    if (len > max) {
        const dots = "\u{2026}";
        @memcpy(buf[max - 1 .. max - 1 + dots.len], dots);
        len = max - 1 + dots.len;
    }
    if (!required) return buf[0..len];
    buf[len] = '*';
    return buf[0 .. len + 1];
}

fn addKv(alloc: std.mem.Allocator, out: *std.ArrayList(u8), first: *bool, k: []const u8, v: []const u8) !void {
    if (!first.*) try out.append(alloc, ',');
    first.* = false;
    try out.print(alloc, "{f}:{f}", .{ std.json.fmt(k, .{}), std.json.fmt(v, .{}) });
}

fn setField(buf: []u8, s: []const u8) void {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

fn dim(s: []const u8) void {
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, theme.dim());
    c.igPushTextWrapPos(c.igGetFontSize() * 34);
    cimgui.textUnformatted(s);
    c.igPopTextWrapPos();
    c.igPopStyleColor(1);
}

fn formLabel(label: []const u8, w: f32) void {
    const tw = c.igCalcTextSize(label.ptr, label.ptr + label.len, false, -1).x;
    c.igAlignTextToFramePadding();
    c.igSetCursorPosX(c.igGetCursorPosX() + @max(w - tw - 8, 0));
    cimgui.textUnformatted(label);
    c.igSameLine(0, 0);
    c.igSetCursorPosX(c.igGetStyle().*.WindowPadding.x + w);
}

fn formHint(x: f32, text: []const u8, w: f32, col: c.ImVec4_c) void {
    c.igSameLine(x, -1);
    c.igAlignTextToFramePadding();
    c.igPushTextWrapPos(c.igGetCursorPosX() + w);
    c.igPushStyleColor_Vec4(c.ImGuiCol_Text, col);
    cimgui.textUnformatted(text);
    c.igPopStyleColor(1);
    c.igPopTextWrapPos();
}

/// wakeUi wakes an idle UI loop when rclone answers (glfwPostEmptyEvent is
/// thread-safe).
fn wakeUi() void {
    c.glfwPostEmptyEvent();
}

/// fitDropdown keeps the next dropdown inside the window it opens from: no taller than
/// the room above or below its field. A taller one would get a window of its own
/// (multi-viewport), and opening and closing that makes the whole window blink.
fn fitDropdown() void {
    const vp = c.igGetWindowViewport();
    const y = c.igGetCursorScreenPos().y;
    const pad = c.igGetStyle().*.WindowPadding.y * 2;
    const below = vp.*.Pos.y + vp.*.Size.y - (y + c.igGetFrameHeight()) - pad;
    const above = y - vp.*.Pos.y - pad;
    // Below, as ImGui prefers (it judges by the screen, not the window), unless that's
    // a sliver; then the room above.
    const row = c.igGetFrameHeight();
    const h = if (below >= row * 6) below else @max(above, row * 4);
    c.igSetNextWindowSizeConstraints(cimgui.vec2(0, 0), cimgui.vec2(std.math.floatMax(f32), h), null, null);
}

const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");
const bus = @import("../bus.zig");

const log = std.log.scoped(.whatsapp_web);

const HttpGetFn = *const fn (
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    timeout_secs: []const u8,
) anyerror![]u8;

const HttpPostFn = *const fn (
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) anyerror![]u8;

/// WhatsApp Web channel backed by a local sidecar bridge.
///
/// Bridge contract:
/// - POST `{bridge_url}/poll` with body `{"account_id":"...","cursor":"..."?}`
/// - POST `{bridge_url}/send` with body `{"account_id":"...","to":"...","text":"..."}`
/// - optional GET `{bridge_url}/health` for operator diagnostics.
pub const WhatsAppWebChannel = struct {
    allocator: std.mem.Allocator,
    config: config_types.WhatsAppWebConfig,
    event_bus: ?*bus.Bus = null,
    running: bool = false,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    poll_thread: ?std.Thread = null,
    cursor: ?[]u8 = null,

    http_get: HttpGetFn = root.http_util.curlGet,
    http_post: HttpPostFn = root.http_util.curlPost,

    pub const MAX_MESSAGE_LEN: usize = 3500;
    pub const POLL_ENDPOINT: []const u8 = "/poll";
    pub const SEND_ENDPOINT: []const u8 = "/send";
    pub const HEALTH_ENDPOINT: []const u8 = "/health";

    pub fn init(allocator: std.mem.Allocator, config: config_types.WhatsAppWebConfig) WhatsAppWebChannel {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.WhatsAppWebConfig) WhatsAppWebChannel {
        return init(allocator, cfg);
    }

    pub fn deinit(self: *WhatsAppWebChannel) void {
        vtableStop(@ptrCast(self));
        if (self.cursor) |cursor| {
            self.allocator.free(cursor);
            self.cursor = null;
        }
    }

    pub fn setBus(self: *WhatsAppWebChannel, b: *bus.Bus) void {
        self.event_bus = b;
    }

    pub fn channelName(_: *WhatsAppWebChannel) []const u8 {
        return "whatsapp_web";
    }

    pub fn healthCheck(self: *WhatsAppWebChannel) bool {
        return self.running and self.poll_thread != null;
    }

    fn trimTrailingSlash(value: []const u8) []const u8 {
        var trimmed = std.mem.trim(u8, value, " \t\r\n");
        while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        return trimmed;
    }

    fn endpointUrl(self: *const WhatsAppWebChannel, suffix: []const u8) ![]u8 {
        const base = trimTrailingSlash(self.config.bridge_url);
        if (base.len == 0) return error.InvalidConfiguration;
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, suffix });
    }

    fn authHeaders(self: *const WhatsAppWebChannel, auth_buf: *[512]u8, header_slots: *[1][]const u8) []const []const u8 {
        if (self.config.api_key) |api_key| {
            header_slots[0] = std.fmt.bufPrint(auth_buf, "Authorization: Bearer {s}", .{api_key}) catch return &.{};
            return header_slots[0..1];
        }
        return &.{};
    }

    fn isSenderAllowed(self: *const WhatsAppWebChannel, sender: []const u8, is_group: bool) bool {
        if (!is_group) {
            if (self.config.allow_from.len == 0) return true;
            return root.isAllowed(self.config.allow_from, sender);
        }

        if (std.mem.eql(u8, self.config.group_policy, "disabled")) return false;
        if (std.mem.eql(u8, self.config.group_policy, "open")) return true;

        const effective_allowlist = if (self.config.group_allow_from.len > 0)
            self.config.group_allow_from
        else
            self.config.allow_from;
        if (effective_allowlist.len == 0) return false;
        return root.isAllowed(effective_allowlist, sender);
    }

    fn getObjString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const value = obj.get(key) orelse return null;
        if (value != .string) return null;
        if (value.string.len == 0) return null;
        return value.string;
    }

    fn getObjBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
        const value = obj.get(key) orelse return null;
        if (value != .bool) return null;
        return value.bool;
    }

    fn replaceCursor(self: *WhatsAppWebChannel, next_cursor: []const u8) !void {
        if (self.cursor) |cursor| self.allocator.free(cursor);
        self.cursor = try self.allocator.dupe(u8, next_cursor);
    }

    fn publishParsedMessage(self: *WhatsAppWebChannel, obj: std.json.ObjectMap) !bool {
        const sender = getObjString(obj, "from") orelse return false;
        const text = getObjString(obj, "text") orelse getObjString(obj, "content") orelse return false;
        const cleaned_text = std.mem.trim(u8, text, " \t\r\n");
        if (cleaned_text.len == 0) return false;

        const is_group = getObjBool(obj, "is_group") orelse false;
        const group_id = getObjString(obj, "group_id");
        const chat_id = getObjString(obj, "chat_id") orelse if (is_group) (group_id orelse sender) else sender;

        if (!self.isSenderAllowed(sender, is_group)) return false;

        const peer_kind = if (is_group) "group" else "direct";
        const peer_id = if (is_group) (group_id orelse chat_id) else sender;
        const message_id = getObjString(obj, "id");

        const session_key = try std.fmt.allocPrint(
            self.allocator,
            "whatsapp_web:{s}:{s}:{s}",
            .{ self.config.account_id, peer_kind, peer_id },
        );
        defer self.allocator.free(session_key);

        var meta_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer meta_buf.deinit(self.allocator);
        const mw = meta_buf.writer(self.allocator);
        try mw.writeAll("{\"account_id\":");
        try root.appendJsonStringW(mw, self.config.account_id);
        try mw.writeAll(",\"is_group\":");
        try mw.writeAll(if (is_group) "true" else "false");
        try mw.writeAll(",\"peer_kind\":");
        try root.appendJsonStringW(mw, peer_kind);
        try mw.writeAll(",\"peer_id\":");
        try root.appendJsonStringW(mw, peer_id);
        if (message_id) |mid| {
            try mw.writeAll(",\"message_id\":");
            try root.appendJsonStringW(mw, mid);
        }
        try mw.writeByte('}');

        const inbound = try bus.makeInboundFull(
            self.allocator,
            "whatsapp_web",
            sender,
            chat_id,
            cleaned_text,
            session_key,
            &.{},
            meta_buf.items,
        );

        if (self.event_bus) |eb| {
            eb.publishInbound(inbound) catch |err| {
                inbound.deinit(self.allocator);
                if (err != error.Closed) {
                    log.warn("failed to publish whatsapp_web inbound: {}", .{err});
                }
                return false;
            };
            return true;
        }

        inbound.deinit(self.allocator);
        return false;
    }

    /// Parse bridge poll payload and publish all accepted messages to the bus.
    pub fn ingestPollPayload(self: *WhatsAppWebChannel, payload: []const u8) !usize {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return 0;
        defer parsed.deinit();
        if (parsed.value != .object) return 0;
        const root_obj = parsed.value.object;

        if (getObjString(root_obj, "next_cursor")) |next_cursor| {
            try self.replaceCursor(next_cursor);
        }

        const messages_val = root_obj.get("messages") orelse return 0;
        if (messages_val != .array) return 0;

        var published: usize = 0;
        for (messages_val.array.items) |item| {
            if (item != .object) continue;
            if (try self.publishParsedMessage(item.object)) {
                published += 1;
            }
        }
        return published;
    }

    /// Fetch one poll batch from the sidecar and forward accepted messages.
    pub fn pollOnce(self: *WhatsAppWebChannel) !usize {
        const url = try self.endpointUrl(POLL_ENDPOINT);
        defer self.allocator.free(url);

        var body: std.ArrayListUnmanaged(u8) = .empty;
        defer body.deinit(self.allocator);
        const bw = body.writer(self.allocator);
        try bw.writeAll("{\"account_id\":");
        try root.appendJsonStringW(bw, self.config.account_id);
        if (self.cursor) |cursor| {
            try bw.writeAll(",\"cursor\":");
            try root.appendJsonStringW(bw, cursor);
        }
        try bw.writeByte('}');

        var auth_buf: [512]u8 = undefined;
        var header_slots: [1][]const u8 = undefined;
        const headers = self.authHeaders(&auth_buf, &header_slots);

        const response = try self.http_post(self.allocator, url, body.items, headers);
        defer self.allocator.free(response);

        return self.ingestPollPayload(response);
    }

    fn buildSendPayload(
        allocator: std.mem.Allocator,
        account_id: []const u8,
        target: []const u8,
        text: []const u8,
    ) ![]u8 {
        var body: std.ArrayListUnmanaged(u8) = .empty;
        errdefer body.deinit(allocator);
        const bw = body.writer(allocator);
        try bw.writeAll("{\"account_id\":");
        try root.appendJsonStringW(bw, account_id);
        try bw.writeAll(",\"to\":");
        try root.appendJsonStringW(bw, target);
        try bw.writeAll(",\"text\":");
        try root.appendJsonStringW(bw, text);
        try bw.writeByte('}');
        return body.toOwnedSlice(allocator);
    }

    fn sendChunk(self: *WhatsAppWebChannel, target: []const u8, text: []const u8) !void {
        const url = try self.endpointUrl(SEND_ENDPOINT);
        defer self.allocator.free(url);

        const payload = try buildSendPayload(self.allocator, self.config.account_id, target, text);
        defer self.allocator.free(payload);

        var auth_buf: [512]u8 = undefined;
        var header_slots: [1][]const u8 = undefined;
        const headers = self.authHeaders(&auth_buf, &header_slots);

        const response = try self.http_post(self.allocator, url, payload, headers);
        self.allocator.free(response);
    }

    pub fn sendMessage(self: *WhatsAppWebChannel, target: []const u8, text: []const u8) !void {
        var chunks = root.splitMessage(text, MAX_MESSAGE_LEN);
        while (chunks.next()) |chunk| {
            try self.sendChunk(target, chunk);
        }
    }

    pub fn probeBridgeHealth(self: *WhatsAppWebChannel) !void {
        const url = try self.endpointUrl(HEALTH_ENDPOINT);
        defer self.allocator.free(url);

        var auth_buf: [512]u8 = undefined;
        var header_slots: [1][]const u8 = undefined;
        const headers = self.authHeaders(&auth_buf, &header_slots);

        const body = try self.http_get(self.allocator, url, headers, "5");
        self.allocator.free(body);
    }

    fn pollLoop(self: *WhatsAppWebChannel) void {
        while (!self.stop_requested.load(.acquire)) {
            _ = self.pollOnce() catch |err| {
                log.warn("whatsapp_web poll failed (account_id={s}): {}", .{ self.config.account_id, err });
                continue;
            };
            std.Thread.sleep(@as(u64, self.config.poll_interval_ms) * std.time.ns_per_ms);
        }
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *WhatsAppWebChannel = @ptrCast(@alignCast(ptr));
        if (self.running) return;

        if (trimTrailingSlash(self.config.bridge_url).len == 0) {
            return error.InvalidConfiguration;
        }

        self.stop_requested.store(false, .release);
        self.running = true;
        self.poll_thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, pollLoop, .{self});
        log.info("whatsapp_web channel started (account_id={s}, bridge_url={s})", .{
            self.config.account_id,
            self.config.bridge_url,
        });
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *WhatsAppWebChannel = @ptrCast(@alignCast(ptr));
        self.stop_requested.store(true, .release);
        if (self.poll_thread) |thread| {
            thread.join();
            self.poll_thread = null;
        }
        self.running = false;
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *WhatsAppWebChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *WhatsAppWebChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *WhatsAppWebChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *WhatsAppWebChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

fn mockPollPost(allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: []const []const u8) ![]u8 {
    return allocator.dupe(u8,
        \\{"next_cursor":"cursor-2","messages":[{"id":"m-1","from":"551199999999","chat_id":"551199999999","text":"oi","is_group":false}]}
    );
}

var mock_send_calls: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn mockSendPost(allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: []const []const u8) ![]u8 {
    _ = mock_send_calls.fetchAdd(1, .monotonic);
    return allocator.dupe(u8, "{}");
}

test "whatsapp_web ingest poll payload publishes metadata and session key" {
    var event_bus = bus.Bus.init();
    defer event_bus.close();

    var ch = WhatsAppWebChannel.init(std.testing.allocator, .{
        .account_id = "wa-web-main",
        .bridge_url = "http://127.0.0.1:3301",
        .allow_from = &.{"*"},
        .group_policy = "open",
    });
    defer ch.deinit();
    ch.setBus(&event_bus);

    const payload =
        \\{
        \\  "next_cursor": "next-1",
        \\  "messages": [
        \\    {
        \\      "id": "m-01",
        \\      "from": "5511912345678",
        \\      "chat_id": "5511912345678",
        \\      "text": "hello from bridge",
        \\      "is_group": false
        \\    }
        \\  ]
        \\}
    ;

    const published = try ch.ingestPollPayload(payload);
    try std.testing.expectEqual(@as(usize, 1), published);
    try std.testing.expect(ch.cursor != null);
    try std.testing.expectEqualStrings("next-1", ch.cursor.?);

    var msg = event_bus.consumeInbound() orelse return error.TestUnexpectedResult;
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("whatsapp_web", msg.channel);
    try std.testing.expectEqualStrings("5511912345678", msg.sender_id);
    try std.testing.expectEqualStrings("5511912345678", msg.chat_id);
    try std.testing.expectEqualStrings("hello from bridge", msg.content);
    try std.testing.expectEqualStrings("whatsapp_web:wa-web-main:direct:5511912345678", msg.session_key);
    try std.testing.expect(msg.metadata_json != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.metadata_json.?, "\"account_id\":\"wa-web-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.metadata_json.?, "\"peer_kind\":\"direct\"") != null);
}

test "whatsapp_web group allowlist blocks unlisted senders" {
    var event_bus = bus.Bus.init();
    defer event_bus.close();

    var ch = WhatsAppWebChannel.init(std.testing.allocator, .{
        .account_id = "wa-web-main",
        .bridge_url = "http://127.0.0.1:3301",
        .group_policy = "allowlist",
        .group_allow_from = &.{"5511911111111"},
    });
    defer ch.deinit();
    ch.setBus(&event_bus);

    const payload =
        \\{"messages":[{"id":"m-02","from":"5511999999999","group_id":"1203630","chat_id":"1203630","text":"blocked","is_group":true}]}
    ;

    const published = try ch.ingestPollPayload(payload);
    try std.testing.expectEqual(@as(usize, 0), published);
    try std.testing.expectEqual(@as(usize, 0), event_bus.inboundDepth());
}

test "whatsapp_web pollOnce uses transport hook and updates cursor" {
    var event_bus = bus.Bus.init();
    defer event_bus.close();

    var ch = WhatsAppWebChannel.init(std.testing.allocator, .{
        .account_id = "wa-web-main",
        .bridge_url = "http://127.0.0.1:3301",
        .allow_from = &.{"*"},
    });
    defer ch.deinit();
    ch.setBus(&event_bus);
    ch.http_post = mockPollPost;

    const published = try ch.pollOnce();
    try std.testing.expectEqual(@as(usize, 1), published);
    try std.testing.expect(ch.cursor != null);
    try std.testing.expectEqualStrings("cursor-2", ch.cursor.?);

    var msg = event_bus.consumeInbound() orelse return error.TestUnexpectedResult;
    msg.deinit(std.testing.allocator);
}

test "whatsapp_web sendMessage splits long text into chunks" {
    mock_send_calls.store(0, .monotonic);

    var ch = WhatsAppWebChannel.init(std.testing.allocator, .{
        .account_id = "wa-web-main",
        .bridge_url = "http://127.0.0.1:3301",
    });
    defer ch.deinit();
    ch.http_post = mockSendPost;

    const long_msg = "A" ** (WhatsAppWebChannel.MAX_MESSAGE_LEN + 11);
    try ch.sendMessage("5511912345678", long_msg);
    try std.testing.expectEqual(@as(u32, 2), mock_send_calls.load(.monotonic));
}

test "whatsapp_web channel interface and lifecycle" {
    var ch = WhatsAppWebChannel.init(std.testing.allocator, .{
        .account_id = "wa-web-main",
        .bridge_url = "http://127.0.0.1:3301",
        .poll_interval_ms = 1,
    });
    ch.http_post = mockPollPost;
    const iface = ch.channel();
    try std.testing.expectEqualStrings("whatsapp_web", iface.name());
    try iface.start();
    try std.testing.expect(ch.healthCheck());
    iface.stop();
    try std.testing.expect(!ch.healthCheck());
    ch.deinit();
}

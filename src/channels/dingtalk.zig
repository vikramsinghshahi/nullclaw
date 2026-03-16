const std = @import("std");
const root = @import("root.zig");
const config_types = @import("../config_types.zig");

/// DingTalk channel — connects via Stream Mode WebSocket for real-time messages.
/// Replies are sent through per-message session webhook URLs.
pub const DingTalkChannel = struct {
    allocator: std.mem.Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    allow_from: []const []const u8,

    pub const GATEWAY_URL = "https://api.dingtalk.com/v1.0/gateway/connections/open";

    pub fn init(
        allocator: std.mem.Allocator,
        client_id: []const u8,
        client_secret: []const u8,
        allow_from: []const []const u8,
    ) DingTalkChannel {
        return .{
            .allocator = allocator,
            .client_id = client_id,
            .client_secret = client_secret,
            .allow_from = allow_from,
        };
    }

    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: config_types.DingTalkConfig) DingTalkChannel {
        return init(
            allocator,
            cfg.client_id,
            cfg.client_secret,
            cfg.allow_from,
        );
    }

    pub fn channelName(_: *DingTalkChannel) []const u8 {
        return "dingtalk";
    }

    pub fn isUserAllowed(self: *const DingTalkChannel, user_id: []const u8) bool {
        return root.isAllowedExact(self.allow_from, user_id);
    }

    pub fn healthCheck(_: *DingTalkChannel) bool {
        return true;
    }

    // ── Channel vtable ──────────────────────────────────────────────────────────────

    /// POST a JSON body to a DingTalk webhook URL.
    fn postJson(self: *DingTalkChannel, webhook_url: []const u8, body: []const u8) !void {
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        const result = client.fetch(.{
            .location = .{ .url = webhook_url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        }) catch return error.DingTalkApiError;
        if (result.status != .ok) return error.DingTalkApiError;
    }

    /// Send a plain markdown message via DingTalk session webhook URL.
    /// The target is expected to be the per-session webhook URL provided by the DingTalk Stream API.
    pub fn sendMessage(self: *DingTalkChannel, webhook_url: []const u8, text: []const u8) !void {
        var body_buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const w = fbs.writer();
        try w.writeAll("{\"msgtype\":\"markdown\",\"markdown\":{\"title\":\"nullclaw\",\"text\":");
        try root.appendJsonStringW(w, text);
        try w.writeAll("}}");
        try self.postJson(webhook_url, fbs.getWritten());
    }

    /// Send a rich card payload via DingTalk.
    ///
    /// - Payloads with action buttons use DingTalk `actionCard` (shows real buttons).
    /// - Payloads without buttons use `markdown` with section headers.
    pub fn sendRichMessage(self: *DingTalkChannel, webhook_url: []const u8, payload: root.OutboundPayload) !void {
        const has_buttons = for (payload.action_groups) |grp| {
            if (grp.actions.len > 0) break true;
        } else false;

        var text_buf: [8192]u8 = undefined;
        var text_fbs = std.io.fixedBufferStream(&text_buf);
        const tw = text_fbs.writer();
        if (payload.text.len > 0) {
            try tw.print("{s}\n\n", .{payload.text});
        }
        for (payload.card_sections) |sec| {
            if (sec.title.len > 0) try tw.print("### {s}\n", .{sec.title});
            try tw.print("{s}\n\n", .{sec.body});
        }
        const body_text = text_fbs.getWritten();
        const title = if (payload.card_title.len > 0) payload.card_title else "NullClaw";

        var json_buf: [16384]u8 = undefined;
        var json_fbs = std.io.fixedBufferStream(&json_buf);
        const jw = json_fbs.writer();

        if (has_buttons) {
            // actionCard: shows real buttons (tapping opens actionURL — noop close URL used here).
            try jw.writeAll("{\"msgtype\":\"actionCard\",\"actionCard\":{\"title\":");
            try root.appendJsonStringW(jw, title);
            try jw.writeAll(",\"text\":");
            try root.appendJsonStringW(jw, body_text);
            try jw.writeAll(",\"btnOrientation\":\"0\",\"btns\":[");
            var first = true;
            for (payload.action_groups) |grp| {
                for (grp.actions) |btn| {
                    if (!first) try jw.writeByte(',');
                    first = false;
                    try jw.writeAll("{\"title\":");
                    try root.appendJsonStringW(jw, btn.label);
                    try jw.writeAll(",\"actionURL\":\"dingtalk://dingtalkclient/page/close\"}");
                }
            }
            try jw.writeAll("]}");
            try jw.writeByte('}');
        } else {
            // markdown card with section headers.
            var md_buf: [8192]u8 = undefined;
            var md_fbs = std.io.fixedBufferStream(&md_buf);
            const mw = md_fbs.writer();
            if (payload.card_title.len > 0) try mw.print("## {s}\n\n", .{payload.card_title});
            try mw.writeAll(body_text);

            try jw.writeAll("{\"msgtype\":\"markdown\",\"markdown\":{\"title\":");
            try root.appendJsonStringW(jw, title);
            try jw.writeAll(",\"text\":");
            try root.appendJsonStringW(jw, md_fbs.getWritten());
            try jw.writeAll("}}");
        }

        try self.postJson(webhook_url, json_fbs.getWritten());
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        _ = ptr;
        // DingTalk: full implementation would connect via Stream Mode WebSocket.
        // Messages arrive with per-session webhook URLs for replies.
    }

    fn vtableStop(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8, _: []const []const u8) anyerror!void {
        const self: *DingTalkChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableSendRich(ptr: *anyopaque, target: []const u8, payload: root.OutboundPayload) anyerror!void {
        const self: *DingTalkChannel = @ptrCast(@alignCast(ptr));
        try self.sendRichMessage(target, payload);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *DingTalkChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *DingTalkChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .sendRich = &vtableSendRich,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *DingTalkChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

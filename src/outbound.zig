//! Abstract rich-message payload for cross-channel card rendering.
//!
//! `Payload` is the canonical representation of a rich outbound message.
//! Each channel's `sendRich()` vtable implementation translates it into the
//! platform-specific wire format (DingTalk action_card, Lark interactive card, etc.).
//!
//! Channels that do not implement `sendRich` receive a plain-text fallback via
//! `Channel.sendRich()`, which concatenates title, section bodies, and choice labels.
//!
//! Ownership: all slices inside Payload are borrowed — the caller owns the memory
//! and must ensure it outlives the `sendRich` call.

/// A section of text content within a card (title + body).
pub const CardSection = struct {
    title: []const u8 = "",
    body: []const u8,
};

/// A group of action buttons presented together.
pub const ActionGroup = struct {
    actions: []const ChoiceButton,
};

/// A single clickable button.
pub const ChoiceButton = struct {
    /// Machine-readable identifier sent back as submit text.
    id: []const u8,
    /// Human-readable label shown on the button.
    label: []const u8,
};

/// Rich outbound message payload.
/// All fields are optional; channels use only what they support.
pub const Payload = struct {
    /// Optional card header / title.
    card_title: []const u8 = "",
    /// Plain text fallback (always rendered by channels that don't support cards).
    text: []const u8 = "",
    /// Structured content sections.
    card_sections: []const CardSection = &.{},
    /// Rows of action buttons.
    action_groups: []const ActionGroup = &.{},

    /// Build a plain-text fallback string from all card fields.
    /// Caller must free the returned slice.
    pub fn toPlainText(self: Payload, allocator: @import("std").mem.Allocator) ![]u8 {
        var buf: @import("std").ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        if (self.card_title.len > 0) {
            try buf.appendSlice(allocator, self.card_title);
            try buf.appendSlice(allocator, "\n\n");
        }
        if (self.text.len > 0) {
            try buf.appendSlice(allocator, self.text);
            try buf.append(allocator, '\n');
        }
        for (self.card_sections) |sec| {
            if (sec.title.len > 0) {
                try buf.appendSlice(allocator, sec.title);
                try buf.append(allocator, '\n');
            }
            try buf.appendSlice(allocator, sec.body);
            try buf.append(allocator, '\n');
        }
        for (self.action_groups) |grp| {
            for (grp.actions) |btn| {
                try buf.append(allocator, '[');
                try buf.appendSlice(allocator, btn.label);
                try buf.append(allocator, ']');
                try buf.append(allocator, ' ');
            }
            if (grp.actions.len > 0) try buf.append(allocator, '\n');
        }
        return buf.toOwnedSlice(allocator);
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────────────────

const std = @import("std");

test "Payload toPlainText empty payload" {
    const p = Payload{};
    const text = try p.toPlainText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "Payload toPlainText title only" {
    const p = Payload{ .card_title = "My Title" };
    const text = try p.toPlainText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("My Title\n\n", text);
}

test "Payload toPlainText with sections and buttons" {
    const buttons = [_]ChoiceButton{
        .{ .id = "yes", .label = "Yes" },
        .{ .id = "no", .label = "No" },
    };
    const groups = [_]ActionGroup{.{ .actions = &buttons }};
    const sections = [_]CardSection{.{ .title = "Section", .body = "Body text" }};

    const p = Payload{
        .card_title = "Question",
        .card_sections = &sections,
        .action_groups = &groups,
    };
    const text = try p.toPlainText(std.testing.allocator);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Question") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Section") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Body text") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Yes]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[No]") != null);
}

test "Payload toPlainText text field included" {
    const p = Payload{ .text = "hello world" };
    const text = try p.toPlainText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
}

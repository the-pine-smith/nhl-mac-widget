const std = @import("std");
const http = std.http;
const json = std.json;
const objc = @cImport({
    @cInclude("objc/message.h");
    @cInclude("objc/runtime.h");
});

const NSString = *opaque {};
const NSMenu = *opaque {};
const NSMenuItem = *opaque {};
const NSStatusBar = *opaque {};
const NSStatusItem = *opaque {};
const NSApplication = *opaque {};
const NSAutoreleasePool = *opaque {};
const NSImage = *opaque {};
const SEL = *opaque {};
const Class = *opaque {};
const id = *opaque {};

extern fn objc_getClass(name: [*:0]const u8) Class;
extern fn sel_registerName(str: [*:0]const u8) SEL;
extern fn objc_msgSend() void;
extern fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
extern fn objc_registerClassPair(cls: Class) void;
extern fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;

fn msgSend(obj: id, sel_name: [*:0]const u8) id {
    const sel = sel_registerName(sel_name);
    const send = @as(*const fn (id, SEL) callconv(.c) id, @ptrCast(&objc_msgSend));
    return send(obj, sel);
}

fn msgSendClass(class: Class, sel_name: [*:0]const u8) id {
    const sel = sel_registerName(sel_name);
    const send = @as(*const fn (Class, SEL) callconv(.c) id, @ptrCast(&objc_msgSend));
    return send(class, sel);
}

fn msgSendClass2(class: Class, sel_name: [*:0]const u8, arg1: anytype, arg2: anytype) id {
    const sel = sel_registerName(sel_name);
    const send = @as(*const fn (Class, SEL, @TypeOf(arg1), @TypeOf(arg2)) callconv(.c) id, @ptrCast(&objc_msgSend));
    return send(class, sel, arg1, arg2);
}

fn msgSend1(obj: id, sel_name: [*:0]const u8, arg: id) id {
    const sel = sel_registerName(sel_name);
    const send = @as(*const fn (id, SEL, @TypeOf(arg)) callconv(.c) id, @ptrCast(&objc_msgSend));
    return send(obj, sel, arg);
}

fn msgSend2(obj: id, sel_name: [*:0]const u8, arg1: id, arg2: id) id {
    const sel = sel_registerName(sel_name);
    const send = @as(*const fn (id, SEL, @TypeOf(arg1), @TypeOf(arg2)) callconv(.c) id, @ptrCast(&objc_msgSend));
    return send(obj, sel, arg1, arg2);
}

fn createNSString(str: []const u8) NSString {
    const NSStringClass = objc_getClass("NSString");
    const alloc = msgSendClass(NSStringClass, "alloc");
    const sel = sel_registerName("initWithBytes:length:encoding:");
    const send = @as(*const fn (id, SEL, [*]const u8, usize, usize) callconv(.c) NSString, @ptrCast(&objc_msgSend));
    return send(alloc, sel, str.ptr, str.len, 4);
}

fn setMenuItemEnabled(item: id, enabled: bool) void {
    const sel = sel_registerName("setEnabled:");
    const send = @as(*const fn (id, SEL, bool) callconv(.c) void, @ptrCast(&objc_msgSend));
    send(item, sel, enabled);
}

var global_allocator: std.mem.Allocator = undefined;
var status_item: NSStatusItem = undefined;
var team_name: []const u8 = "Seattle Kraken";
var home_abbrev: []const u8 = "SEA";
var away_abbrev: []const u8 = "SEA";
var next_game_date: []const u8 = undefined;
var venue: []const u8 = "Climate Pledge Arena";
var division: []const u8 = "Pacific";
var roster_count: usize = 0;
var last_update: []const u8 = "Never";
var app_delegate: id = undefined;

fn fetchRosterData(alloc: std.mem.Allocator) !json.Parsed(json.Value) {
    std.debug.print("Fetching roster data...\n", .{});
    var client = http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse("https://api-web.nhle.com/v1/roster/SEA/current");

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &body.writer,
    });

    if (fetch_res.status != .ok) {
        std.debug.print("Error: HTTP {d}\n", .{@intFromEnum(fetch_res.status)});
        return error.HttpError;
    }

    const response_body = try body.toOwnedSlice();
    defer alloc.free(response_body);

    return try json.parseFromSlice(json.Value, alloc, response_body, .{});
}

fn fetchTeamData(alloc: std.mem.Allocator) !json.Parsed(json.Value) {
    std.debug.print("Fetching team data...\n", .{});
    var client = http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse("https://api-web.nhle.com/v1/club-schedule/SEA/week/now");

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const fetch_res = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &body.writer,
    });

    if (fetch_res.status != .ok) {
        std.debug.print("Error: HTTP {d}\n", .{@intFromEnum(fetch_res.status)});
        return error.HttpError;
    }

    const response_body = try body.toOwnedSlice();
    defer alloc.free(response_body);

    return try json.parseFromSlice(json.Value, alloc, response_body, .{});
}

export fn refreshData(_: id, _: SEL, _: id) callconv(.c) void {
    refreshMenuData() catch |e| {
        std.debug.print("Error refreshing: {}\n", .{e});
    };
}

export fn quitApp(_: id, _: SEL, _: id) callconv(.c) void {
    const app = msgSendClass(objc_getClass("NSApplication"), "sharedApplication");
    _ = msgSend1(app, "terminate:", @as(id, @ptrCast(app)));
}

fn refreshMenuData() !void {
    std.debug.print("Refreshing game data...\n", .{});

    const game_data = try fetchTeamData(global_allocator);
    defer game_data.deinit();

    const now_str = try timestampToDateString(std.time.timestamp(), global_allocator);
    defer global_allocator.free(now_str);

    const games = game_data.value.object.get("games").?.array;
    if (games.items.len > 0) {
        for (games.items) |game| {
            if (game.object.get("gameDate")) |game_date| {
                const game_date_val = game_date.string;
                if (std.mem.lessThan(u8, game_date_val, now_str)) {
                    std.debug.print("Skipping past game: {s}\n", .{game_date_val});
                    continue;
                }
                away_abbrev = try global_allocator.dupe(u8, game.object.get("awayTeam").?.object.get("abbrev").?.string);
                home_abbrev = try global_allocator.dupe(u8, game.object.get("homeTeam").?.object.get("abbrev").?.string);
                next_game_date = game_date_val;
                break;
            }
        }
    }

    const roster_data = try fetchRosterData(global_allocator);
    defer roster_data.deinit();

    const roster = roster_data.value.object;
    if (roster.get("roster")) |roster_array_value| {
        roster_count = roster_array_value.array.items.len;
    }

    const timestamp = std.time.timestamp();
    last_update = try std.fmt.allocPrint(global_allocator, "{d}", .{timestamp});

    std.debug.print("Data refreshed success\n", .{});

    buildMenu();
}

fn createMenuItem(title: NSString, key: ?NSString, action: ?SEL) id {
    const NSMenuItemClass = objc_getClass("NSMenuItem");
    const alloc = msgSendClass(NSMenuItemClass, "alloc");

    const key_equiv = key orelse createNSString("");
    const sel = sel_registerName("initWithTitle:action:keyEquivalent:");
    const send = @as(*const fn (id, SEL, NSString, ?SEL, NSString) callconv(.c) id, @ptrCast(&objc_msgSend));

    return send(alloc, sel, title, action, key_equiv);
}

fn buildMenu() void {
    const menu = msgSend(@as(id, @ptrCast(status_item)), "menu");
    _ = msgSend(menu, "removeAllItems");

    const title_str = createNSString("Seattle Kraken");
    const title_item = createMenuItem(title_str, null, null);
    // setMenuItemEnabled(title_item, true);
    _ = msgSend1(menu, "addItem:", title_item);

    const sep1 = msgSendClass(objc_getClass("NSMenuItem"), "separatorItem");
    _ = msgSend1(menu, "addItem:", sep1);

    var buf: [256]u8 = undefined;
    const next_title_str = createNSString("Next Game Info");
    const next_title_item = createMenuItem(next_title_str, null, null);
    // setMenuItemEnabled(next_title_item, true);
    _ = msgSend1(menu, "addItem:", next_title_item);

    const abbrev_txt = std.fmt.bufPrint(&buf, "{s} @ {s}", .{ away_abbrev, home_abbrev }) catch "Unkown teams";
    const abbrev_str = createNSString(abbrev_txt);
    const abbrev_item = createMenuItem(abbrev_str, null, null);
    // setMenuItemEnabled(abbrev_item, true);
    _ = msgSend1(menu, "addItem:", abbrev_item);

    const game_date_txt = std.fmt.bufPrint(&buf, "on {s}", .{next_game_date}) catch "Unkown teams";
    const game_date_str = createNSString(game_date_txt);
    const game_date_item = createMenuItem(game_date_str, null, null);
    // setMenuItemEnabled(game_date_item, true);
    _ = msgSend1(menu, "addItem:", game_date_item);

    const sep2 = msgSendClass(objc_getClass("NSMenuItem"), "separatorItem");
    _ = msgSend1(menu, "addItem:", sep2);

    const refresh_str = createNSString("Refresh Data");
    const refresh_sel = sel_registerName("refreshData:");
    const refresh_item = createMenuItem(refresh_str, null, refresh_sel);
    _ = msgSend1(menu, "addItem:", refresh_item);

    const sep3 = msgSendClass(objc_getClass("NSMenuItem"), "separatorItem");
    _ = msgSend1(menu, "addItem:", sep3);

    const quit_str = createNSString("Quit");
    const quit_sel = sel_registerName("quitApp:");
    const quit_item = createMenuItem(quit_str, null, quit_sel);
    _ = msgSend1(menu, "addItem:", quit_item);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;

    const pool = msgSendClass(objc_getClass("NSAutoReleasePool"), "alloc");
    _ = msgSend(pool, "init");
    defer _ = msgSend(pool, "drain");

    const app = msgSendClass(objc_getClass("NSApplication"), "sharedApplication");
    const sel = sel_registerName("setActivationPolicy:");
    const send = @as(*const fn (id, SEL, c_int) callconv(.c) void, @ptrCast(&objc_msgSend));
    send(app, sel, 2);

    const status_bar = msgSendClass(objc_getClass("NSStatusBar"), "systemStatusBar");
    const sel2 = sel_registerName("statusItemWithLength:");
    const send2 = @as(*const fn (id, SEL, f64) callconv(.c) NSStatusItem, @ptrCast(&objc_msgSend));
    status_item = send2(status_bar, sel2, -1.0);

    const button = msgSend(@as(id, @ptrCast(status_item)), "button");
    const NSImageClass = objc_getClass("NSImage");
    const symbol_name = createNSString("hockey.puck");
    const symbol_desc = createNSString("puck");
    const image = msgSendClass2(NSImageClass, "imageWithSystemSymbolName:accessibilityDescription:", symbol_name, symbol_desc);
    _ = msgSend1(button, "setImage:", image);

    const menu = msgSendClass(objc_getClass("NSMenu"), "alloc");
    _ = msgSend(menu, "init");
    const sel_setAuto = sel_registerName("setAutoenablesItems:");
    const send_bool = @as(*const fn (id, SEL, bool) callconv(.c) void, @ptrCast(&objc_msgSend));
    send_bool(menu, sel_setAuto, false);
    _ = msgSend1(@as(id, @ptrCast(status_item)), "setMenu:", menu);

    const NSObjectClass = objc_getClass("NSObject");
    const delegateClassName = "AppDelegate";
    const AppDelegateClass = objc_allocateClassPair(NSObjectClass, delegateClassName, 0);

    const refreshDataSel = sel_registerName("refreshData:");
    _ = class_addMethod(AppDelegateClass, refreshDataSel, @ptrCast(&refreshData), "v@:@");

    const quitAppSel = sel_registerName("quitApp:");
    _ = class_addMethod(AppDelegateClass, quitAppSel, @ptrCast(&quitApp), "v@:@");

    objc_registerClassPair(AppDelegateClass);

    app_delegate = msgSendClass(AppDelegateClass, "alloc");
    app_delegate = msgSend(app_delegate, "init");

    std.debug.print("Fetching initial Kraken data...\n", .{});
    refreshMenuData() catch |err| {
        std.debug.print("Error fetching initial data: {}\n", .{err});
        buildMenu();
    };

    std.debug.print("Kraken menu bar app running!\n", .{});
    _ = msgSend(app, "run");
}

// Utilities
fn timestampToDateString(timestamp: i64, alloc: std.mem.Allocator) ![]u8 {
    const epoch_seconds = @as(u64, @intCast(timestamp));
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day_val = epoch_day.getEpochDay();
    const year_val = day_val.calculateYearDay();
    const month_val = year_val.calculateMonthDay();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_val.year,
        month_val.month,
        month_val.day_index + 1,
    });
}

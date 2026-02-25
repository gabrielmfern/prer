const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Title: ", .{});
    const raw_title = try readLineAlloc(allocator, 1024);
    defer allocator.free(raw_title);
    const title = std.mem.trim(u8, raw_title, " \t\r\n");
    if (title.len == 0) {
        std.debug.print("Title cannot be empty.\n", .{});
        return error.EmptyTitle;
    }

    const body = try editBodyInNvim(allocator);
    defer allocator.free(body);

    const repo_name_with_owner = try runCommandCapture(allocator, &.{
        "gh",
        "repo",
        "view",
        "--json",
        "nameWithOwner",
        "-q",
        ".nameWithOwner",
    });
    defer allocator.free(repo_name_with_owner);
    const repo_name = std.mem.trim(u8, repo_name_with_owner, " \t\r\n");
    if (repo_name.len == 0) {
        std.debug.print("Unable to determine repository with `gh repo view`.\n", .{});
        return error.RepositoryNotFound;
    }

    const collaborators_endpoint = try std.fmt.allocPrint(
        allocator,
        "repos/{s}/collaborators",
        .{repo_name},
    );
    defer allocator.free(collaborators_endpoint);

    const collaborators_output = try runCommandCapture(allocator, &.{
        "gh",
        "api",
        collaborators_endpoint,
        "--jq",
        ".[].login",
    });
    defer allocator.free(collaborators_output);

    var reviewers = try parseReviewers(allocator, collaborators_output);
    defer freeReviewerList(allocator, &reviewers);

    if (reviewers.items.len == 0) {
        std.debug.print("No collaborators available to review this PR.\n", .{});
        return error.NoReviewersAvailable;
    }

    const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home_dir);

    const dot_config_dir = try std.fmt.allocPrint(allocator, "{s}/.config", .{home_dir});
    defer allocator.free(dot_config_dir);
    const prer_config_dir = try std.fmt.allocPrint(allocator, "{s}/prer", .{dot_config_dir});
    defer allocator.free(prer_config_dir);
    const reviewers_map_path = try std.fmt.allocPrint(allocator, "{s}/reviewers.json", .{prer_config_dir});
    defer allocator.free(reviewers_map_path);

    try ensureDirExists(dot_config_dir);
    try ensureDirExists(prer_config_dir);
    try ensureReviewerMapFileExists(allocator, reviewers_map_path, reviewers.items);

    const reviewer = try chooseReviewer(allocator, reviewers.items);
    defer allocator.free(reviewer);

    const pr_create_output = try runCommandCapture(allocator, &.{
        "gh",
        "pr",
        "create",
        "--title",
        title,
        "--body",
        body,
        "--reviewer",
        reviewer,
    });
    defer allocator.free(pr_create_output);

    const pr_url = std.mem.trim(u8, pr_create_output, " \t\r\n");
    if (pr_url.len == 0) {
        std.debug.print("`gh pr create` did not return a URL.\n", .{});
        return error.MissingPrUrl;
    }

    const slack_handle = try loadSlackHandle(allocator, reviewers_map_path, reviewer);
    defer allocator.free(slack_handle);

    const slack_message = try std.fmt.allocPrint(
        allocator,
        "[:open-pr: {s} @{s}]({s})",
        .{ title, slack_handle, pr_url },
    );
    defer allocator.free(slack_message);

    try copyToClipboard(allocator, slack_message);
    std.debug.print("Copied to clipboard: {s}\n", .{slack_message});
    std.debug.print("PR created: {s}\n", .{pr_url});
}

fn readLineAlloc(allocator: std.mem.Allocator, max_len: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var stdin_file = std.fs.File.stdin();
    var byte: [1]u8 = undefined;

    while (true) {
        const n = try stdin_file.read(&byte);
        if (n == 0) break;
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;

        if (out.items.len >= max_len) return error.LineTooLong;
        try out.append(allocator, byte[0]);
    }

    return out.toOwnedSlice(allocator);
}

fn editBodyInNvim(allocator: std.mem.Allocator) ![]u8 {
    const random_suffix = std.crypto.random.int(u64);
    const temp_path = try std.fmt.allocPrint(allocator, "/tmp/prer-{x}.md", .{random_suffix});
    defer allocator.free(temp_path);
    defer std.fs.deleteFileAbsolute(temp_path) catch {};

    {
        const temp_file = try std.fs.createFileAbsolute(temp_path, .{});
        temp_file.close();
    }

    std.debug.print("Opening nvim for PR body...\n", .{});
    var nvim_child = std.process.Child.init(&.{ "nvim", temp_path }, allocator);
    nvim_child.stdin_behavior = .Inherit;
    nvim_child.stdout_behavior = .Inherit;
    nvim_child.stderr_behavior = .Inherit;
    try nvim_child.spawn();
    const nvim_term = try nvim_child.wait();
    switch (nvim_term) {
        .Exited => |exit_code| {
            if (exit_code != 0) return error.EditorFailed;
        },
        else => return error.EditorFailed,
    }

    var temp_file = try std.fs.openFileAbsolute(temp_path, .{});
    defer temp_file.close();
    const body_full = try temp_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(body_full);

    const body_trimmed = std.mem.trim(u8, body_full, " \t\r\n");
    if (body_trimmed.len == 0) {
        std.debug.print("PR body cannot be empty.\n", .{});
        return error.EmptyBody;
    }

    return allocator.dupe(u8, body_trimmed);
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code == 0) {
                return result.stdout;
            }
        },
        else => {},
    }

    std.debug.print("Command failed: {s}\n{s}\n", .{ argv[0], result.stderr });
    allocator.free(result.stdout);
    return error.CommandFailed;
}

fn parseReviewers(allocator: std.mem.Allocator, raw_output: []const u8) !std.ArrayList([]const u8) {
    var reviewers: std.ArrayList([]const u8) = .empty;
    errdefer freeReviewerList(allocator, &reviewers);

    var it = std.mem.splitScalar(u8, raw_output, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        try reviewers.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return reviewers;
}

fn freeReviewerList(allocator: std.mem.Allocator, reviewers: *std.ArrayList([]const u8)) void {
    for (reviewers.items) |reviewer| {
        allocator.free(reviewer);
    }
    reviewers.deinit(allocator);
}

fn ensureDirExists(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn ensureReviewerMapFileExists(
    allocator: std.mem.Allocator,
    map_path: []const u8,
    reviewers: []const []const u8,
) !void {
    const existing = std.fs.openFileAbsolute(map_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (existing) |file| {
        file.close();
        return;
    }

    var file = try std.fs.createFileAbsolute(map_path, .{});
    defer file.close();

    try file.writeAll("{\n");
    for (reviewers, 0..) |reviewer, idx| {
        const comma = if (idx + 1 == reviewers.len) "" else ",";
        const line = try std.fmt.allocPrint(
            allocator,
            "  \"{s}\": \"{s}\"{s}\n",
            .{ reviewer, reviewer, comma },
        );
        defer allocator.free(line);
        try file.writeAll(line);
    }
    try file.writeAll("}\n");

    std.debug.print(
        "Created default reviewer map at {s}. Edit values to Slack handles.\n",
        .{map_path},
    );
}

fn chooseReviewer(allocator: std.mem.Allocator, reviewers: []const []const u8) ![]u8 {
    std.debug.print("\nReviewers:\n", .{});
    for (reviewers, 0..) |reviewer, idx| {
        std.debug.print("{d}) {s}\n", .{ idx + 1, reviewer });
    }

    std.debug.print("Reviewer number: ", .{});
    const raw_selection = try readLineAlloc(allocator, 32);
    defer allocator.free(raw_selection);
    const selection_str = std.mem.trim(u8, raw_selection, " \t\r\n");
    if (selection_str.len == 0) return error.EmptyReviewerSelection;

    const selection = std.fmt.parseUnsigned(usize, selection_str, 10) catch {
        return error.InvalidReviewerSelection;
    };
    if (selection == 0 or selection > reviewers.len) return error.InvalidReviewerSelection;

    return allocator.dupe(u8, reviewers[selection - 1]);
}

fn loadSlackHandle(
    allocator: std.mem.Allocator,
    map_path: []const u8,
    reviewer: []const u8,
) ![]u8 {
    var file = std.fs.openFileAbsolute(map_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, reviewer),
        else => return err,
    };
    defer file.close();

    const raw_json = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw_json);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{
        .allocate = .alloc_always,
    }) catch {
        return allocator.dupe(u8, reviewer);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return allocator.dupe(u8, reviewer);
    }

    if (parsed.value.object.get(reviewer)) |value| {
        if (value == .string) {
            const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
            const handle = trimLeadingAt(trimmed);
            if (handle.len != 0) {
                return allocator.dupe(u8, handle);
            }
        }
    }

    return allocator.dupe(u8, reviewer);
}

fn trimLeadingAt(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and s[start] == '@') {
        start += 1;
    }
    return s[start..];
}

fn copyToClipboard(allocator: std.mem.Allocator, text: []const u8) !void {
    var child = std.process.Child.init(&.{"wl-copy"}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdin_file = child.stdin orelse return error.ClipboardInputUnavailable;
    try stdin_file.writeAll(text);
    stdin_file.close();
    child.stdin = null;

    var stderr_buffer: std.ArrayList(u8) = .empty;
    defer stderr_buffer.deinit(allocator);

    if (child.stderr) |stderr_file| {
        const err_text = try stderr_file.readToEndAlloc(allocator, 64 * 1024);
        defer allocator.free(err_text);
        if (err_text.len > 0) {
            try stderr_buffer.appendSlice(allocator, err_text);
        }
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("wl-copy failed:\n{s}\n", .{stderr_buffer.items});
                return error.ClipboardCopyFailed;
            }
        },
        else => return error.ClipboardCopyFailed,
    }
}

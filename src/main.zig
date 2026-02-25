const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runPreflightChecks(allocator);

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

    const current_branch = try getCurrentBranch(allocator);
    defer allocator.free(current_branch);

    std.debug.print("Creating pull request...\n", .{});

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
        "--head",
        current_branch,
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
    const result = try runCommand(allocator, argv);
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

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024,
    });
}

fn runPreflightChecks(allocator: std.mem.Allocator) !void {
    // Ensure the branch has an origin remote.
    {
        const remote_result = try runCommand(allocator, &.{ "git", "remote", "get-url", "origin" });
        defer allocator.free(remote_result.stdout);
        defer allocator.free(remote_result.stderr);

        const has_origin = switch (remote_result.term) {
            .Exited => |code| code == 0 and std.mem.trim(u8, remote_result.stdout, " \t\r\n").len > 0,
            else => false,
        };

        if (!has_origin) {
            std.debug.print("No `origin` remote found. Configure a remote before creating a PR.\n", .{});
            return error.MissingOriginRemote;
        }
    }

    var needs_attention = false;
    const current_branch = try getCurrentBranch(allocator);
    defer allocator.free(current_branch);

    // Fail fast if an open PR already exists for this branch.
    if (try findOpenPrUrlForBranch(allocator, current_branch)) |existing_pr_url| {
        defer allocator.free(existing_pr_url);
        std.debug.print(
            "An open PR already exists for branch `{s}`: {s}\n",
            .{ current_branch, existing_pr_url },
        );
        return error.PullRequestAlreadyExists;
    }

    // Check for uncommitted changes.
    {
        const status_result = try runCommand(allocator, &.{ "git", "status", "--porcelain" });
        defer allocator.free(status_result.stdout);
        defer allocator.free(status_result.stderr);

        if (status_result.term == .Exited and status_result.term.Exited == 0) {
            const has_uncommitted = std.mem.trim(u8, status_result.stdout, " \t\r\n").len > 0;
            if (has_uncommitted) {
                needs_attention = true;
                std.debug.print(
                    "Working tree has uncommitted changes. Consider committing or stashing first.\n",
                    .{},
                );
            }
        }
    }

    // Check for an upstream and whether local commits are pushed.
    var has_upstream = false;
    {
        const upstream_result = try runCommand(
            allocator,
            &.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" },
        );
        defer allocator.free(upstream_result.stdout);
        defer allocator.free(upstream_result.stderr);

        has_upstream = upstream_result.term == .Exited and upstream_result.term.Exited == 0;
        if (!has_upstream) {
            needs_attention = true;
            std.debug.print(
                "Current branch has no upstream. Push with `git push -u origin <branch>` before creating a PR.\n",
                .{},
            );
        } else {
            const ahead_count = try commitCount(allocator, &.{ "git", "rev-list", "--count", "@{upstream}..HEAD" });
            if (ahead_count > 0) {
                needs_attention = true;
                std.debug.print(
                    "Current branch is ahead of upstream by {d} commit(s). Consider pushing first.\n",
                    .{ahead_count},
                );
            }
        }
    }

    // Check commit delta relative to PR target branch (default branch).
    const base_branch_output = try runCommandCapture(allocator, &.{
        "gh",
        "repo",
        "view",
        "--json",
        "defaultBranchRef",
        "-q",
        ".defaultBranchRef.name",
    });
    defer allocator.free(base_branch_output);
    const base_branch = std.mem.trim(u8, base_branch_output, " \t\r\n");
    if (base_branch.len == 0) return error.TargetBranchUnknown;

    const base_ref = try std.fmt.allocPrint(allocator, "origin/{s}", .{base_branch});
    defer allocator.free(base_ref);

    const base_to_head_range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{base_ref});
    defer allocator.free(base_to_head_range);
    const local_base_to_head_range = try std.fmt.allocPrint(allocator, "{s}..HEAD", .{base_branch});
    defer allocator.free(local_base_to_head_range);

    const ahead_of_base = commitCount(allocator, &.{ "git", "rev-list", "--count", base_to_head_range }) catch blk: {
        // Fallback in case origin/<base> is unavailable locally.
        break :blk try commitCount(allocator, &.{ "git", "rev-list", "--count", local_base_to_head_range });
    };
    if (ahead_of_base == 0) {
        std.debug.print(
            "No commits between current branch and target `{s}`. Nothing to open in a PR.\n",
            .{base_branch},
        );
        return error.NoCommitsToPullRequest;
    }

    const head_to_base_range = try std.fmt.allocPrint(allocator, "HEAD..{s}", .{base_ref});
    defer allocator.free(head_to_base_range);
    const behind_base = commitCount(allocator, &.{ "git", "rev-list", "--count", head_to_base_range }) catch 0;
    if (behind_base > 0) {
        needs_attention = true;
        std.debug.print(
            "Target branch `{s}` is ahead by {d} commit(s). Consider rebasing/merging before creating a PR.\n",
            .{ base_branch, behind_base },
        );
    }

    if (needs_attention) {
        const proceed = try confirmYesNo(
            allocator,
            "Continue creating PR anyway? [y/N]: ",
        );
        if (!proceed) {
            return error.AbortedByUser;
        }
    }
}

fn commitCount(allocator: std.mem.Allocator, argv: []const []const u8) !usize {
    const count_text = try runCommandCapture(allocator, argv);
    defer allocator.free(count_text);
    const trimmed = std.mem.trim(u8, count_text, " \t\r\n");
    return std.fmt.parseUnsigned(usize, trimmed, 10);
}

fn confirmYesNo(allocator: std.mem.Allocator, prompt: []const u8) !bool {
    std.debug.print("{s}", .{prompt});
    const answer_raw = try readLineAlloc(allocator, 16);
    defer allocator.free(answer_raw);
    const answer = std.mem.trim(u8, answer_raw, " \t\r\n");
    if (answer.len == 0) return false;
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn getCurrentBranch(allocator: std.mem.Allocator) ![]u8 {
    const current_branch_output = try runCommandCapture(allocator, &.{
        "git",
        "rev-parse",
        "--abbrev-ref",
        "HEAD",
    });
    defer allocator.free(current_branch_output);

    const current_branch = std.mem.trim(u8, current_branch_output, " \t\r\n");
    if (current_branch.len == 0) return error.CurrentBranchUnknown;
    return allocator.dupe(u8, current_branch);
}

fn findOpenPrUrlForBranch(allocator: std.mem.Allocator, branch: []const u8) !?[]u8 {
    const pr_url_output = try runCommandCapture(allocator, &.{
        "gh",
        "pr",
        "list",
        "--head",
        branch,
        "--state",
        "open",
        "--json",
        "url",
        "--limit",
        "1",
        "--jq",
        ".[0].url",
    });
    defer allocator.free(pr_url_output);

    const pr_url = std.mem.trim(u8, pr_url_output, " \t\r\n");
    if (pr_url.len == 0 or std.mem.eql(u8, pr_url, "null")) {
        return null;
    }

    const owned_url = try allocator.dupe(u8, pr_url);
    return owned_url;
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

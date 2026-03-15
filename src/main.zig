const std = @import("std");

const Allocator = std.mem.Allocator;
const Command = enum { chat, ask, models, help };

const Nord = struct {
    const title = "38;2;163;190;140";
    const accent = "38;2;136;192;208";
    const prompt = "38;2;235;203;139";
    const muted = "38;2;129;161;193";
    const text = "38;2;216;222;233";
    const reset = "0";
};

const Config = struct {
    remote_host: []const u8,
    remote_ollama: []const u8,
    default_model: []const u8,
};

const Parsed = struct {
    command: Command = .chat,
    prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

fn useColor() bool {
    if (std.process.hasEnvVarConstant("FORCE_COLOR")) return true;
    if (std.process.hasEnvVarConstant("NO_COLOR")) return false;
    return std.posix.isatty(std.fs.File.stdout().handle);
}

fn paint(writer: *std.Io.Writer, enabled: bool, color: []const u8, text: []const u8) !void {
    if (!enabled) return writer.writeAll(text);
    try writer.print("\x1b[{s}m{s}\x1b[{s}m", .{ color, text, Nord.reset });
}

fn printlnColor(writer: *std.Io.Writer, enabled: bool, color: []const u8, text: []const u8) !void {
    try paint(writer, enabled, color, text);
    try writer.writeByte('\n');
}

fn joinArgs(allocator: Allocator, args: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " ", args);
}

fn parseArgs(allocator: Allocator) !Parsed {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) return .{};

    var parsed = Parsed{};
    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "ask")) {
            parsed.command = .ask;
            if (idx + 1 >= args.len) return error.MissingPrompt;
            parsed.prompt = try joinArgs(allocator, args[idx + 1 ..]);
            break;
        }
        if (std.mem.eql(u8, arg, "models")) {
            parsed.command = .models;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
            parsed.command = .help;
            continue;
        }
        if (std.mem.eql(u8, arg, "--model")) {
            idx += 1;
            if (idx >= args.len) return error.MissingModel;
            parsed.model = try allocator.dupe(u8, args[idx]);
            continue;
        }

        if (parsed.command == .chat) {
            parsed.command = .ask;
            parsed.prompt = try joinArgs(allocator, args[idx..]);
            break;
        }
    }

    return parsed;
}

fn configFromEnv(allocator: Allocator) !Config {
    const remote_host = std.process.getEnvVarOwned(allocator, "MINILLM_REMOTE_HOST") catch try allocator.dupe(u8, "user@example-host");
    const remote_ollama = std.process.getEnvVarOwned(allocator, "MINILLM_REMOTE_OLLAMA") catch try allocator.dupe(u8, "/Applications/Ollama.app/Contents/Resources/ollama");
    const default_model = std.process.getEnvVarOwned(allocator, "MINILLM_MODEL") catch try allocator.dupe(u8, "jj-general");

    return .{
        .remote_host = remote_host,
        .remote_ollama = remote_ollama,
        .default_model = default_model,
    };
}

fn freeConfig(allocator: Allocator, config: Config) void {
    allocator.free(config.remote_host);
    allocator.free(config.remote_ollama);
    allocator.free(config.default_model);
}

fn stripTerminalNoise(allocator: Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == 0x1b) {
            i += 1;
            if (i < raw.len and raw[i] == '[') {
                i += 1;
                while (i < raw.len) : (i += 1) {
                    const ch = raw[i];
                    if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')) {
                        i += 1;
                        break;
                    }
                }
            }
            continue;
        }
        if (c == '\r' or c == 0x08) {
            i += 1;
            continue;
        }
        if ((c < 0x20 or c == 0x7f) and c != '\n' and c != '\t') {
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }

    const owned = try out.toOwnedSlice(allocator);
    defer allocator.free(owned);
    const trimmed = std.mem.trim(u8, owned, " \n\t");
    return allocator.dupe(u8, trimmed);
}

fn runChild(allocator: Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    errdefer _ = child.kill() catch {};
    try child.collectOutput(allocator, &stdout, &stderr, 1024 * 1024);

    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                const stderr_owned = try stderr.toOwnedSlice(allocator);
                defer allocator.free(stderr_owned);
                const stderr_clean = try stripTerminalNoise(allocator, stderr_owned);
                defer allocator.free(stderr_clean);
                if (stderr_clean.len > 0) std.debug.print("{s}\n", .{stderr_clean});
                return error.CommandFailed;
            }
        },
        else => {
            return error.CommandFailed;
        },
    }

    const stdout_owned = try stdout.toOwnedSlice(allocator);
    defer allocator.free(stdout_owned);
    const clean = try stripTerminalNoise(allocator, stdout_owned);
    return clean;
}

fn appendShellQuoted(allocator: Allocator, builder: *std.ArrayList(u8), arg: []const u8) !void {
    try builder.append(allocator, '\'');
    for (arg) |ch| {
        if (ch == '\'') {
            try builder.appendSlice(allocator, "'\\''");
        } else {
            try builder.append(allocator, ch);
        }
    }
    try builder.append(allocator, '\'');
}

fn buildRemoteCommand(allocator: Allocator, remote_ollama: []const u8, argv_tail: []const []const u8) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);

    try appendShellQuoted(allocator, &command, remote_ollama);
    for (argv_tail) |arg| {
        try command.append(allocator, ' ');
        try appendShellQuoted(allocator, &command, arg);
    }

    return command.toOwnedSlice(allocator);
}

fn runOllama(allocator: Allocator, config: Config, argv_tail: []const []const u8) ![]u8 {
    var local_args: std.ArrayList([]const u8) = .empty;
    defer local_args.deinit(allocator);
    try local_args.append(allocator, "ollama");
    try local_args.appendSlice(allocator, argv_tail);

    return runChild(allocator, local_args.items) catch |err| switch (err) {
        error.FileNotFound => {
            const remote_command = try buildRemoteCommand(allocator, config.remote_ollama, argv_tail);
            defer allocator.free(remote_command);

            var remote_args: std.ArrayList([]const u8) = .empty;
            defer remote_args.deinit(allocator);
            try remote_args.appendSlice(allocator, &.{ "ssh", "-o", "IdentitiesOnly=yes", config.remote_host, remote_command });
            return runChild(allocator, remote_args.items);
        },
        else => return err,
    };
}

fn listModels(allocator: Allocator, config: Config, writer: *std.Io.Writer, colors: bool) !u8 {
    const output = try runOllama(allocator, config, &.{ "list" });
    defer allocator.free(output);

    try printlnColor(writer, colors, Nord.title, "Available models");
    try printlnColor(writer, colors, Nord.text, output);
    return 0;
}

fn askOnce(allocator: Allocator, config: Config, prompt: []const u8, model: []const u8, writer: *std.Io.Writer, colors: bool) !u8 {
    const output = try runOllama(allocator, config, &.{ "run", model, prompt });
    defer allocator.free(output);

    try paint(writer, colors, Nord.accent, "model: ");
    try paint(writer, colors, Nord.muted, model);
    try writer.writeByte('\n');
    try printlnColor(writer, colors, Nord.text, output);
    return 0;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "minillm\n\n" ++
        "Usage:\n" ++
        "  minillm\n" ++
        "  minillm ask \"your prompt\"\n" ++
        "  minillm models\n" ++
        "  minillm --model jj-code ask \"fix this shell command\"\n\n" ++
        "Env:\n" ++
        "  MINILLM_MODEL         default model (default: jj-general)\n" ++
        "  MINILLM_REMOTE_HOST   ssh host fallback (default: user@example-host)\n" ++
        "  MINILLM_REMOTE_OLLAMA remote ollama binary path\n",
    );
}

fn runChat(allocator: Allocator, config: Config, selected_model: []const u8) !u8 {
    const colors = useColor();
    var out = std.fs.File.stdout().writer(&.{});
    var err = std.fs.File.stderr().writer(&.{});

    try printlnColor(&out.interface, colors, Nord.title, "minillm");
    try paint(&out.interface, colors, Nord.muted, "model: ");
    try printlnColor(&out.interface, colors, Nord.accent, selected_model);
    try printlnColor(&out.interface, colors, Nord.muted, "Type :q to quit, :models to list models.");

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);

    while (true) {
        try paint(&out.interface, colors, Nord.prompt, "minillm> ");
        const maybe_line = try stdin_reader.interface.takeDelimiter('\n');
        if (maybe_line == null) {
            try out.interface.writeByte('\n');
            return 0;
        }
        const line = std.mem.trim(u8, maybe_line.?, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, ":q") or std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) return 0;
        if (std.mem.eql(u8, line, ":models")) {
            _ = try listModels(allocator, config, &out.interface, colors);
            try out.interface.writeByte('\n');
            continue;
        }

        try printlnColor(&out.interface, colors, Nord.muted, "thinking...");
        _ = askOnce(allocator, config, line, selected_model, &out.interface, colors) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)});
            defer allocator.free(msg);
            try printlnColor(&err.interface, colors, Nord.muted, msg);
            continue;
        };
        try out.interface.writeByte('\n');
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsed = parseArgs(allocator) catch |err| {
        var err_writer = std.fs.File.stderr().writer(&.{});
        try printHelp(&err_writer.interface);
        return err;
    };
    defer {
        if (parsed.prompt) |prompt| allocator.free(prompt);
        if (parsed.model) |model| allocator.free(model);
    }

    const config = try configFromEnv(allocator);
    defer freeConfig(allocator, config);

    const selected_model = parsed.model orelse config.default_model;
    const colors = useColor();

    switch (parsed.command) {
        .help => {
            var out = std.fs.File.stdout().writer(&.{});
            try printHelp(&out.interface);
        },
        .models => {
            var out = std.fs.File.stdout().writer(&.{});
            std.process.exit(try listModels(allocator, config, &out.interface, colors));
        },
        .ask => {
            var out = std.fs.File.stdout().writer(&.{});
            std.process.exit(try askOnce(allocator, config, parsed.prompt.?, selected_model, &out.interface, colors));
        },
        .chat => std.process.exit(try runChat(allocator, config, selected_model)),
    }
}

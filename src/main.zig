const std = @import("std");

const Allocator = std.mem.Allocator;
const Command = enum { chat, ask, models, modes, facts, refresh_facts, help };
const Mode = enum { normal, careful, verify, selfcheck };
const max_history_turns = 6;
const max_history_chars = 600;
const unloaded_lineage = "__MINILLM_UNLOADED_OLLAMA_LINEAGE__";
const unloaded_model_facts = "__MINILLM_UNLOADED_MODEL_FACTS__";

const Nord = struct {
    const title = "38;2;147;194;184";
    const accent = "38;2;136;192;208";
    const prompt = "38;2;235;203;139";
    const muted = "38;2;129;161;193";
    const text = "38;2;216;222;233";
    const reset = "0";
};

const startup_banner =
    " ███╗   ███╗ ██╗ ███╗   ██╗ ██╗ ██╗      ██╗      ███╗   ███╗\n" ++
    " ████╗ ████║ ██║ ████╗  ██║ ██║ ██║      ██║      ████╗ ████║\n" ++
    " ██╔████╔██║ ██║ ██╔██╗ ██║ ██║ ██║      ██║      ██╔████╔██║\n" ++
    " ██║╚██╔╝██║ ██║ ██║╚██╗██║ ██║ ██║      ██║      ██║╚██╔╝██║\n" ++
    " ██║ ╚═╝ ██║ ██║ ██║ ╚████║ ██║ ███████╗ ███████╗ ██║ ╚═╝ ██║\n" ++
    " ╚═╝     ╚═╝ ╚═╝ ╚═╝  ╚═══╝ ╚═╝ ╚══════╝ ╚══════╝ ╚═╝     ╚═╝\n";

const Config = struct {
    remote_host: []const u8,
    remote_ollama: []const u8,
    default_model: []const u8,
    model_facts_dir: ?[]const u8,
    facts_source_path: ?[]const u8,
};

const Parsed = struct {
    command: Command = .chat,
    prompt: ?[]const u8 = null,
    model: ?[]const u8 = null,
    mode: Mode = .normal,
};

const TurnRole = enum { user, assistant };

const ChatTurn = struct {
    role: TurnRole,
    text: []u8,
};

const PromptContext = struct {
    model: []const u8,
    remote_host: []const u8,
    ollama_lineage: []const u8,
    model_facts: []const u8,
    history: []const ChatTurn = &.{},
};

fn metadataIsUnloaded(value: []const u8, sentinel: []const u8) bool {
    return std.mem.eql(u8, value, sentinel);
}

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
        if (std.mem.eql(u8, arg, "modes")) {
            parsed.command = .modes;
            continue;
        }
        if (std.mem.eql(u8, arg, "facts")) {
            parsed.command = .facts;
            if (idx + 1 < args.len and args[idx + 1][0] != '-') {
                idx += 1;
                parsed.model = try allocator.dupe(u8, args[idx]);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "refresh-facts")) {
            parsed.command = .refresh_facts;
            if (idx + 1 < args.len and args[idx + 1][0] != '-') {
                idx += 1;
                parsed.model = try allocator.dupe(u8, args[idx]);
            }
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
        if (std.mem.eql(u8, arg, "--mode")) {
            idx += 1;
            if (idx >= args.len) return error.MissingMode;
            const mode = args[idx];
            if (std.mem.eql(u8, mode, "normal")) {
                parsed.mode = .normal;
            } else if (std.mem.eql(u8, mode, "careful")) {
                parsed.mode = .careful;
            } else if (std.mem.eql(u8, mode, "verify")) {
                parsed.mode = .verify;
            } else if (std.mem.eql(u8, mode, "selfcheck")) {
                parsed.mode = .selfcheck;
            } else {
                return error.InvalidMode;
            }
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
    const model_facts_dir = std.process.getEnvVarOwned(allocator, "MINILLM_MODEL_FACTS_DIR") catch null;
    const facts_source_path = std.process.getEnvVarOwned(allocator, "MINILLM_FACTS_SOURCE") catch null;

    return .{
        .remote_host = remote_host,
        .remote_ollama = remote_ollama,
        .default_model = default_model,
        .model_facts_dir = model_facts_dir,
        .facts_source_path = facts_source_path,
    };
}

fn freeConfig(allocator: Allocator, config: Config) void {
    allocator.free(config.remote_host);
    allocator.free(config.remote_ollama);
    allocator.free(config.default_model);
    if (config.model_facts_dir) |dir| allocator.free(dir);
    if (config.facts_source_path) |path| allocator.free(path);
}

fn builtinModelFacts(model: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, model, "jj-general")) {
        return
            "- `jj-general` is a custom Ollama workflow alias built from `llama3.2:3b`.\n" ++
            "- No trusted local fine-tuning corpus is currently recorded for `jj-general` itself.\n" ++
            "- Separate local training work exists for proof/predicate/math/formal corpora, but those runs were LoRA experiments on `Qwen/Qwen2.5-0.5B-Instruct`, not `jj-general`.\n" ++
            "- Recorded local corpora from that separate training work include:\n" ++
            "  - `train-proof-v1` exported from `notes-proof-v1.sqlite3`\n" ++
            "  - `FOLIO` v0.0 exported into `train-folio-v1`\n" ++
            "  - `NaturalProofs` ProofWiki exported into `train-naturalproofs-proofwiki-v1`\n" ++
            "  - `train-diffcalc-v1` from the DeepMind mathematics differentiation corpus line\n" ++
            "  - `train-naturalproofs-proofwiki-grounded-v1` for retrieval-grounded NaturalProofs experiments\n" ++
            "  - `train-set-theory-v1` from the original formal set-theory corpus line (`set.mm`, Isabelle/ZF, AFP entries)\n" ++
            "  - `train-set-theory-v2` from the extended set-theory corpus line (`set.mm`, Mizar MML, Isabelle/ZF, selected AFP entries)\n" ++
            "  - `train-isabelle-source-v1` from Isabelle/AFP source corpora\n" ++
            "- Related local non-training corpus lines include:\n" ++
            "  - `tptp-set-v1` as a fetched TPTP SET-domain corpus line\n" ++
            "  - `formal-eval-v1` as a held-out formal evaluation bundle (`miniF2F`, `PutnamBench`, `Portal-to-ISAbelle`)\n" ++
            "- Do not claim those corpora trained `jj-general` unless newer trusted local metadata says so.";
    }
    if (std.mem.eql(u8, model, "jj-code")) {
        return
            "- `jj-code` is a custom Ollama workflow alias built from `qwen2.5-coder:3b`.\n" ++
            "- No trusted local fine-tuning corpus is currently recorded here for `jj-code`.\n" ++
            "- Do not invent code-training corpora beyond this note.";
    }
    return null;
}

fn defaultFactsDir(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config_home| {
        defer allocator.free(xdg_config_home);
        return std.fs.path.join(allocator, &.{ xdg_config_home, "minillm", "model-facts" });
    } else |_| {}

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "minillm", "model-facts" });
}

fn configuredFactsDir(allocator: Allocator, config: Config) ![]u8 {
    if (config.model_facts_dir) |dir| return allocator.dupe(u8, dir);
    return defaultFactsDir(allocator);
}

fn defaultFactsSourcePath(allocator: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".codex", "memories", "jj.md" });
}

fn configuredFactsSourcePath(allocator: Allocator, config: Config) ![]u8 {
    if (config.facts_source_path) |path| return allocator.dupe(u8, path);
    return defaultFactsSourcePath(allocator);
}

fn loadModelFacts(allocator: Allocator, config: Config, model: []const u8) ![]u8 {
    const dir = try configuredFactsDir(allocator, config);
    defer allocator.free(dir);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{model});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ dir, file_name });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (file) |facts_file| {
        defer facts_file.close();
        return facts_file.readToEndAlloc(allocator, 64 * 1024);
    }

    if (builtinModelFacts(model)) |facts| return allocator.dupe(u8, facts);

    return allocator.dupe(u8, "No trusted local model facts are available for this model.");
}

fn extractModelfileBase(allocator: Allocator, modelfile: []const u8) !?[]u8 {
    var iter = std.mem.splitScalar(u8, modelfile, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "# FROM ")) {
            return try allocator.dupe(u8, std.mem.trim(u8, line[7..], " \t\r"));
        }
    }

    var fallback_iter = std.mem.splitScalar(u8, modelfile, '\n');
    while (fallback_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "FROM ")) {
            const candidate = std.mem.trim(u8, line[5..], " \t\r");
            if (candidate.len == 0) continue;
            return try allocator.dupe(u8, candidate);
        }
    }

    return null;
}

fn isSelfReferentialModelRef(model: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, candidate, model)) return true;

    if (candidate.len > model.len and std.mem.startsWith(u8, candidate, model) and candidate[model.len] == ':') {
        return true;
    }

    return false;
}

fn loadOllamaLineage(allocator: Allocator, config: Config, model: []const u8) ![]u8 {
    const modelfile = runOllama(allocator, config, &.{ "show", "--modelfile", model }) catch {
        return allocator.dupe(u8, "Ollama lineage unavailable.");
    };
    defer allocator.free(modelfile);

    if (try extractModelfileBase(allocator, modelfile)) |base| {
        defer allocator.free(base);
        if (isSelfReferentialModelRef(model, base)) {
            return allocator.dupe(u8, "Ollama lineage unavailable.");
        }
        return std.fmt.allocPrint(allocator, "Ollama reports `{s}` is built from `{s}`.", .{ model, base });
    }

    return allocator.dupe(u8, "Ollama lineage unavailable.");
}

fn isPlaceholderRemoteHost(remote_host: []const u8) bool {
    return std.mem.eql(u8, remote_host, "user@example-host");
}

const corpus_descriptions = std.StaticStringMap([]const u8).initComptime(.{
    .{ "train-proof-v1", "exported from `notes-proof-v1.sqlite3`" },
    .{ "train-folio-v1", "exported from `FOLIO` v0.0" },
    .{ "train-naturalproofs-proofwiki-v1", "exported from `NaturalProofs` ProofWiki" },
    .{ "train-diffcalc-v1", "from the DeepMind mathematics differentiation corpus line" },
    .{ "train-naturalproofs-proofwiki-grounded-v1", "for retrieval-grounded NaturalProofs experiments" },
    .{ "train-set-theory-v1", "from the original formal set-theory corpus line (`set.mm`, Isabelle/ZF, AFP entries)" },
    .{ "train-set-theory-v2", "from the extended set-theory corpus line (`set.mm`, Mizar MML, Isabelle/ZF, selected AFP entries)" },
    .{ "train-isabelle-source-v1", "from Isabelle/AFP source corpora" },
});

fn corpusDescription(dataset_id: []const u8) []const u8 {
    return corpus_descriptions.get(dataset_id) orelse "recorded in local training history";
}

fn appendUniqueString(allocator: Allocator, items: *std.ArrayList([]u8), candidate: []const u8) !void {
    for (items.items) |existing| {
        if (std.mem.eql(u8, existing, candidate)) return;
    }
    try items.append(allocator, try allocator.dupe(u8, candidate));
}

fn collectTrainDatasetsFromText(allocator: Allocator, text: []const u8) !std.ArrayList([]u8) {
    var items: std.ArrayList([]u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.mem.startsWith(u8, text[i..], "train-")) continue;
        var j = i + "train-".len;
        while (j < text.len) : (j += 1) {
            const ch = text[j];
            const allowed = std.ascii.isAlphanumeric(ch) or ch == '-';
            if (!allowed) break;
        }
        if (j == i + "train-".len) continue;
        try appendUniqueString(allocator, &items, text[i..j]);
        i = j;
    }

    return items;
}

fn loadRecordedTrainingDatasets(allocator: Allocator, config: Config) !std.ArrayList([]u8) {
    const source_path = configuredFactsSourcePath(allocator, config) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return .empty,
        else => return err,
    };
    defer allocator.free(source_path);

    const file = std.fs.openFileAbsolute(source_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 512 * 1024);
    defer allocator.free(contents);
    return collectTrainDatasetsFromText(allocator, contents);
}

fn buildGeneratedModelFacts(allocator: Allocator, config: Config, model: []const u8) ![]u8 {
    if (std.mem.eql(u8, model, "jj-general")) {
        var corpora = try loadRecordedTrainingDatasets(allocator, config);
        defer {
            for (corpora.items) |item| allocator.free(item);
            corpora.deinit(allocator);
        }

        if (corpora.items.len == 0) {
            if (builtinModelFacts(model)) |facts| return allocator.dupe(u8, facts);
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        var writer = output.writer(allocator);

        try writer.writeAll("- `jj-general` is a custom Ollama workflow alias built from `llama3.2:3b`.\n");
        try writer.writeAll("- No trusted local fine-tuning corpus is currently recorded for `jj-general` itself.\n");
        try writer.writeAll("- Separate local training work exists for proof/predicate/math/formal corpora, but those runs were LoRA experiments on `Qwen/Qwen2.5-0.5B-Instruct`, not `jj-general`.\n");
        if (corpora.items.len == 0) {
            try writer.writeAll("- No recorded local training corpora were found in the configured facts source.\n");
        } else {
            try writer.writeAll("- Recorded local corpora from that separate training work include:\n");
            for (corpora.items) |dataset_id| {
                try writer.print("  - `{s}` {s}\n", .{ dataset_id, corpusDescription(dataset_id) });
            }
        }
        try writer.writeAll("- Related local non-training corpus lines include:\n");
        try writer.writeAll("  - `tptp-set-v1` as a fetched TPTP SET-domain corpus line\n");
        try writer.writeAll("  - `formal-eval-v1` as a held-out formal evaluation bundle (`miniF2F`, `PutnamBench`, `Portal-to-ISAbelle`)\n");
        try writer.writeAll("- Do not claim those corpora trained `jj-general` unless newer trusted local metadata says so.");
        return output.toOwnedSlice(allocator);
    }

    if (builtinModelFacts(model)) |facts| return allocator.dupe(u8, facts);
    return allocator.dupe(u8, "No trusted local model facts are available for this model.");
}

fn asciiLowerDup(allocator: Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

fn isModelProvenanceQuestion(allocator: Allocator, prompt: []const u8) !bool {
    const lower = try asciiLowerDup(allocator, prompt);
    defer allocator.free(lower);

    if (std.mem.indexOf(u8, lower, "trained on") != null) return true;
    if (std.mem.indexOf(u8, lower, "training data") != null) return true;
    if (std.mem.indexOf(u8, lower, "training corpus") != null) return true;
    if (std.mem.indexOf(u8, lower, "training corpora") != null) return true;
    if (std.mem.indexOf(u8, lower, "corpus") != null) return true;
    if (std.mem.indexOf(u8, lower, "corpora") != null) return true;
    if (std.mem.indexOf(u8, lower, "fine-tun") != null) return true;
    if (std.mem.indexOf(u8, lower, "finetun") != null) return true;
    return false;
}

fn formatModelProvenanceAnswer(allocator: Allocator, context: PromptContext, mode: Mode) ![]u8 {
    const summary = if (std.mem.startsWith(u8, context.model_facts, "No trusted local model facts"))
        if (std.mem.eql(u8, context.ollama_lineage, "Ollama lineage unavailable."))
            try allocator.dupe(u8, "I don't know because there are no trusted local model facts recorded for this model.")
        else
            try std.fmt.allocPrint(allocator, "{s} No trusted local fine-tuning or corpus facts are recorded for this model.", .{context.ollama_lineage})
    else if (std.mem.eql(u8, context.ollama_lineage, "Ollama lineage unavailable."))
        try allocator.dupe(u8, context.model_facts)
    else
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ context.ollama_lineage, context.model_facts });
    defer allocator.free(summary);

    return switch (mode) {
        .normal => allocator.dupe(u8, summary),
        .careful, .verify, .selfcheck => std.fmt.allocPrint(
            allocator,
            "Answer: {s}\nEvidence basis: Trusted local model facts\nConfidence: high",
            .{summary},
        ),
    };
}

fn answerFromTrustedModelMetadata(allocator: Allocator, context: PromptContext, mode: Mode) ![]u8 {
    return formatModelProvenanceAnswer(allocator, context, mode);
}

fn resolvePromptContextMetadata(allocator: Allocator, config: Config, context: PromptContext) !PromptContext {
    var resolved = context;
    if (metadataIsUnloaded(resolved.ollama_lineage, unloaded_lineage)) {
        resolved.ollama_lineage = try loadOllamaLineage(allocator, config, context.model);
    }
    if (metadataIsUnloaded(resolved.model_facts, unloaded_model_facts)) {
        resolved.model_facts = try loadModelFacts(allocator, config, context.model);
    }
    return resolved;
}

fn freeResolvedPromptContextMetadata(allocator: Allocator, original: PromptContext, resolved: PromptContext) void {
    if (!std.mem.eql(u8, resolved.ollama_lineage, original.ollama_lineage)) {
        allocator.free(resolved.ollama_lineage);
    }
    if (!std.mem.eql(u8, resolved.model_facts, original.model_facts)) {
        allocator.free(resolved.model_facts);
    }
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
            if (isPlaceholderRemoteHost(config.remote_host)) return error.RemoteHostNotConfigured;
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

fn carefulSystemPrompt() []const u8 {
    return
        "You are a cautious assistant. Do not guess. " ++
        "If the question depends on local system state, training history, installed models, or files, and no trusted context is provided, answer exactly: I don't know. " ++
        "Do not invent frameworks, datasets, or machine details. " ++
        "Respond using this format:\n" ++
        "Answer: <answer or I don't know>\n" ++
        "Evidence basis: <brief basis or 'No trusted local evidence'>\n" ++
        "Confidence: high|medium|low";
}

fn draftSystemPrompt() []const u8 {
    return
        "Draft a short answer. Avoid unsupported claims. " ++
        "If the question appears to depend on local system state or inaccessible facts, say I don't know.";
}

fn verificationPlannerSystemPrompt() []const u8 {
    return
        "You plan factual verification questions. " ++
        "Return exactly 3 short verification questions, one per line, with no numbering, JSON, or commentary. " ++
        "Each question should directly test a specific factual claim from the draft.";
}

fn verificationAnswerSystemPrompt() []const u8 {
    return
        "Answer the verification question independently and conservatively. " ++
        "Do not reuse unsupported claims from any earlier draft. " ++
        "If the answer is unknown, say Unknown.";
}

fn verificationFinalSystemPrompt() []const u8 {
    return
        "You are revising an answer after verification. " ++
        "Use only supported claims from the verification answers. " ++
        "If too much remains uncertain, answer exactly: I don't know. " ++
        "Respond using this format:\n" ++
        "Answer: <answer or I don't know>\n" ++
        "Evidence basis: <which verification answers support it>\n" ++
        "Confidence: high|medium|low";
}

fn selfcheckJudgeSystemPrompt() []const u8 {
    return
        "You are comparing multiple independently sampled answers for factual consistency. " ++
        "Use only facts shared across at least two answers. " ++
        "If the answers materially disagree or appear speculative, answer I don't know. " ++
        "Respond using this format:\n" ++
        "Answer: <answer or I don't know>\n" ++
        "Evidence basis: <facts shared across samples or 'No stable shared facts'>\n" ++
        "Confidence: high|medium|low";
}

fn runPrompt(allocator: Allocator, config: Config, model: []const u8, prompt: []const u8) ![]u8 {
    return runOllama(allocator, config, &.{ "run", model, prompt });
}

fn writePromptContextSection(writer: *std.ArrayList(u8).Writer, context: PromptContext) !void {
    try writer.writeAll("Local minillm context:\n");
    try writer.print("- Active selected model: {s}\n", .{context.model});
    try writer.print("- Remote fallback host: {s}\n", .{context.remote_host});
    try writer.writeAll("- minillm uses local Ollama when available and otherwise falls back to the remote host above.\n");
    try writer.writeAll("- Unless the user explicitly names another model, phrases like \"this model\", \"the llm\", or follow-up clarifications refer to the active selected model above.\n");
    try writer.writeAll("- If the user explicitly mentions \"the Mac mini\", treat that as referring to the configured remote fallback host.\n");
    if (metadataIsUnloaded(context.ollama_lineage, unloaded_lineage) or metadataIsUnloaded(context.model_facts, unloaded_model_facts)) {
        try writer.writeAll("- Trusted model metadata is loaded on demand for provenance or training-corpus questions.\n");
    } else {
        try writer.print("- Ollama lineage: {s}\n", .{context.ollama_lineage});
        try writer.writeAll("- The trusted local model facts below are the only authoritative source for model provenance or training-corpus claims in this session.\n");
        try writer.print("Trusted local model facts:\n{s}\n", .{context.model_facts});
    }
}

fn formatConversationHistory(allocator: Allocator, history: []const ChatTurn) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    if (history.len == 0) {
        try buffer.appendSlice(allocator, "No earlier conversation.\n");
        return buffer.toOwnedSlice(allocator);
    }

    const start = if (history.len > max_history_turns) history.len - max_history_turns else 0;
    var writer = buffer.writer(allocator);
    for (history[start..]) |turn| {
        const role = switch (turn.role) {
            .user => "User",
            .assistant => "Assistant",
        };
        try writer.print("{s}: {s}\n", .{ role, turn.text });
    }
    return buffer.toOwnedSlice(allocator);
}

fn buildPrompt(allocator: Allocator, system_prompt: []const u8, prompt: []const u8, context: PromptContext) ![]u8 {
    const history_block = try formatConversationHistory(allocator, context.history);
    defer allocator.free(history_block);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);
    try writer.print("{s}\n\n", .{system_prompt});
    try writePromptContextSection(&writer, context);
    try writer.print("\nRecent conversation:\n{s}\nCurrent user message:\n{s}", .{ history_block, prompt });
    return buffer.toOwnedSlice(allocator);
}

fn askNormal(allocator: Allocator, config: Config, prompt: []const u8, model: []const u8, context: PromptContext) ![]u8 {
    const full_prompt = try buildPrompt(allocator, "Answer the user's latest message directly and concisely.", prompt, context);
    defer allocator.free(full_prompt);
    return runPrompt(allocator, config, model, full_prompt);
}

fn askCareful(allocator: Allocator, config: Config, prompt: []const u8, model: []const u8, context: PromptContext) ![]u8 {
    const full_prompt = try buildPrompt(allocator, carefulSystemPrompt(), prompt, context);
    defer allocator.free(full_prompt);
    return runPrompt(allocator, config, model, full_prompt);
}

fn askVerify(allocator: Allocator, config: Config, prompt: []const u8, model: []const u8, context: PromptContext) ![]u8 {
    const draft_prompt = try buildPrompt(allocator, draftSystemPrompt(), prompt, context);
    defer allocator.free(draft_prompt);

    const draft = try runPrompt(allocator, config, model, draft_prompt);
    defer allocator.free(draft);

    const history_block = try formatConversationHistory(allocator, context.history);
    defer allocator.free(history_block);

    const planner_prompt = try std.fmt.allocPrint(
        allocator,
        "{s}\n\nLocal minillm context:\n- Active selected model: {s}\n- Remote fallback host: {s}\n- Unless the user explicitly names another model, phrases like \"this model\", \"the llm\", or follow-up clarifications refer to the active selected model above.\n- If the user explicitly mentions \"the Mac mini\", treat that as referring to the configured remote fallback host.\n\nRecent conversation:\n{s}\nCurrent user message:\n{s}\n\nDraft answer:\n{s}",
        .{ verificationPlannerSystemPrompt(), context.model, context.remote_host, history_block, prompt, draft },
    );
    defer allocator.free(planner_prompt);

    const planner_output = try runPrompt(allocator, config, model, planner_prompt);
    defer allocator.free(planner_output);

    var verification_report: std.ArrayList(u8) = .empty;
    defer verification_report.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, planner_output, '\n');
    var idx: usize = 0;
    while (line_iter.next()) |raw_line| {
        const question = std.mem.trim(u8, raw_line, " \t\r\n-*0123456789.");
        if (question.len == 0) continue;
        if (idx >= 3) break;

        const answer_prompt = try std.fmt.allocPrint(
            allocator,
            "{s}\n\nLocal minillm context:\n- Active selected model: {s}\n- Remote fallback host: {s}\n- Unless the user explicitly names another model, phrases like \"this model\", \"the llm\", or follow-up clarifications refer to the active selected model above.\n- If the user explicitly mentions \"the Mac mini\", treat that as referring to the configured remote fallback host.\n\nRecent conversation:\n{s}\nCurrent user message:\n{s}\n\nVerification question:\n{s}",
            .{ verificationAnswerSystemPrompt(), context.model, context.remote_host, history_block, prompt, question },
        );
        defer allocator.free(answer_prompt);

        const answer = try runPrompt(allocator, config, model, answer_prompt);
        defer allocator.free(answer);

        try verification_report.writer(allocator).print("Q{d}: {s}\nA{d}: {s}\n\n", .{ idx + 1, question, idx + 1, answer });
        idx += 1;
    }

    const final_prompt = try std.fmt.allocPrint(
        allocator,
        "{s}\n\nLocal minillm context:\n- Active selected model: {s}\n- Remote fallback host: {s}\n- Unless the user explicitly names another model, phrases like \"this model\", \"the llm\", or follow-up clarifications refer to the active selected model above.\n- If the user explicitly mentions \"the Mac mini\", treat that as referring to the configured remote fallback host.\n\nRecent conversation:\n{s}\nCurrent user message:\n{s}\n\nInitial draft:\n{s}\n\nVerification results:\n{s}",
        .{ verificationFinalSystemPrompt(), context.model, context.remote_host, history_block, prompt, draft, verification_report.items },
    );
    defer allocator.free(final_prompt);

    return runPrompt(allocator, config, model, final_prompt);
}

fn askSelfCheck(allocator: Allocator, config: Config, prompt: []const u8, model: []const u8, context: PromptContext) ![]u8 {
    var candidates: [3][]u8 = undefined;
    defer {
        for (candidates) |candidate| allocator.free(candidate);
    }
    const history_block = try formatConversationHistory(allocator, context.history);
    defer allocator.free(history_block);

    const sampling_labels = [_][]const u8{
        "Independent answer attempt A.",
        "Independent answer attempt B.",
        "Independent answer attempt C.",
    };

    for (sampling_labels, 0..) |label, idx| {
        const sample_context_prompt = try std.fmt.allocPrint(
            allocator,
            "{s}\n\n{s}",
            .{ carefulSystemPrompt(), label },
        );
        defer allocator.free(sample_context_prompt);
        const sample_prompt = try buildPrompt(allocator, sample_context_prompt, prompt, context);
        defer allocator.free(sample_prompt);
        candidates[idx] = try runPrompt(allocator, config, model, sample_prompt);
    }

    const judge_prompt = try std.fmt.allocPrint(
        allocator,
        "{s}\n\nLocal minillm context:\n- Active selected model: {s}\n- Remote fallback host: {s}\n- Unless the user explicitly names another model, phrases like \"this model\", \"the llm\", or follow-up clarifications refer to the active selected model above.\n- If the user explicitly mentions \"the Mac mini\", treat that as referring to the configured remote fallback host.\n\nRecent conversation:\n{s}\nCurrent user message:\n{s}\n\nCandidate answer 1:\n{s}\n\nCandidate answer 2:\n{s}\n\nCandidate answer 3:\n{s}",
        .{ selfcheckJudgeSystemPrompt(), context.model, context.remote_host, history_block, prompt, candidates[0], candidates[1], candidates[2] },
    );
    defer allocator.free(judge_prompt);

    return runPrompt(allocator, config, model, judge_prompt);
}

fn listModels(allocator: Allocator, config: Config, writer: *std.Io.Writer, colors: bool) !u8 {
    const output = try runOllama(allocator, config, &.{ "list" });
    defer allocator.free(output);

    try printlnColor(writer, colors, Nord.title, "Available models");
    try printlnColor(writer, colors, Nord.text, output);
    return 0;
}

fn listModes(writer: *std.Io.Writer, colors: bool) !u8 {
    try printlnColor(writer, colors, Nord.title, "Available modes");
    try printlnColor(writer, colors, Nord.accent, "normal");
    try printlnColor(writer, colors, Nord.text, "  Plain answer generation.");
    try printlnColor(writer, colors, Nord.accent, "careful");
    try printlnColor(writer, colors, Nord.text, "  Abstention-first prompting for lower-confidence answers.");
    try printlnColor(writer, colors, Nord.accent, "verify");
    try printlnColor(writer, colors, Nord.text, "  Draft, verify claims independently, then revise.");
    try printlnColor(writer, colors, Nord.accent, "selfcheck");
    try printlnColor(writer, colors, Nord.text, "  Compare multiple answers and keep only stable shared facts.");
    return 0;
}

fn showFacts(allocator: Allocator, config: Config, model: []const u8, writer: *std.Io.Writer, colors: bool) !u8 {
    const ollama_lineage = try loadOllamaLineage(allocator, config, model);
    defer allocator.free(ollama_lineage);
    const model_facts = try loadModelFacts(allocator, config, model);
    defer allocator.free(model_facts);

    try printlnColor(writer, colors, Nord.title, "Model Facts");
    try paint(writer, colors, Nord.accent, "model: ");
    try printlnColor(writer, colors, Nord.muted, model);
    try paint(writer, colors, Nord.accent, "ollama lineage: ");
    try printlnColor(writer, colors, Nord.text, ollama_lineage);
    try printlnColor(writer, colors, Nord.accent, "trusted local facts:");
    try printlnColor(writer, colors, Nord.text, model_facts);
    return 0;
}

fn writeModelFactsFile(allocator: Allocator, facts_dir: []const u8, model: []const u8, contents: []const u8) ![]u8 {
    var root_dir = try std.fs.openDirAbsolute("/", .{});
    defer root_dir.close();
    try root_dir.makePath(std.mem.trimLeft(u8, facts_dir, "/"));

    const file_name = try std.fmt.allocPrint(allocator, "{s}.md", .{model});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ facts_dir, file_name });

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
    return path;
}

fn refreshFacts(allocator: Allocator, config: Config, selected_model: ?[]const u8, writer: *std.Io.Writer, colors: bool) !u8 {
    const facts_dir = try configuredFactsDir(allocator, config);
    defer allocator.free(facts_dir);

    const default_models = [_][]const u8{ "jj-general", "jj-code" };

    try printlnColor(writer, colors, Nord.title, "Refreshing model facts");
    try paint(writer, colors, Nord.accent, "facts dir: ");
    try printlnColor(writer, colors, Nord.text, facts_dir);

    if (selected_model) |model| {
        const generated = try buildGeneratedModelFacts(allocator, config, model);
        defer allocator.free(generated);
        const path = try writeModelFactsFile(allocator, facts_dir, model, generated);
        defer allocator.free(path);

        try paint(writer, colors, Nord.accent, "updated: ");
        try paint(writer, colors, Nord.muted, model);
        try writer.writeAll(" -> ");
        try printlnColor(writer, colors, Nord.text, path);
        return 0;
    }

    for (default_models) |model| {
        const generated = try buildGeneratedModelFacts(allocator, config, model);
        defer allocator.free(generated);
        const path = try writeModelFactsFile(allocator, facts_dir, model, generated);
        defer allocator.free(path);

        try paint(writer, colors, Nord.accent, "updated: ");
        try paint(writer, colors, Nord.muted, model);
        try writer.writeAll(" -> ");
        try printlnColor(writer, colors, Nord.text, path);
    }

    return 0;
}

fn generateAnswer(allocator: Allocator, config: Config, prompt: []const u8, model: []const u8, mode: Mode, context: PromptContext) ![]u8 {
    if (try isModelProvenanceQuestion(allocator, prompt)) {
        const resolved = try resolvePromptContextMetadata(allocator, config, context);
        defer freeResolvedPromptContextMetadata(allocator, context, resolved);
        return answerFromTrustedModelMetadata(allocator, resolved, mode);
    }

    return switch (mode) {
        .normal => try askNormal(allocator, config, prompt, model, context),
        .careful => try askCareful(allocator, config, prompt, model, context),
        .verify => try askVerify(allocator, config, prompt, model, context),
        .selfcheck => try askSelfCheck(allocator, config, prompt, model, context),
    };
}

fn duplicateHistoryText(allocator: Allocator, text: []const u8) ![]u8 {
    if (text.len <= max_history_chars) return allocator.dupe(u8, text);

    const suffix = "\n[truncated]";
    const prefix_len = max_history_chars - suffix.len;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ text[0..prefix_len], suffix });
}

fn appendTurn(allocator: Allocator, history: *std.ArrayList(ChatTurn), role: TurnRole, text: []const u8) !void {
    try history.append(allocator, .{
        .role = role,
        .text = try duplicateHistoryText(allocator, text),
    });
    if (history.items.len > max_history_turns) {
        const old = history.orderedRemove(0);
        allocator.free(old.text);
    }
}

fn askOnce(
    allocator: Allocator,
    config: Config,
    prompt: []const u8,
    model: []const u8,
    mode: Mode,
    context: PromptContext,
    writer: *std.Io.Writer,
    colors: bool,
) !u8 {
    const output = try generateAnswer(allocator, config, prompt, model, mode, context);
    defer allocator.free(output);

    try paint(writer, colors, Nord.accent, "model: ");
    try paint(writer, colors, Nord.muted, model);
    try writer.writeByte('\n');
    try paint(writer, colors, Nord.accent, "mode: ");
    try printlnColor(writer, colors, Nord.muted, @tagName(mode));
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
        "  minillm modes\n" ++
        "  minillm facts [model]\n" ++
        "  minillm refresh-facts [model]\n" ++
        "  minillm --mode careful ask \"your prompt\"\n" ++
        "  minillm --mode verify ask \"your prompt\"\n" ++
        "  minillm --mode selfcheck ask \"your prompt\"\n" ++
        "  minillm --model jj-code ask \"fix this shell command\"\n\n" ++
        "Chat commands:\n" ++
        "  :q                 quit\n" ++
        "  :models            list available models\n" ++
        "  :modes             list available modes\n" ++
        "  :mode <name>       switch chat mode\n" ++
        "  :model             show current chat model\n" ++
        "  :model <name>      switch current chat model\n\n" ++
        "Env:\n" ++
        "  MINILLM_MODEL         default model (default: jj-general)\n" ++
        "  MINILLM_REMOTE_HOST   ssh host fallback (default: user@example-host)\n" ++
        "  MINILLM_REMOTE_OLLAMA remote ollama binary path\n" ++
        "  MINILLM_MODEL_FACTS_DIR facts directory (default: $XDG_CONFIG_HOME/minillm/model-facts or ~/.config/minillm/model-facts)\n" ++
        "  MINILLM_FACTS_SOURCE  training-history source file (default: ~/.codex/memories/jj.md)\n\n" ++
        "Modes:\n" ++
        "  normal     Plain answer generation\n" ++
        "  careful    Abstention-first prompting\n" ++
        "  verify     Draft, verify, then revise\n" ++
        "  selfcheck  Compare multiple answers for agreement\n",
    );
}

fn runChat(allocator: Allocator, config: Config, selected_model: []const u8, initial_mode: Mode) !u8 {
    const colors = useColor();
    var out = std.fs.File.stdout().writer(&.{});
    var err = std.fs.File.stderr().writer(&.{});
    var mode = initial_mode;
    var current_model = try allocator.dupe(u8, selected_model);
    defer allocator.free(current_model);
    var history: std.ArrayList(ChatTurn) = .empty;
    defer {
        for (history.items) |turn| allocator.free(turn.text);
        history.deinit(allocator);
    }

    try printlnColor(&out.interface, colors, Nord.title, startup_banner);
    try paint(&out.interface, colors, Nord.muted, "model: ");
    try printlnColor(&out.interface, colors, Nord.accent, current_model);
    try paint(&out.interface, colors, Nord.muted, "mode: ");
    try printlnColor(&out.interface, colors, Nord.accent, @tagName(mode));
    try printlnColor(&out.interface, colors, Nord.muted, "Type :q to quit, :models/models to list models, :modes/modes to list modes, :mode/mode normal|careful|verify|selfcheck, :model/model [name] to show or switch model, or just normal/careful/verify/selfcheck.");

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
        if (std.mem.eql(u8, line, ":models") or std.mem.eql(u8, line, "models")) {
            _ = try listModels(allocator, config, &out.interface, colors);
            try out.interface.writeByte('\n');
            continue;
        }
        if (std.mem.eql(u8, line, ":modes") or std.mem.eql(u8, line, "modes")) {
            _ = try listModes(&out.interface, colors);
            try out.interface.writeByte('\n');
            continue;
        }
        if (std.mem.eql(u8, line, ":model") or std.mem.eql(u8, line, "model")) {
            try paint(&out.interface, colors, Nord.muted, "model: ");
            try printlnColor(&out.interface, colors, Nord.accent, current_model);
            continue;
        }
        if (std.mem.startsWith(u8, line, ":model ") or std.mem.startsWith(u8, line, "model ")) {
            const next_model = if (std.mem.startsWith(u8, line, ":model "))
                std.mem.trim(u8, line[7..], " \t")
            else
                std.mem.trim(u8, line[6..], " \t");
            if (next_model.len == 0) {
                try printlnColor(&err.interface, colors, Nord.muted, "missing model name");
                continue;
            }
            allocator.free(current_model);
            current_model = try allocator.dupe(u8, next_model);
            try paint(&out.interface, colors, Nord.muted, "model: ");
            try printlnColor(&out.interface, colors, Nord.accent, current_model);
            continue;
        }
        if (std.mem.startsWith(u8, line, ":mode ") or std.mem.startsWith(u8, line, "mode ") or std.mem.eql(u8, line, "normal") or std.mem.eql(u8, line, "careful") or std.mem.eql(u8, line, "verify") or std.mem.eql(u8, line, "selfcheck")) {
            const mode_name = if (std.mem.startsWith(u8, line, ":mode "))
                std.mem.trim(u8, line[6..], " \t")
            else if (std.mem.startsWith(u8, line, "mode "))
                std.mem.trim(u8, line[5..], " \t")
            else
                line;
            if (std.mem.eql(u8, mode_name, "normal")) {
                mode = .normal;
            } else if (std.mem.eql(u8, mode_name, "careful")) {
                mode = .careful;
            } else if (std.mem.eql(u8, mode_name, "verify")) {
                mode = .verify;
            } else if (std.mem.eql(u8, mode_name, "selfcheck")) {
                mode = .selfcheck;
            } else {
                try printlnColor(&err.interface, colors, Nord.muted, "unknown mode");
                continue;
            }
            try paint(&out.interface, colors, Nord.muted, "mode: ");
            try printlnColor(&out.interface, colors, Nord.accent, @tagName(mode));
            continue;
        }

        const status_line = if (try isModelProvenanceQuestion(allocator, line))
            "checking model metadata..."
        else
            "thinking...";
        try printlnColor(&out.interface, colors, Nord.muted, status_line);
        const context: PromptContext = .{
            .model = current_model,
            .remote_host = config.remote_host,
            .ollama_lineage = unloaded_lineage,
            .model_facts = unloaded_model_facts,
            .history = history.items,
        };
        const output = generateAnswer(allocator, config, line, current_model, mode, context) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "request failed: {s}", .{@errorName(e)});
            defer allocator.free(msg);
            try printlnColor(&err.interface, colors, Nord.muted, msg);
            continue;
        };
        defer allocator.free(output);

        try paint(&out.interface, colors, Nord.accent, "model: ");
        try paint(&out.interface, colors, Nord.muted, current_model);
        try out.interface.writeByte('\n');
        try paint(&out.interface, colors, Nord.accent, "mode: ");
        try printlnColor(&out.interface, colors, Nord.muted, @tagName(mode));
        try printlnColor(&out.interface, colors, Nord.text, output);

        try appendTurn(allocator, &history, .user, line);
        try appendTurn(allocator, &history, .assistant, output);
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
        .modes => {
            var out = std.fs.File.stdout().writer(&.{});
            std.process.exit(try listModes(&out.interface, colors));
        },
        .facts => {
            var out = std.fs.File.stdout().writer(&.{});
            std.process.exit(try showFacts(allocator, config, selected_model, &out.interface, colors));
        },
        .refresh_facts => {
            var out = std.fs.File.stdout().writer(&.{});
            std.process.exit(try refreshFacts(allocator, config, parsed.model, &out.interface, colors));
        },
        .ask => {
            var out = std.fs.File.stdout().writer(&.{});
            std.process.exit(try askOnce(allocator, config, parsed.prompt.?, selected_model, parsed.mode, .{
                .model = selected_model,
                .remote_host = config.remote_host,
                .ollama_lineage = unloaded_lineage,
                .model_facts = unloaded_model_facts,
            }, &out.interface, colors));
        },
        .chat => std.process.exit(try runChat(allocator, config, selected_model, parsed.mode)),
    }
}

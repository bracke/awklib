# Changelog

All notable changes to awklib are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to adhere
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **UTF-8 support.** String functions are code-point aware — `length`, `substr`,
  `index`, `split ""`, empty-`FS` field splitting, `match`'s `RSTART`/`RLENGTH`, and
  `printf %c` all count or emit whole code points rather than bytes (via a lenient
  `Awklib.Utf8` helper; a malformed byte counts as one character, as gawk tolerates).
  Regular expressions also match by code point — `.`, quantifiers, and classes
  (including positive ranges like `[α-ω]` and negated classes like `[^,]`) span whole
  code points — because awk patterns compile in the `regexp` engine's UTF-8 mode.
  Boundaries: matching stays byte-lenient (arbitrary input bytes are tolerated, not
  rejected), so `\b`/`\w` word-membership and case-insensitive folding remain
  ASCII-only; `printf` field width for `%c` counts bytes.

- Fleet-standard scaffolding: an AUnit test suite, tri-platform CI (Linux, macOS,
  Windows), README/CLAUDE/AGENTS on-ramp docs, and a `project_tools`-based release
  checklist (`check_awklib`).
- `Output_Files` out parameter on `Awklib.Interpreter.Run`: redirected output
  (`print > name`, `print >> name`, `printf > name`) is captured in memory and returned
  as (name, content) entries in first-write order, so the library never touches the
  filesystem — symmetric with the in-memory `Files`/`Input_Files` input.
- Math builtins `sqrt`, `sin`, `cos`, `exp`, `log`, `atan2`, `rand`, and `srand`,
  which were previously stubs returning 0.
- `**` and `**=` as aliases for the `^` and `^=` exponentiation operators, the way
  one-true-awk and gawk accept them.
- `ARGC`/`ARGV`, seeded from a new optional `Arguments` parameter on
  `Awklib.Interpreter.Run` (`ARGV[0]` is `"awk"`, `ARGV[1..n]` the supplied strings,
  `ARGC` = n + 1); when `Arguments` is omitted they are derived from the `Input_Files`
  names, matching awk. They are readable but do not drive input.
- `Awklib.Interpreter.Run_Streaming`, a live-host API with a main-record reader
  callback and stdout/redirection writer callbacks. It avoids preloading main input,
  standard output, or redirected output and exposes effective append/truncate
  redirection semantics to the host.
- `Awklib.Interpreter.Run_Text_Streaming`, a live-host API that accepts raw text chunks
  and keeps AWK record splitting inside `awklib`, including records that span chunk
  boundaries.

### Changed

- The interpreter is now **reentrant**: interpreter and parser state is local to each
  `Run`/`Parse` call, and the shared compiled-regex cache is guarded by a protected
  object, so independent programs may run concurrently on separate tasks.
- `print | "cmd"` output pipes now degrade quietly (the piped output is dropped) instead
  of failing the run, consistent with `system()` (returns -1) and `"cmd" | getline`
  (returns 0/EOF): this hermetic library does not spawn processes.

### Fixed

- Division and modulo by zero no longer crash the host: they are reported as a graceful
  `Run_Error` ("division by zero"), and a top-level handler on `Run` converts any other
  unexpected exception into a `Run_Error` so an embedded interpreter can never abort its
  caller. A non-finite result (overflow) now formats as `inf`/`-inf`/`nan` like C and awk
  instead of overflowing the number formatter.
- `getline` and `getline var` from the main input stream now advance the record cursor
  instead of being a no-op.
- Main-input `getline` from `BEGIN` works when using `Run_Streaming` or
  `Run_Text_Streaming`, because records are pulled lazily from the caller-supplied
  reader.
- Custom `RS`, including single-character and paragraph mode, is honoured when splitting
  records.
- Number formatting now matches C/awk: default output is `%.6g` (six significant
  figures), `OFMT` and `CONVFMT` are honoured, and `printf` renders `%e`/`%E`/`%g`/`%G`
  and `%.0f` the way C printf does.
- Output redirection no longer doubles newlines.
- The `awk_run` example CLI reads piped standard input, not only redirected input.

[Unreleased]: https://github.com/bracke/awklib

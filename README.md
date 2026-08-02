# awklib

**An AWK interpreter library in Ada, backed by the [regexp](../regexp) engine.**

awklib implements a POSIX-style AWK language as an embeddable Ada library. It parses
and runs real, unmodified AWK programs over in-memory input and captures their standard
output — its first consumer runs the IANA tzdb project's own `ziguard`/`zishrink`
scripts, so behaviour aims to match one-true-awk / gawk for the language subset those
programs use.

## Using it

The entry point is `Awklib.Interpreter.Run` — give it a program and an input string, get
back the captured output:

```ada
with Awklib.Interpreter;

declare
   package I renames Awklib.Interpreter;
   Empty     : I.Assignment_Vectors.Vector;
   Written   : I.Assignment_Vectors.Vector;
   Output    : Ada.Strings.Unbounded.Unbounded_String;
   Message   : Ada.Strings.Unbounded.Unbounded_String;
   Exit_Code : Integer;
   Status    : I.Run_Status;
begin
   I.Run
     (Program_Source => "{ s += $1 } END { print s }",
      Input          => "1" & ASCII.LF & "2" & ASCII.LF & "3" & ASCII.LF,
      Assignments    => Empty,      --  seed variables like -v
      Environment    => Empty,      --  seed ENVIRON[]
      Filename       => "input",
      Output         => Output,     --  captured stdout: "6\n"
      Exit_Code      => Exit_Code,  --  any `exit N`
      Status         => Status,     --  Run_Ok / Run_Error
      Message        => Message,    --  lex/parse/runtime failure text
      Output_Files   => Written);   --  captured `print > file` targets
end;
```

`Files` supplies content for `getline < name`; `Input_Files` supplies the main input as
an ordered list of (FILENAME, content) pairs so `FILENAME`/`FNR` track multi-file input.
Redirected output is symmetric: `print > name` / `print >> name` is **captured in
memory** and returned in `Output_Files` (one (name, content) entry per target, in
first-write order) — the library never touches the filesystem, so a front end decides
whether and where to write those files (the `cli/awk_run` example writes them to disk).

For front ends that need live host integration, `Awklib.Interpreter.Run_Streaming`
accepts a record-reader callback and stdout/redirection writer callbacks. For front
ends that have raw text chunks rather than pre-split records,
`Awklib.Interpreter.Run_Text_Streaming` accepts a text-reader callback and keeps AWK
record splitting inside `awklib`. These APIs do not preload main input, standard
output, or redirected output. The redirection callback receives the effective
append/truncate mode for each write.

`Arguments` seeds `ARGV`/`ARGC` the way a command line would (`ARGV[0]` is `"awk"`,
`ARGV[1..n]` the supplied strings, `ARGC` = n + 1); omit it and they default to the
`Input_Files` names, as awk's own `ARGV` holds the files it was given. `ARGV`/`ARGC` are
readable by the program but do not drive input — records come from `Input_Files`.
The interpreter is **reentrant**: all state is local to a `Run` call, so independent
programs may run concurrently on separate tasks (the shared compiled-regex cache is
guarded by a protected object).

Supported today includes fields and `NF`/`NR`, `BEGIN`/`END`, regex and relational
patterns, `FS`/`OFS`/`ORS`, arithmetic and strnum semantics, `printf`/`print`,
`length`/`substr`/`toupper`/`sub`/`gsub`, `getline`, `ARGC`/`ARGV`, **UTF-8 text**, and
multi-file input — see the [testsuite](tests/src/awklib_suite.adb) for worked behaviours.

## Known boundaries

- **Regex discipline.** `regexp` is a backtracking (leftmost-first) engine, so matches
  follow that discipline rather than POSIX leftmost-longest. For the simple expressions
  AWK programs typically use, the two never diverge.
- **UTF-8 is code-point aware, but byte-lenient.** String functions and regex operate on
  whole code points (`length`, `substr`, `.`, `[α-ω]`, …), yet input is never rejected
  for being malformed UTF-8 — stray bytes count as one character each. Because matching
  stays byte-lenient, `\w`/`\b` word-membership and case-insensitive folding are
  ASCII-only, and `printf` field width for `%c` counts bytes.
- **`getline` from the main stream in `BEGIN` needs streaming input.** `getline`,
  `getline var`, and `while ((getline) > 0)` read the main input correctly inside main
  rules for all APIs. `Run_Streaming` and `Run_Text_Streaming` also support main-input
  `getline` from `BEGIN` because records are read lazily. The in-memory `Run` API still
  splits records after `BEGIN` so an `RS` assigned in `BEGIN` takes effect.
  `getline < file` works everywhere; `cmd | getline` is not implemented.

## Architecture

A conventional pipeline, one package per stage: `Awklib.Lexer` → `Awklib.Parser` →
`Awklib.Ast` → `Awklib.Interpreter`, with `Awklib.Values` (AWK's strnum value model),
`Awklib.Format` (`printf`/`sprintf`), and `Awklib.Regex` (the bridge to `regexp`).

## Build & test

Built with [Alire](https://alire.ada.dev/) and GNAT 15.2.1.

```sh
alr build   # build the library
alr test    # build and run the AUnit suite (tests/)
```

The `cli/` directory has a small `awk_run` front end that runs a program from the command
line.

## Platforms

Pure Ada over `regexp`; Linux, macOS, and Windows are all supported and CI builds and
tests the library on all three.

## License

MIT © Bent Bracke

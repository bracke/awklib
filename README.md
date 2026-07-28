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
      Message        => Message);   --  lex/parse/runtime failure text
end;
```

`Files` supplies content for `getline < name`; `Input_Files` supplies the main input as
an ordered list of (FILENAME, content) pairs so `FILENAME`/`FNR` track multi-file input.
The interpreter is **not reentrant** — its state is process-global; run one program at a
time.

Supported today includes fields and `NF`/`NR`, `BEGIN`/`END`, regex and relational
patterns, `FS`/`OFS`/`ORS`, arithmetic and strnum semantics, `printf`/`print`,
`length`/`substr`/`toupper`/`sub`/`gsub`, `getline`, and multi-file input — see the
[testsuite](tests/src/awklib_suite.adb) for worked behaviours.

## Known boundary

`regexp` is a backtracking (leftmost-first) engine, so matches follow that discipline
rather than POSIX leftmost-longest. For the simple expressions AWK programs typically use
the two never diverge.

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

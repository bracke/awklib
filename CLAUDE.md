# CLAUDE.md

Guidance for AI agents (Claude Code and others) working in this repository.

## What this is

awklib is an Ada 2022 library implementing a POSIX-style AWK interpreter, embeddable via
`Awklib.Interpreter.Run` (program + input → captured output). Its one external dependency
is the sibling `regexp` crate, which supplies all regular-expression matching. The design
goal is to run **real, unmodified** AWK programs — the first consumer is the IANA tzdb
project's `ziguard`/`zishrink` scripts — so correctness is measured against
one-true-awk / gawk for the subset those programs use, not against a spec in the abstract.

## Build, test, verify

Built with [Alire](https://alire.ada.dev/) (`alr`), pinned to `gnat_native = "=15.2.1"`.

- `alr build` — compile the library.
- `alr test` — build and run the AUnit suite. The suite (`tests/`) drives
  `Awklib.Interpreter.Run` with a program and an input string and asserts the captured
  output — the natural way to add a case is another `Run` + `Assert` pair in
  `tests/src/awklib_suite.adb`.
- `cli/awk_run` is a command-line front end useful for checking behaviour by hand.

## Architecture

A conventional interpreter pipeline, one package per stage — change the stage that owns
the concern, not the interpreter as a whole:

- `Awklib.Lexer` → `Awklib.Parser` → `Awklib.Ast` — source to syntax tree.
- `Awklib.Interpreter` — walks the tree; the only public entry point.
- `Awklib.Values` — AWK's value model (the strnum: a string that is also a number when it
  looks like one). Most subtle-bug territory lives here.
- `Awklib.Format` — `printf`/`sprintf` formatting.
- `Awklib.Regex` — the bridge to the `regexp` engine.

## Conventions

- Match real AWK behaviour; when in doubt, check `awk`/`gawk` and add a test that pins the
  case. A new feature without a suite case is not done.
- The interpreter is **not reentrant** (process-global state) — do not assume otherwise.
- The known, deliberate divergence is regex discipline: `regexp` is backtracking
  (leftmost-first), not POSIX leftmost-longest. Don't "fix" that per-call; it is a
  property of the engine.
- Conventional-commits style (`feat:`, `fix:`, `refactor:`, …).

## Tri-platform CI

CI builds and tests on ubuntu-latest, macos-15-intel, and windows-latest. awklib is pure
Ada over `regexp`, so all three should stay green; the macOS image must be x86_64
(`macos-15-intel`) because the pinned `gnat_native=15.2.1` ships no aarch64-darwin binary.
A Linux release-check job additionally runs the `project_tools`-based `check_awklib`
release checklist.

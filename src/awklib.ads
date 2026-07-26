package Awklib
  with Preelaborate
is
   --  Root package for the AWK interpreter library.
   --
   --  awklib implements a POSIX-style AWK language on top of the sibling
   --  `regexp` engine (which supplies all regular-expression matching). The
   --  goal is to run real, unmodified AWK programs -- its first consumer runs
   --  the IANA tzdb project's own ziguard/zishrink scripts -- so behaviour aims
   --  to match one-true-awk / gawk for the language subset those programs use.
   --
   --  Known boundary: `regexp` is a backtracking (leftmost-first) engine, so
   --  regex matches follow that discipline rather than POSIX leftmost-longest.
   --  For simple expressions the two never diverge.

   Version : constant String := "0.1.0";

   --  Raised for unrecoverable interpreter faults that are not reported through
   --  a status value (e.g. a parse used where the caller promised valid input).
   Awk_Error : exception;

end Awklib;

package Awklib.Regex is
   --  Thin AWK-flavoured wrapper over the regexp engine: case-sensitive
   --  matching (AWK's default, unlike regexp's) and a compile cache keyed by
   --  pattern text (dynamic regexes recur constantly over large inputs).
   --
   --  Not reentrant: the cache is process-global.

   type Match is record
      Matched : Boolean := False;
      First   : Natural := 0;   --  1-based offset into Text; 0 when no match
      Last    : Natural := 0;   --  1-based; Last < First for a zero-length match
   end record;

   function Is_Match (Pattern, Text : String) return Boolean;
   --  True when Pattern matches anywhere in Text. A pattern that fails to
   --  compile never matches.

   function Search (Pattern, Text : String; From : Positive := 1) return Match;
   --  Earliest match of Pattern in Text at or after the 1-based offset From.

end Awklib.Regex;

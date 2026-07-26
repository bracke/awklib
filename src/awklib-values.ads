with Ada.Strings.Unbounded;

package Awklib.Values is
   --  The AWK scalar value model.
   --
   --  A scalar is one of:
   --    * Uninitialized -- an unset variable; behaves as "" and 0 at once.
   --    * Number        -- a numeric value (AWK numbers are doubles).
   --    * Str           -- a genuine string (string literals, string builtins).
   --    * Strnum        -- a string that entered the program from the outside
   --                       (a field, getline, FS split, -v, ENVIRON). It
   --                       compares numerically iff it *looks* numeric. This is
   --                       the distinction that makes field "0" false but the
   --                       string constant "0" true.

   package U renames Ada.Strings.Unbounded;

   type Number is new Long_Float;

   type Value_Kind is (Uninitialized, Num, Str, Strnum);

   type Value is record
      Kind : Value_Kind := Uninitialized;
      N    : Number := 0.0;                    --  meaningful for Num
      S    : U.Unbounded_String;               --  meaningful for Str/Strnum
   end record;

   --  Structural equality (needed to store values in hashed containers).
   --  Declared before the type is frozen.
   function "=" (Left, Right : Value) return Boolean;

   Uninitialized_Value : constant Value := (Kind => Uninitialized, others => <>);

   --  Constructors.
   function To_Value (Item : Number) return Value;
   function To_Value (Item : String) return Value;          --  a genuine string
   function To_Value (Item : U.Unbounded_String) return Value;
   function Make_Strnum (Item : String) return Value;       --  input-derived text

   --  Coercions.
   function As_Number (Item : Value) return Number;
   function As_String (Item : Value) return String;
   function As_Unbounded (Item : Value) return U.Unbounded_String;

   --  AWK truthiness: number /= 0, non-empty genuine string, numeric strnum
   --  /= 0, non-empty non-numeric strnum. Uninitialized is false.
   function Is_True (Item : Value) return Boolean;

   --  Comparison following POSIX rules: numeric if both operands are treated as
   --  numeric (Number, Uninitialized, or numeric-looking Strnum), else string.
   --  Returns -1, 0, or 1.
   function Compare (Left, Right : Value) return Integer;

   --  True when Text is a valid AWK numeric string (optionally surrounded by
   --  blanks): [+-]? ( d+ (.d*)? | .d+ ) ([eE][+-]?d+)?.
   function Looks_Numeric (Text : String) return Boolean;

   --  strtod-style leading-prefix parse: skip blanks, read the longest numeric
   --  prefix, return its value (0.0 if none). "-0:30" yields 0.0.
   function Parse_Leading_Number (Text : String) return Number;

   --  Format a Number as AWK would for implicit string conversion: an integral
   --  value prints with no fraction; otherwise CONVFMT ("%.6g").
   function Number_Image (Item : Number) return String;

end Awklib.Values;

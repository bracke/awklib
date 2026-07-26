with Awklib.Values;

package Awklib.Format is
   --  AWK printf/sprintf formatting.

   type Value_Array is array (Positive range <>) of Awklib.Values.Value;

   function Sprintf (Fmt : String; Args : Value_Array) return String;
   --  Format Args per the AWK/C format string Fmt. Supports conversions
   --  d i o u x X c s e E f F g G %% with the - + space # 0 flags, a width and
   --  a precision (each optionally '*' taken from Args). Missing arguments read
   --  as "" / 0; surplus arguments are ignored.

end Awklib.Format;

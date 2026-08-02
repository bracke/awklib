with AUnit;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Ada.Directories;
with Ada.Strings.Unbounded;

with Awklib.Interpreter;

package body Awklib_Suite is
   use AUnit.Assertions;

   package I renames Awklib.Interpreter;
   package U renames Ada.Strings.Unbounded;
   use type I.Run_Status;

   LF : constant String := [1 => ASCII.LF];
   HT : constant String := [1 => ASCII.HT];
   DQ : constant String := [1 => '"'];

   Stream_Files   : I.Assignment_Vectors.Vector;
   Stream_Index   : Natural := 0;
   Stream_Output  : U.Unbounded_String;
   Stream_Redirect_Log : U.Unbounded_String;

   procedure Stream_Read
     (Filename     : out U.Unbounded_String;
      Record_Text  : out U.Unbounded_String;
      End_Of_Input : out Boolean)
   is
   begin
      if Stream_Index >= Natural (Stream_Files.Length) then
         Filename := U.Null_Unbounded_String;
         Record_Text := U.Null_Unbounded_String;
         End_Of_Input := True;
      else
         Stream_Index := Stream_Index + 1;
         Filename := Stream_Files.Element (Stream_Index).Name;
         Record_Text := Stream_Files.Element (Stream_Index).Value;
         End_Of_Input := False;
      end if;
   end Stream_Read;

   procedure Stream_Text_Read
     (Filename     : out U.Unbounded_String;
      Text         : out U.Unbounded_String;
      End_Of_Input : out Boolean)
   is
   begin
      if Stream_Index >= Natural (Stream_Files.Length) then
         Filename := U.Null_Unbounded_String;
         Text := U.Null_Unbounded_String;
         End_Of_Input := True;
      else
         Stream_Index := Stream_Index + 1;
         Filename := Stream_Files.Element (Stream_Index).Name;
         Text := Stream_Files.Element (Stream_Index).Value;
         End_Of_Input := False;
      end if;
   end Stream_Text_Read;

   procedure Stream_Write (Text : String) is
   begin
      U.Append (Stream_Output, Text);
   end Stream_Write;

   procedure Stream_Redirect
     (Name : String;
      Text : String;
      Append : Boolean;
      Truncate : Boolean)
   is
   begin
      U.Append (Stream_Redirect_Log, Name);
      U.Append (Stream_Redirect_Log, ":");
      U.Append (Stream_Redirect_Log, (if Append then "append" else "write"));
      U.Append (Stream_Redirect_Log, ":");
      U.Append (Stream_Redirect_Log, (if Truncate then "truncate" else "keep"));
      U.Append (Stream_Redirect_Log, ":");
      U.Append (Stream_Redirect_Log, Text);
   end Stream_Redirect;

   procedure Reset_Stream is
   begin
      Stream_Files.Clear;
      Stream_Index := 0;
      Stream_Output := U.Null_Unbounded_String;
      Stream_Redirect_Log := U.Null_Unbounded_String;
   end Reset_Stream;

   --  Run PROGRAM over INPUT with no seeded variables and return captured stdout.
   function Awk (Program : String; Input : String := "") return String is
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      I.Run
        (Program_Source => Program,
         Input          => Input,
         Assignments    => Empty,
         Environment    => Empty,
         Filename       => "test",
         Output         => Output,
         Exit_Code      => Exit_Code,
         Status         => Status,
         Message        => Message,
         Output_Files   => Written);
      return U.To_String (Output);
   end Awk;

   function Pair (Name, Value : String) return I.Var_Assignment is
     (I.Var_Assignment'(Name  => U.To_Unbounded_String (Name),
                        Value => U.To_Unbounded_String (Value)));

   --  Run PROGRAM with one named file available to `getline < name`.
   function Awk_With_File
     (Program, File_Name, File_Content : String) return String
   is
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Files     : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Files.Append (Pair (File_Name, File_Content));
      I.Run
        (Program_Source => Program, Input => "", Assignments => Empty,
         Environment => Empty, Filename => "test", Output => Output,
         Exit_Code => Exit_Code, Status => Status, Message => Message,
         Output_Files => Written, Files => Files);
      return U.To_String (Output);
   end Awk_With_File;

   --  Run PROGRAM over two named input files (for FILENAME/FNR/NR).
   function Awk_Two_Files (Program, N1, C1, N2, C2 : String) return String is
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Inputs    : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Inputs.Append (Pair (N1, C1));
      Inputs.Append (Pair (N2, C2));
      I.Run
        (Program_Source => Program, Input => "", Assignments => Empty,
         Environment => Empty, Filename => "test", Output => Output,
         Exit_Code => Exit_Code, Status => Status, Message => Message,
         Output_Files => Written, Input_Files => Inputs);
      return U.To_String (Output);
   end Awk_Two_Files;

   procedure Test_Begin (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { print ""hello"" }") = "hello" & LF, "BEGIN block prints once");
   end Test_Begin;

   procedure Test_Whole_Record (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print }", "one" & LF & "two" & LF) = "one" & LF & "two" & LF,
              "bare print echoes $0 per record");
   end Test_Whole_Record;

   procedure Test_Field (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print $1 }", "a b c" & LF) = "a" & LF, "first field");
      Assert (Awk ("{ print $3 }", "a b c" & LF) = "c" & LF, "third field");
   end Test_Field;

   procedure Test_NF (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print NF }", "a b c" & LF) = "3" & LF, "NF counts fields");
   end Test_NF;

   procedure Test_NR (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print NR }", "x" & LF & "y" & LF) = "1" & LF & "2" & LF,
              "NR counts records");
   end Test_NR;

   procedure Test_Accumulate (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ s += $1 } END { print s }", "1" & LF & "2" & LF & "3" & LF) = "6" & LF,
              "accumulate a column and print the total in END");
   end Test_Accumulate;

   procedure Test_Regex_Pattern (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("/b/ { print }", "a" & LF & "b" & LF & "c" & LF) = "b" & LF,
              "a bare regex selects matching records");
   end Test_Regex_Pattern;

   procedure Test_Comparison_Pattern (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Awk ("$1 > 3 { print $1 }", "1" & LF & "5" & LF & "2" & LF & "8" & LF) = "5" & LF & "8" & LF,
         "a relational pattern filters numerically");
   end Test_Comparison_Pattern;

   procedure Test_Field_Separator (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { FS = "","" } { print $2 }", "a,b,c" & LF) = "b" & LF,
              "FS splits on a chosen separator");
   end Test_Field_Separator;

   procedure Test_Output_Field_Separator (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { OFS = ""-"" } { print $1, $2 }", "hello world" & LF) = "hello-world" & LF,
              "OFS joins printed fields");
   end Test_Output_Field_Separator;

   procedure Test_Printf (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { printf ""%d-%s"" ORS, 42, ""x"" }") = "42-x" & LF,
              "printf formats integers and strings");
      Assert (Awk ("BEGIN { printf ""%.2f"" ORS, 3.14159 }") = "3.14" & LF,
              "printf rounds floats");
   end Test_Printf;

   procedure Test_Length (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print length($0) }", "abcd" & LF) = "4" & LF, "length of a string");
   end Test_Length;

   procedure Test_Substr (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print substr($0, 1, 5) }", "hello world" & LF) = "hello" & LF,
              "substr extracts a slice");
   end Test_Substr;

   procedure Test_Toupper (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ print toupper($1) }", "hello world" & LF) = "HELLO" & LF, "toupper");
   end Test_Toupper;

   procedure Test_Gsub (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ n = gsub(/a/, ""X""); print $0, n }", "banana" & LF) = "bXnXnX 3" & LF,
              "gsub replaces all and returns the count");
   end Test_Gsub;

   procedure Test_Seeded_Variable (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Assigns   : I.Assignment_Vectors.Vector;
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Assigns.Append
        (I.Var_Assignment'(Name  => U.To_Unbounded_String ("x"),
                           Value => U.To_Unbounded_String ("7")));
      I.Run
        (Program_Source => "BEGIN { print x + 1 }",
         Input          => "",
         Assignments    => Assigns,
         Environment    => Empty,
         Filename       => "test",
         Output         => Output,
         Exit_Code      => Exit_Code,
         Status         => Status,
         Message        => Message,
         Output_Files   => Written);
      Assert (Status = I.Run_Ok, "seeded run succeeds");
      Assert (U.To_String (Output) = "8" & LF, "a seeded variable is a numeric strnum");
   end Test_Seeded_Variable;

   procedure Test_Exit_Code (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      I.Run
        (Program_Source => "BEGIN { exit 3 }",
         Input          => "",
         Assignments    => Empty,
         Environment    => Empty,
         Filename       => "test",
         Output         => Output,
         Exit_Code      => Exit_Code,
         Status         => Status,
         Message        => Message,
         Output_Files   => Written);
      Assert (Status = I.Run_Ok, "exit is a clean run, not an error");
      Assert (Exit_Code = 3, "exit N is reported as the exit code");
   end Test_Exit_Code;

   procedure Test_Parse_Error (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      I.Run
        (Program_Source => "BEGIN {",
         Input          => "",
         Assignments    => Empty,
         Environment    => Empty,
         Filename       => "test",
         Output         => Output,
         Exit_Code      => Exit_Code,
         Status         => Status,
         Message        => Message,
         Output_Files   => Written);
      Assert (Status = I.Run_Error, "an unterminated block is a run error");
      Assert (U.Length (Message) > 0, "a parse failure carries a message");
   end Test_Parse_Error;

   procedure Test_Getline_Var (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Awk ("{ getline nl; print $0 ""/"" nl }", "a" & LF & "b" & LF & "c" & LF & "d" & LF)
           = "a/b" & LF & "c/d" & LF,
         "getline into a variable reads the next main record");
   end Test_Getline_Var;

   procedure Test_Getline_Plain (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ getline; print }", "a" & LF & "b" & LF & "c" & LF & "d" & LF) = "b" & LF & "d" & LF,
              "plain getline advances $0 to the next main record");
   end Test_Getline_Plain;

   procedure Test_RS_Char (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Awk ("BEGIN { RS = "";"" } { print NR "": "" $0 }", "a;b;c")
           = "1: a" & LF & "2: b" & LF & "3: c" & LF,
         "a single-character RS splits records");
   end Test_RS_Char;

   procedure Test_RS_Paragraph (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Awk ("BEGIN { RS = """" } { print NR }", "a" & LF & "b" & LF & LF & "c" & LF & "d" & LF)
           = "1" & LF & "2" & LF,
         "RS = """" is paragraph mode");
   end Test_RS_Paragraph;

   procedure Test_OFMT (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { OFMT = ""%.2f"" } { print $1 + 0 }", "3.14159" & LF) = "3.14" & LF,
              "OFMT formats printed numbers");
   end Test_OFMT;

   procedure Test_Printf_Sci (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { printf ""%e"", 31415.9 }") = "3.141590e+04", "%e is C-style");
      Assert (Awk ("BEGIN { printf ""%E"", 1000000 }") = "1.000000E+06", "%E is C-style");
   end Test_Printf_Sci;

   procedure Test_Printf_G (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { printf ""%g"", 3.14159 }") = "3.14159", "%g fixed form");
      Assert (Awk ("BEGIN { printf ""%g"", 1000000 }") = "1e+06", "%g switches to exponent");
      Assert (Awk ("BEGIN { printf ""%g"", 0.00001 }") = "1e-05", "%g small switches to exponent");
   end Test_Printf_G;

   procedure Test_Printf_F0 (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { printf ""%.0f"", 2.7 }") = "3", "%.0f rounds");
      Assert (Awk ("BEGIN { printf ""%.0f"", 2.5 }") = "2", "%.0f rounds half to even");
   end Test_Printf_F0;

   procedure Test_Control_Flow (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { if (3 > 2) print ""y""; else print ""n"" }") = "y" & LF, "if/else");
      Assert (Awk ("BEGIN { i = 0; while (i < 3) { print i; i++ } }") = "0" & LF & "1" & LF & "2" & LF,
              "while");
      Assert (Awk ("BEGIN { i = 0; do { print i; i++ } while (i < 3) }") = "0" & LF & "1" & LF & "2" & LF,
              "do-while");
      Assert (Awk ("BEGIN { for (i = 0; i < 3; i++) print i }") = "0" & LF & "1" & LF & "2" & LF,
              "for");
      Assert
        (Awk ("BEGIN { for (i = 0; i < 5; i++) { if (i == 2) continue; if (i == 4) break; print i } }")
           = "0" & LF & "1" & LF & "3" & LF,
         "break and continue");
      Assert (Awk ("NR == 2 { next } { print }", "a" & LF & "b" & LF & "c" & LF) = "a" & LF & "c" & LF,
              "next skips a record");
   end Test_Control_Flow;

   procedure Test_Math (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { print int(3.9), int(-3.9) }") = "3 -3" & LF, "int truncates toward zero");
      Assert (Awk ("BEGIN { print sqrt(16) }") = "4" & LF, "sqrt");
      Assert (Awk ("BEGIN { printf ""%.4f %.4f"", sin(1), cos(1) }") = "0.8415 0.5403", "sin/cos");
      Assert (Awk ("BEGIN { printf ""%.4f %.4f"", exp(1), log(10) }") = "2.7183 2.3026", "exp/log");
      Assert (Awk ("BEGIN { printf ""%.4f"", atan2(1, 1) }") = "0.7854", "atan2");
   end Test_Math;

   procedure Test_Rand (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { srand(1); r = rand(); print (r >= 0 && r < 1) }") = "1" & LF,
              "rand is in [0, 1)");
      Assert (Awk ("BEGIN { srand(7); a = rand(); srand(7); b = rand(); print (a == b) }") = "1" & LF,
              "srand makes rand reproducible");
   end Test_Rand;

   procedure Test_Arrays (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { a[""x""] = 1; a[""y""] = 2; for (k in a) s += a[k]; print s }") = "3" & LF,
              "associative array and for-in");
      Assert (Awk ("BEGIN { a[""x""] = 1; delete a[""x""]; print (""x"" in a) }") = "0" & LF,
              "delete an element");
      Assert (Awk ("BEGIN { a[""x""] = 1; print (""x"" in a), (""y"" in a) }") = "1 0" & LF,
              "the in operator");
      Assert
        (Awk ("BEGIN { a[1, 2] = 9; for (k in a) { split(k, p, SUBSEP); print p[1], p[2], a[k] } }")
           = "1 2 9" & LF,
         "multi-dimensional subscripts via SUBSEP");
   end Test_Arrays;

   procedure Test_Functions (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("function sq(n) { return n * n } BEGIN { print sq(5) }") = "25" & LF,
              "a user function returns a value");
      Assert
        (Awk ("function f(n) { return n <= 1 ? 1 : n * f(n - 1) } BEGIN { print f(5) }") = "120" & LF,
         "recursion");
      Assert
        (Awk ("function g(n,   loc) { loc = n + 1; return loc } BEGIN { loc = 99; print g(1), loc }")
           = "2 99" & LF,
         "an extra parameter is a local variable");
   end Test_Functions;

   procedure Test_Operators (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { x = 5; print x++, x, --x }") = "5 6 5" & LF, "increment and decrement");
      Assert (Awk ("BEGIN { x = 10; x += 5; x *= 2; print x }") = "30" & LF, "compound assignment");
      Assert (Awk ("BEGIN { print (1 > 2) ? ""a"" : ""b"" }") = "b" & LF, "the ternary operator");
      Assert (Awk ("BEGIN { print 2 ^ 10 }") = "1024" & LF, "exponentiation");
      Assert (Awk ("BEGIN { print 2 ** 10 }") = "1024" & LF, "** is an alias for ^");
      Assert (Awk ("BEGIN { print 2 ** 3 ** 2 }") = "512" & LF, "** is right-associative like ^");
      Assert (Awk ("BEGIN { x = 3; x **= 2; print x }") = "9" & LF, "**= is an alias for ^=");
      Assert (Awk ("BEGIN { print (1 && 0), (1 || 0), (! 1) }") = "0 1 0" & LF, "logical operators");
      Assert (Awk ("BEGIN { x = ""ab""; y = ""cd""; print x y }") = "abcd" & LF, "string concatenation");
      Assert (Awk ("{ print ($1 ~ /^[0-9]+$/), ($1 !~ /x/) }", "42" & LF) = "1 1" & LF, "match operators");
   end Test_Operators;

   procedure Test_Fields (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ $2 = ""X""; print }", "a b c" & LF) = "a X c" & LF, "assigning a field rebuilds $0");
      Assert (Awk ("{ NF = 2; print }", "a b c d" & LF) = "a b" & LF, "lowering NF truncates the record");
      Assert (Awk ("{ $0 = ""x y z""; print NF, $2 }", "a b" & LF) = "3 y" & LF,
              "assigning $0 re-splits the fields");
      Assert (Awk ("{ i = 2; print $(i) }", "a b c" & LF) = "b" & LF, "a computed field index");
   end Test_Fields;

   procedure Test_Field_Splitting (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { FS = ""\t"" } { print $2 }", "a" & HT & "b" & HT & "c" & LF) = "b" & LF,
              "a tab field separator");
      Assert (Awk ("BEGIN { FS = ""[0-9]+"" } { print $2 }", "a12b34c" & LF) = "b" & LF,
              "a regular-expression field separator");
      Assert (Awk ("{ print $1 }", "   leading   spaces  " & LF) = "leading" & LF,
              "the default separator ignores leading blanks");
   end Test_Field_Splitting;

   procedure Test_String_Functions (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("{ n = split($0, a); print n, a[1], a[3] }", "x y z" & LF) = "3 x z" & LF,
              "split on the default separator");
      Assert (Awk ("BEGIN { print index(""hello"", ""ll""), index(""hello"", ""z"") }") = "3 0" & LF,
              "index");
      Assert
        (Awk ("BEGIN { print match(""foobar"", /o+/), RSTART, RLENGTH }") = "2 2 2" & LF,
         "match sets RSTART and RLENGTH");
      Assert (Awk ("BEGIN { s = ""hello""; n = sub(/l/, ""L"", s); print s, n }") = "heLlo 1" & LF,
              "sub replaces the first match and returns the count");
      Assert (Awk ("BEGIN { print tolower(""HeLLo"") }") = "hello" & LF, "tolower");
      Assert (Awk ("BEGIN { print sprintf(""%d/%s"", 7, ""x"") }") = "7/x" & LF, "sprintf");
   end Test_String_Functions;

   procedure Test_Getline_File (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Awk_With_File
           ("BEGIN { while ((getline l < ""data"") > 0) print ""g:"" l }",
            "data", "one" & LF & "two" & LF)
           = "g:one" & LF & "g:two" & LF,
         "getline < file reads a named file");
   end Test_Getline_File;

   procedure Test_Multi_File (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Awk_Two_Files
           ("{ print FILENAME, FNR, NR }", "f1", "a" & LF & "b" & LF, "f2", "c" & LF)
           = "f1 1 1" & LF & "f1 2 2" & LF & "f2 1 3" & LF,
         "FILENAME and FNR track each file while NR runs continuously");
   end Test_Multi_File;

   procedure Test_Streaming_Input (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Reset_Stream;
      Stream_Files.Append (Pair ("f1", "alpha one"));
      Stream_Files.Append (Pair ("f1", "beta two"));
      Stream_Files.Append (Pair ("f2", "gamma three"));
      I.Run_Streaming
        (Program_Source => "{ print FILENAME, FNR, NR, $1 }",
         Assignments => Empty,
         Environment => Empty,
         Initial_Filename => "test",
         Read_Record => Stream_Read'Access,
         Write_Output => Stream_Write'Access,
         Write_Redirection => null,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message);
      Assert (Status = I.Run_Ok, "streaming run succeeds");
      Assert
        (U.To_String (Stream_Output) =
         "f1 1 1 alpha" & LF & "f1 2 2 beta" & LF & "f2 1 3 gamma" & LF,
         "streaming input drives FILENAME, FNR, NR, fields, and live stdout");
   end Test_Streaming_Input;

   procedure Test_Streaming_Getline_From_Begin
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Reset_Stream;
      Stream_Files.Append (Pair ("stdin", "first"));
      Stream_Files.Append (Pair ("stdin", "second"));
      I.Run_Streaming
        (Program_Source =>
           "BEGIN { getline x; print FILENAME, FNR, NR, x } { print ""main"", $0 }",
         Assignments => Empty,
         Environment => Empty,
         Initial_Filename => "stdin",
         Read_Record => Stream_Read'Access,
         Write_Output => Stream_Write'Access,
         Write_Redirection => null,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message);
      Assert (Status = I.Run_Ok, "streaming getline from BEGIN succeeds");
      Assert
        (U.To_String (Stream_Output) =
         "stdin 1 1 first" & LF & "main second" & LF,
         "BEGIN getline consumes the first streaming record");
   end Test_Streaming_Getline_From_Begin;

   procedure Test_Streaming_Redirection
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Reset_Stream;
      I.Run_Streaming
        (Program_Source =>
           "BEGIN { print ""a"" > ""out""; print ""b"" > ""out""; print ""c"" >> ""out"" }",
         Assignments => Empty,
         Environment => Empty,
         Initial_Filename => "test",
         Read_Record => Stream_Read'Access,
         Write_Output => Stream_Write'Access,
         Write_Redirection => Stream_Redirect'Access,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message);
      Assert (Status = I.Run_Ok, "streaming redirection run succeeds");
      Assert
        (U.To_String (Stream_Redirect_Log) =
         "out:write:truncate:a" & LF &
         "out:append:keep:b" & LF &
         "out:append:keep:c" & LF,
         "streaming redirection exposes effective write mode");
   end Test_Streaming_Redirection;

   procedure Test_Text_Streaming_Splits_Records
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Reset_Stream;
      Stream_Files.Append (Pair ("f1", "alpha"));
      Stream_Files.Append (Pair ("f1", " one" & LF & "beta two" & LF & "gam"));
      Stream_Files.Append (Pair ("f2", "delta four" & LF));
      I.Run_Text_Streaming
        (Program_Source => "{ print FILENAME, FNR, NR, $0 }",
         Assignments => Empty,
         Environment => Empty,
         Initial_Filename => "test",
         Read_Text => Stream_Text_Read'Access,
         Write_Output => Stream_Write'Access,
         Write_Redirection => null,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message);
      Assert (Status = I.Run_Ok, "text streaming run succeeds");
      Assert
        (U.To_String (Stream_Output) =
         "f1 1 1 alpha one" & LF & "f1 2 2 beta two" & LF & "f1 3 3 gam" & LF &
         "f2 1 4 delta four" & LF,
         "awklib splits streamed text chunks into AWK records");
   end Test_Text_Streaming_Splits_Records;

   procedure Test_Text_Streaming_Uses_Begin_RS
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Reset_Stream;
      Stream_Files.Append (Pair ("stdin", "a;b"));
      Stream_Files.Append (Pair ("stdin", ";c"));
      I.Run_Text_Streaming
        (Program_Source => "BEGIN { RS = "";"" } { print NR, $0 }",
         Assignments => Empty,
         Environment => Empty,
         Initial_Filename => "stdin",
         Read_Text => Stream_Text_Read'Access,
         Write_Output => Stream_Write'Access,
         Write_Redirection => null,
         Exit_Code => Exit_Code,
         Status => Status,
         Message => Message);
      Assert (Status = I.Run_Ok, "text streaming with BEGIN RS succeeds");
      Assert
        (U.To_String (Stream_Output) =
         "1 a" & LF & "2 b" & LF & "3 c" & LF,
         "text streaming applies RS assigned in BEGIN");
   end Test_Text_Streaming_Uses_Begin_RS;

   procedure Test_Printf_Flags (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { printf ""[%-5d][%05d][%+d][% d]"", 3, 3, 3, 3 }") = "[3    ][00003][+3][ 3]",
              "printf flags");
      Assert (Awk ("BEGIN { printf ""[%*d]"", 5, 42 }") = "[   42]", "printf dynamic (*) width");
      Assert (Awk ("BEGIN { printf ""%o %x %c"", 8, 255, 65 }") = "10 ff A", "printf %o/%x/%c");
   end Test_Printf_Flags;

   procedure Test_Coercion (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { x = ""3abc""; print x + 2 }") = "5" & LF, "a leading numeric prefix coerces");
      Assert (Awk ("BEGIN { print x + 0, ""["" x ""]"" }") = "0 []" & LF, "an uninitialised variable is 0/empty");
      Assert (Awk ("BEGIN { print (""10"" < ""9""), (10 < 9) }") = "1 0" & LF,
              "string compares lexically, numbers numerically");
      Assert (Awk ("BEGIN { print substr(""hello"", -1, 3), substr(""hello"", 2, 100) }") = "h ello" & LF,
              "substr clamps out-of-range positions");
   end Test_Coercion;

   procedure Test_Escapes (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { print ""a\tb"" }") = "a" & HT & "b" & LF, "a tab escape in a string literal");
      Assert (Awk ("BEGIN { printf ""x\ny\n"" }") = "x" & LF & "y" & LF, "newline escapes in printf");
   end Test_Escapes;

   procedure Test_CONVFMT (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Assert (Awk ("BEGIN { CONVFMT = ""%.2f""; x = 3.14159; print x """" }") = "3.14" & LF,
              "CONVFMT governs number-to-string in concatenation");
      Assert (Awk ("BEGIN { CONVFMT = ""%.2f""; a[3.14159] = 1; for (k in a) print k }") = "3.14" & LF,
              "CONVFMT governs an array subscript");
      Assert (Awk ("BEGIN { x = 1 / 3; print x """" }") = "0.333333" & LF,
              "the default CONVFMT is %.6g");
   end Test_CONVFMT;

   procedure Test_Redirect (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      One       : constant String := "awklib_redirect_one.tmp";
      Two       : constant String := "awklib_redirect_two.tmp";
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
      --  ">" truncates then appends to the same stream; ">>" appends. All of it
      --  must be captured in memory, so a second target proves ordering too.
      Program   : constant String :=
        "BEGIN {"
        & " print " & DQ & "a" & DQ & " > "  & DQ & One & DQ & ";"
        & " print " & DQ & "b" & DQ & " > "  & DQ & One & DQ & ";"
        & " print " & DQ & "x" & DQ & " >> " & DQ & Two & DQ & ";"
        & " print " & DQ & "y" & DQ & " >> " & DQ & Two & DQ
        & " }";

      function Captured (Name : String) return String is
      begin
         for E of Written loop
            if U.To_String (E.Name) = Name then
               return U.To_String (E.Value);
            end if;
         end loop;
         return "<absent>";
      end Captured;
   begin
      I.Run
        (Program_Source => Program, Input => "", Assignments => Empty,
         Environment => Empty, Filename => "test", Output => Output,
         Exit_Code => Exit_Code, Status => Status, Message => Message,
         Output_Files => Written);
      Assert (Natural (Written.Length) = 2, "each redirect target is one capture entry");
      Assert (U.To_String (Written.Element (1).Name) = One,
              "captures preserve first-write order");
      Assert (Captured (One) = "a" & LF & "b" & LF,
              "redirection to a name captures its records in memory, single newlines");
      Assert (Captured (Two) = "x" & LF & "y" & LF,
              "append redirection accumulates in the capture");
      Assert (not Ada.Directories.Exists (One) and then not Ada.Directories.Exists (Two),
              "redirection never touches the filesystem");
   end Test_Redirect;

   --  Reentrancy: many interpreter runs at once, each summing 1..Id. If Run kept
   --  shared state the concurrent runs would corrupt one another's totals.
   procedure Test_Reentrancy (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      N       : constant := 16;
      Results : array (1 .. N) of U.Unbounded_String;

      function Img (K : Integer) return String is
         S : constant String := Integer'Image (K);
      begin
         return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
      end Img;

      task type Worker is
         entry Go (Id : Integer);
      end Worker;

      task body Worker is
         My : Integer;
      begin
         accept Go (Id : Integer) do
            My := Id;
         end Go;
         Results (My) := U.To_Unbounded_String
           (Awk ("BEGIN { s = 0; for (i = 1; i <= " & Img (My) & "; i++) s += i; print s }"));
      end Worker;
   begin
      declare
         W : array (1 .. N) of Worker;
      begin
         for K in 1 .. N loop
            W (K).Go (K);
         end loop;
      end;  --  blocks until every worker terminates
      for K in 1 .. N loop
         Assert (U.To_String (Results (K)) = Img (K * (K + 1) / 2) & LF,
                 "concurrent run" & Integer'Image (K) & " kept its own state");
      end loop;
   end Test_Reentrancy;

   --  ARGV/ARGC: seeded from client-supplied Arguments, and (when none are
   --  given) derived from the Input_Files names, as awk's own ARGV would be.
   procedure Test_Argv (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Args      : I.String_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      Args.Append (U.To_Unbounded_String ("alpha"));
      Args.Append (U.To_Unbounded_String ("beta"));
      I.Run
        (Program_Source =>
           "BEGIN { printf ""%d;%s;%s;%s"", ARGC, ARGV[0], ARGV[1], ARGV[2] }",
         Input => "", Assignments => Empty, Environment => Empty,
         Filename => "test", Output => Output, Exit_Code => Exit_Code,
         Status => Status, Message => Message, Output_Files => Written,
         Arguments => Args);
      Assert (U.To_String (Output) = "3;awk;alpha;beta",
              "client-supplied Arguments seed ARGV[1..], ARGV[0], and ARGC");

      declare
         Inputs : I.Assignment_Vectors.Vector;
         Out2   : U.Unbounded_String;
         W2     : I.Assignment_Vectors.Vector;
      begin
         Inputs.Append (Pair ("data1", "x" & LF));
         Inputs.Append (Pair ("data2", "y" & LF));
         I.Run
           (Program_Source => "BEGIN { printf ""%d;%s;%s"", ARGC, ARGV[1], ARGV[2] }",
            Input => "", Assignments => Empty, Environment => Empty,
            Filename => "test", Output => Out2, Exit_Code => Exit_Code,
            Status => Status, Message => Message, Output_Files => W2,
            Input_Files => Inputs);
         Assert (U.To_String (Out2) = "3;data1;data2",
                 "with no Arguments, ARGV/ARGC default to the Input_Files names");
      end;
   end Test_Argv;

   --  Arithmetic must never crash the host: division by zero is a graceful
   --  runtime error, and a non-finite result formats as inf/nan like C/awk.
   procedure Test_Arithmetic_Safety (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
      Written   : I.Assignment_Vectors.Vector;
      Output    : U.Unbounded_String;
      Message   : U.Unbounded_String;
      Exit_Code : Integer;
      Status    : I.Run_Status;
   begin
      I.Run
        (Program_Source => "BEGIN { print 1 / 0 }", Input => "",
         Assignments => Empty, Environment => Empty, Filename => "test",
         Output => Output, Exit_Code => Exit_Code, Status => Status,
         Message => Message, Output_Files => Written);
      Assert (Status = I.Run_Error, "division by zero is a runtime error, not a crash");
      Assert (U.Index (Message, "division by zero") > 0, "the message names division by zero");

      I.Run
        (Program_Source => "BEGIN { print 5 % 0 }", Input => "",
         Assignments => Empty, Environment => Empty, Filename => "test",
         Output => Output, Exit_Code => Exit_Code, Status => Status,
         Message => Message, Output_Files => Written);
      Assert (Status = I.Run_Error, "modulo by zero is a runtime error, not a crash");

      Assert (Awk ("BEGIN { print 10 ** 400 }") = "inf" & LF, "overflow prints inf");
      Assert (Awk ("BEGIN { print -1 * 10 ** 400 }") = "-inf" & LF, "negative overflow prints -inf");
      Assert (Awk ("BEGIN { printf ""%G"", 10 ** 400 }") = "INF", "%G overflow prints INF");
   end Test_Arithmetic_Safety;

   --  UTF-8: string functions count and index by codepoint, not byte. The
   --  multibyte literals are built from explicit bytes so the source encoding
   --  cannot fold them into Latin-1 single characters.
   procedure Test_Utf8 (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Eacute : constant String := Character'Val (16#C3#) & Character'Val (16#A9#);   --  é
      Ri     : constant String :=                                                    --  日
        Character'Val (16#E6#) & Character'Val (16#97#) & Character'Val (16#A5#);
   begin
      Assert (Awk ("BEGIN { print length(" & DQ & "caf" & Eacute & DQ & ") }") = "4" & LF,
              "length counts codepoints, not bytes");
      Assert (Awk ("BEGIN { print length(" & DQ & Ri & Ri & Ri & DQ & ") }") = "3" & LF,
              "length counts multibyte CJK codepoints");
      Assert (Awk ("BEGIN { print substr(" & DQ & "h" & Eacute & "llo" & DQ & ", 2, 1) }")
              = Eacute & LF, "substr slices by codepoint position");
      Assert (Awk ("BEGIN { print index(" & DQ & "x" & Eacute & "y" & DQ & ", " & DQ & "y" & DQ & ") }")
              = "3" & LF, "index reports a codepoint position");
      Assert (Awk ("BEGIN { n = split(" & DQ & "a" & Eacute & "b" & DQ & ", w, " & DQ & DQ
              & "); print n, w[2] }") = "3 " & Eacute & LF, "empty-FS split yields whole codepoints");
      Assert (Awk ("BEGIN { if (match(" & DQ & "z" & Eacute & "z" & DQ & ", " & DQ & Eacute & DQ
              & ")) print RSTART, RLENGTH }") = "2 1" & LF, "match reports codepoint RSTART/RLENGTH");
      Assert (Awk ("BEGIN { printf " & DQ & "%c" & DQ & ", 233 }") = Eacute,
              "printf %c encodes a code point as UTF-8");
      Assert (Awk ("BEGIN { printf " & DQ & "%c" & DQ & ", 26085 }") = Ri,
              "printf %c encodes a multibyte code point");
   end Test_Utf8;

   --  Regex matches by code point (via the UTF-8-mode regexp engine): ".",
   --  quantifiers, and classes span whole code points, not bytes.
   procedure Test_Utf8_Regex (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Eacute : constant String := Character'Val (16#C3#) & Character'Val (16#A9#);   --  é
      Alpha  : constant String := Character'Val (16#CE#) & Character'Val (16#B1#);   --  α
      Del : constant String := Character'Val (16#CE#) & Character'Val (16#B4#);   --  δ
      Omega  : constant String := Character'Val (16#CF#) & Character'Val (16#89#);   --  ω
   begin
      --  "." matches one code point, so gsub over "café" replaces 4, not 5.
      Assert (Awk ("BEGIN { s = " & DQ & "caf" & Eacute & DQ & "; gsub(/./, " & DQ & "X" & DQ
              & ", s); print s }") = "XXXX" & LF, "gsub(/./ ) counts code points");
      --  A negated class matches a whole multibyte code point.
      Assert (Awk ("BEGIN { s = " & DQ & "a" & Eacute & "b" & DQ & "; gsub(/[^a]/, " & DQ & "_"
              & DQ & ", s); print s }") = "a__" & LF, "gsub(/[^a]/ ) over code points");
      --  A positive code-point range: [α-ω] matches δ but not an ASCII letter.
      Assert (Awk ("BEGIN { if (" & DQ & Del & DQ & " ~ /[" & Alpha & "-" & Omega & "]/) "
              & "print " & DQ & "yes" & DQ & " }") = "yes" & LF, "regex [greek-range] matches delta");
      Assert (Awk ("BEGIN { if (" & DQ & "x" & DQ & " ~ /[" & Alpha & "-" & Omega & "]/) "
              & "print " & DQ & "no" & DQ & "; else print " & DQ & "ok" & DQ & " }") = "ok" & LF,
              "regex [greek-range] excludes ascii");
      --  A multibyte literal in a regex matches its own code point.
      Assert (Awk ("BEGIN { if (" & DQ & "z" & Eacute & DQ & " ~ /" & Eacute & "/) "
              & "print " & DQ & "hit" & DQ & " }") = "hit" & LF, "regex multibyte literal");
   end Test_Utf8_Regex;

   type Awklib_Test_Case is new AUnit.Test_Cases.Test_Case with null record;

   overriding function Name (T : Awklib_Test_Case) return AUnit.Message_String;
   overriding procedure Register_Tests (T : in out Awklib_Test_Case);

   overriding function Name (T : Awklib_Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("awklib");
   end Name;

   overriding procedure Register_Tests (T : in out Awklib_Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Test_Begin'Access, "BEGIN runs before input");
      Register_Routine (T, Test_Whole_Record'Access, "print echoes the whole record");
      Register_Routine (T, Test_Field'Access, "fields are addressable by position");
      Register_Routine (T, Test_NF'Access, "NF counts fields");
      Register_Routine (T, Test_NR'Access, "NR counts records");
      Register_Routine (T, Test_Accumulate'Access, "arithmetic accumulates across records");
      Register_Routine (T, Test_Regex_Pattern'Access, "a regex pattern selects records");
      Register_Routine (T, Test_Comparison_Pattern'Access, "a relational pattern filters");
      Register_Routine (T, Test_Field_Separator'Access, "FS chooses the field separator");
      Register_Routine (T, Test_Output_Field_Separator'Access, "OFS joins printed fields");
      Register_Routine (T, Test_Printf'Access, "printf formats");
      Register_Routine (T, Test_Length'Access, "length");
      Register_Routine (T, Test_Substr'Access, "substr");
      Register_Routine (T, Test_Toupper'Access, "toupper");
      Register_Routine (T, Test_Gsub'Access, "gsub replaces and counts");
      Register_Routine (T, Test_Seeded_Variable'Access, "seeded variables are strnums");
      Register_Routine (T, Test_Exit_Code'Access, "exit N sets the exit code");
      Register_Routine (T, Test_Parse_Error'Access, "a parse failure is reported");
      Register_Routine (T, Test_Getline_Var'Access, "getline var reads the next record");
      Register_Routine (T, Test_Getline_Plain'Access, "plain getline advances the record");
      Register_Routine (T, Test_RS_Char'Access, "a single-character RS splits records");
      Register_Routine (T, Test_RS_Paragraph'Access, "RS = empty is paragraph mode");
      Register_Routine (T, Test_OFMT'Access, "OFMT formats printed numbers");
      Register_Routine (T, Test_Printf_Sci'Access, "printf %e/%E are C-style");
      Register_Routine (T, Test_Printf_G'Access, "printf %g is C-style");
      Register_Routine (T, Test_Printf_F0'Access, "printf %.0f rounds");
      Register_Routine (T, Test_Control_Flow'Access, "control flow (if/while/for/next)");
      Register_Routine (T, Test_Math'Access, "math builtins");
      Register_Routine (T, Test_Rand'Access, "rand/srand");
      Register_Routine (T, Test_Arrays'Access, "arrays, for-in, delete, in, SUBSEP");
      Register_Routine (T, Test_Functions'Access, "user functions, recursion, locals");
      Register_Routine (T, Test_Operators'Access, "operators");
      Register_Routine (T, Test_Fields'Access, "field assignment and $0 rebuilding");
      Register_Routine (T, Test_Field_Splitting'Access, "FS variants");
      Register_Routine (T, Test_String_Functions'Access, "split/index/match/sub/tolower/sprintf");
      Register_Routine (T, Test_Getline_File'Access, "getline < file");
      Register_Routine (T, Test_Multi_File'Access, "multi-file FILENAME/FNR/NR");
      Register_Routine (T, Test_Streaming_Input'Access, "streaming input API");
      Register_Routine
        (T, Test_Streaming_Getline_From_Begin'Access,
         "streaming getline from BEGIN");
      Register_Routine
        (T, Test_Streaming_Redirection'Access,
         "streaming redirection API");
      Register_Routine
        (T, Test_Text_Streaming_Splits_Records'Access,
         "text streaming record splitting");
      Register_Routine
        (T, Test_Text_Streaming_Uses_Begin_RS'Access,
         "text streaming BEGIN RS");
      Register_Routine (T, Test_Printf_Flags'Access, "printf flags, width, %o/%x/%c");
      Register_Routine (T, Test_Coercion'Access, "strnum coercion and substr clamping");
      Register_Routine (T, Test_Escapes'Access, "string escapes");
      Register_Routine (T, Test_CONVFMT'Access, "CONVFMT governs implicit number-to-string");
      Register_Routine (T, Test_Redirect'Access, "output redirection to a file");
      Register_Routine (T, Test_Reentrancy'Access, "concurrent runs do not share state");
      Register_Routine (T, Test_Argv'Access, "ARGV/ARGC from Arguments or Input_Files");
      Register_Routine (T, Test_Arithmetic_Safety'Access, "div-by-zero errors; overflow prints inf/nan");
      Register_Routine (T, Test_Utf8'Access, "string functions are UTF-8 codepoint-aware");
      Register_Routine (T, Test_Utf8_Regex'Access, "regex matches by UTF-8 code point");
   end Register_Tests;

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite := new AUnit.Test_Suites.Test_Suite;
   begin
      Result.Add_Test (AUnit.Test_Cases.Test_Case_Access'(new Awklib_Test_Case));
      return Result;
   end Suite;

end Awklib_Suite;

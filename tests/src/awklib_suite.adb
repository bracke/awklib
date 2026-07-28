with AUnit;
with AUnit.Assertions;
with AUnit.Test_Cases;

with Ada.Strings.Unbounded;

with Awklib.Interpreter;

package body Awklib_Suite is
   use AUnit.Assertions;

   package I renames Awklib.Interpreter;
   package U renames Ada.Strings.Unbounded;
   use type I.Run_Status;

   LF : constant String := [1 => ASCII.LF];

   --  Run PROGRAM over INPUT with no seeded variables and return captured stdout.
   function Awk (Program : String; Input : String := "") return String is
      Empty     : I.Assignment_Vectors.Vector;
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
         Message        => Message);
      return U.To_String (Output);
   end Awk;

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
         Message        => Message);
      Assert (Status = I.Run_Ok, "seeded run succeeds");
      Assert (U.To_String (Output) = "8" & LF, "a seeded variable is a numeric strnum");
   end Test_Seeded_Variable;

   procedure Test_Exit_Code (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
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
         Message        => Message);
      Assert (Status = I.Run_Ok, "exit is a clean run, not an error");
      Assert (Exit_Code = 3, "exit N is reported as the exit code");
   end Test_Exit_Code;

   procedure Test_Parse_Error (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Empty     : I.Assignment_Vectors.Vector;
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
         Message        => Message);
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
   end Register_Tests;

   function Suite return AUnit.Test_Suites.Access_Test_Suite is
      Result : constant AUnit.Test_Suites.Access_Test_Suite := new AUnit.Test_Suites.Test_Suite;
   begin
      Result.Add_Test (AUnit.Test_Cases.Test_Case_Access'(new Awklib_Test_Case));
      return Result;
   end Suite;

end Awklib_Suite;

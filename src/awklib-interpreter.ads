with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Awklib.Interpreter is
   --  Runs an AWK program over an in-memory input and captures its standard
   --  output. Not reentrant: interpreter state is process-global.

   package U renames Ada.Strings.Unbounded;

   type Var_Assignment is record
      Name  : U.Unbounded_String;
      Value : U.Unbounded_String;
   end record;

   package Assignment_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Var_Assignment);

   type Run_Status is (Run_Ok, Run_Error);

   procedure Run
     (Program_Source : String;
      Input          : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Filename       : String;
      Output         : out U.Unbounded_String;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String);
   --  Parse and run Program_Source. Input is the main record stream (split by
   --  RS, default newline). Assignments seed variables as strnums (like -v);
   --  Environment seeds ENVIRON[]. Filename sets FILENAME. Standard output is
   --  captured in Output. Exit_Code carries any `exit N`. On Run_Error, Message
   --  describes a lex/parse/runtime failure.

end Awklib.Interpreter;

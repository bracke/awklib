with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

package Awklib.Interpreter is
   --  Runs an AWK program over an in-memory input and captures its standard
   --  output. Reentrant: all interpreter state is local to a Run call, so
   --  independent programs may run concurrently on separate tasks.

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
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Input_Files    : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector);
   --  Files provides the content of named files for `getline < name`: each
   --  entry maps a filename to its full text. A getline from a name absent
   --  here returns -1 (open failure), as AWK would for a missing file.
   --
   --  Input_Files, when non-empty, supplies the main input as an ordered list
   --  of (FILENAME, content) pairs instead of the single Input string: FILENAME
   --  and FNR track each file the way multi-file AWK does, while NR runs
   --  continuously. When empty, Input is treated as one file named Filename.
   --  Parse and run Program_Source. Input is the main record stream (split by
   --  RS, default newline). Assignments seed variables as strnums (like -v);
   --  Environment seeds ENVIRON[]. Filename sets FILENAME. Standard output is
   --  captured in Output. Exit_Code carries any `exit N`. On Run_Error, Message
   --  describes a lex/parse/runtime failure.

end Awklib.Interpreter;

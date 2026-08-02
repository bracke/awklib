with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with System;

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

   --  A plain ordered list of strings, used to supply the program arguments
   --  that seed ARGV/ARGC.
   package String_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => U.Unbounded_String, "=" => U."=");

   type Runtime_Operand_Kind is (Input_Operand, Assignment_Operand);

   type Runtime_Operand is record
      Kind  : Runtime_Operand_Kind := Input_Operand;
      Text  : U.Unbounded_String;
      Name  : U.Unbounded_String;
      Value : U.Unbounded_String;
   end record;

   package Runtime_Operand_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Runtime_Operand);

   type Run_Status is (Run_Ok, Run_Error);

   type Record_Reader is access procedure
     (User_Data    : System.Address;
      Filename     : out U.Unbounded_String;
      Record_Text  : out U.Unbounded_String;
      End_Of_Input : out Boolean);
   --  Supplies one main-input record per call. Filename is the AWK-visible
   --  FILENAME for the returned record. Consecutive records with the same
   --  Filename belong to the same FNR sequence; a changed Filename resets FNR.

   type Output_Writer is access procedure
     (User_Data : System.Address;
      Text      : String);
   --  Receives AWK standard output exactly as produced.

   type Text_Reader is access procedure
     (User_Data    : System.Address;
      Filename     : out U.Unbounded_String;
      Text         : out U.Unbounded_String;
      End_Of_Input : out Boolean);
   --  Supplies main-input text chunks. Filename is the AWK-visible FILENAME for
   --  the returned chunk. Chunks for a file must be contiguous; awklib owns AWK
   --  record splitting across chunk boundaries.

   type Redirection_Writer is access procedure
     (User_Data : System.Address;
      Name : String;
      Text : String;
      Append : Boolean;
      Truncate : Boolean);
   --  Receives AWK redirected output exactly as produced. Truncate is True for
   --  the first effective ">" to a target in a run. Append is True for ">>" and
   --  for later writes to an already-open target.

   type Command_Reader is access procedure
     (User_Data : System.Address;
      Command   : String;
      Text      : out U.Unbounded_String;
      Available : out Boolean);
   --  Supplies stdout text for `command | getline` after the command expression
   --  has been evaluated. awklib does not spawn processes itself; embedders that
   --  want live command execution provide it here.

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
      Output_Files   : out Assignment_Vectors.Vector;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Input_Files    : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null);
   --  Files provides the content of named files for `getline < name`: each
   --  entry maps a filename to its full text. A getline from a name absent
   --  here returns -1 (open failure), as AWK would for a missing file.
   --  Commands provides deterministic output for `command | getline`: each
   --  entry maps a command string to its full stdout text. Read_Command, when
   --  non-null, is called for command strings absent from Commands. If neither
   --  source provides the command, getline returns -1. awklib does not spawn
   --  processes itself.
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
   --
   --  Arguments seeds ARGV/ARGC the way a command line would: ARGV[0] is "awk",
   --  ARGV[1 .. n] are the supplied strings, and ARGC is n + 1. When Arguments is
   --  empty, ARGV/ARGC are derived from the Input_Files names instead, matching
   --  awk (whose ARGV is the input files it was given). ARGV/ARGC are readable by
   --  the program but do not drive input -- records still come from Input_Files,
   --  so mutating ARGV/ARGC in BEGIN does not change what is read.
   --
   --  Output_Files captures redirected output in memory instead of touching the
   --  filesystem: every `print > name` / `print >> name` / `printf > name`
   --  target becomes one (name, final-content) entry, in first-write order, so a
   --  library consumer captures redirected files the same hermetic way it feeds
   --  input. Nothing is written to disk; a front end that wants real files writes
   --  these entries out itself.

   procedure Run_Streaming
     (Program_Source : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Initial_Filename : String;
      Read_Record    : not null Record_Reader;
      Write_Output   : not null Output_Writer;
      Write_Redirection : Redirection_Writer;
      User_Data      : System.Address := System.Null_Address;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null);
   --  Run with caller-provided streaming main input and live output callbacks.
   --  This API does not preload main input, standard output, or redirected
   --  output. AWK source, auxiliary getline file contents supplied through
   --  Files, and interpreter state are still held in memory.

   procedure Run_Text_Streaming
     (Program_Source : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Initial_Filename : String;
      Read_Text      : not null Text_Reader;
      Write_Output   : not null Output_Writer;
      Write_Redirection : Redirection_Writer;
      User_Data      : System.Address := System.Null_Address;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Arguments      : String_Vectors.Vector := String_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null);
   --  Run with caller-provided text chunks and live output callbacks. Unlike
   --  Run_Streaming, the caller does not pre-split AWK records; record splitting
   --  according to RS remains inside awklib.

   type Operand_Text_Reader is access procedure
     (User_Data    : System.Address;
      Operand_Index : Positive;
      Filename     : out U.Unbounded_String;
      Text         : out U.Unbounded_String;
      End_Of_Input : out Boolean);

   procedure Run_Text_Streaming_With_Operands
     (Program_Source : String;
      Assignments    : Assignment_Vectors.Vector;
      Environment    : Assignment_Vectors.Vector;
      Initial_Filename : String;
      Operands       : Runtime_Operand_Vectors.Vector;
      Read_Text      : not null Operand_Text_Reader;
      Write_Output   : not null Output_Writer;
      Write_Redirection : Redirection_Writer;
      User_Data      : System.Address := System.Null_Address;
      Exit_Code      : out Integer;
      Status         : out Run_Status;
      Message        : out U.Unbounded_String;
      Files          : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Commands       : Assignment_Vectors.Vector := Assignment_Vectors.Empty_Vector;
      Read_Command   : Command_Reader := null);
   --  Run with an AWK command-line operand sequence. Input operands are read
   --  lazily through Read_Text, and assignment operands are applied by awklib at
   --  their command-line positions: after BEGIN, before the following input, and
   --  before END when trailing assignments remain. ARGV/ARGC are populated from
   --  Operands exactly as supplied.

end Awklib.Interpreter;

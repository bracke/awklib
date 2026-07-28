with Ada.Strings.Unbounded;
with Awklib.Ast;

package Awklib.Parser is
   --  Recursive-descent parser producing an Awklib.Ast.Program.
   --
   --  Reentrant: all parser state is local to a Parse call.

   package U renames Ada.Strings.Unbounded;

   type Result_Status is (Ok, Parse_Error);

   procedure Parse
     (Source  : String;
      Prog    : out Awklib.Ast.Program;
      Status  : out Result_Status;
      Message : out U.Unbounded_String);
   --  Lex and parse Source. On Parse_Error, Message names the offending line
   --  and token and Prog is left empty.

end Awklib.Parser;

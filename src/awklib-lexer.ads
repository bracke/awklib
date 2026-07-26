with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Awklib.Values;

package Awklib.Lexer is
   --  Tokenizes AWK source into a flat token vector for the parser.
   --
   --  Two AWK-specific subtleties are resolved here:
   --    * `/` is a regex delimiter or the division operator depending on what
   --      the previous significant token was (a value-ending token means
   --      division).
   --    * physical newlines become Tok_Newline tokens (statement terminators);
   --      a backslash immediately before a newline is a line continuation and
   --      produces no token.

   package U renames Ada.Strings.Unbounded;

   type Token_Kind is
     (Tok_Number, Tok_String, Tok_Ere,
      Tok_Name,        --  identifier not directly followed by '('
      Tok_Func_Name,   --  identifier directly followed by '(' (a call)
      --  Keywords
      Tok_Begin, Tok_End, Tok_Function, Tok_If, Tok_Else, Tok_While, Tok_For,
      Tok_Do, Tok_Break, Tok_Continue, Tok_Next, Tok_Nextfile, Tok_Exit,
      Tok_Return, Tok_Delete, Tok_In, Tok_Getline, Tok_Print, Tok_Printf,
      --  Assignment operators
      Tok_Assign, Tok_Add_Assign, Tok_Sub_Assign, Tok_Mul_Assign,
      Tok_Div_Assign, Tok_Mod_Assign, Tok_Pow_Assign,
      --  Other operators
      Tok_Or, Tok_And, Tok_Eq, Tok_Ne, Tok_Lt, Tok_Le, Tok_Gt, Tok_Ge,
      Tok_Not, Tok_Match, Tok_No_Match,
      Tok_Plus, Tok_Minus, Tok_Star, Tok_Slash, Tok_Percent, Tok_Caret,
      Tok_Incr, Tok_Decr, Tok_Question, Tok_Colon, Tok_Dollar,
      Tok_Lparen, Tok_Rparen, Tok_Lbrace, Tok_Rbrace, Tok_Lbracket,
      Tok_Rbracket, Tok_Semicolon, Tok_Comma, Tok_Newline,
      Tok_Append,   --  >>
      Tok_Pipe,     --  |
      Tok_Eof);

   type Token is record
      Kind : Token_Kind := Tok_Eof;
      Text : U.Unbounded_String;      --  source text for Name/String/Ere
      Num  : Awklib.Values.Number := 0.0;
      Line : Positive := 1;
   end record;

   package Token_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Token);

   type Result_Status is (Ok, Lex_Error);

   procedure Tokenize
     (Source  : String;
      Tokens  : out Token_Vectors.Vector;
      Status  : out Result_Status;
      Message : out U.Unbounded_String);
   --  Produce the token stream for Source. A trailing Tok_Eof is always
   --  appended. On Lex_Error, Message describes the failure and the token
   --  vector holds whatever was scanned before it.

end Awklib.Lexer;

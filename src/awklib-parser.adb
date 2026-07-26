with Awklib.Lexer;
with Awklib.Values;

package body Awklib.Parser is

   use Awklib.Ast;
   package L renames Awklib.Lexer;
   use type L.Token_Kind;
   use type L.Result_Status;

   --  Parser state (single-threaded; not reentrant).
   Toks       : L.Token_Vectors.Vector;
   Pos        : Positive := 1;
   Failed     : Boolean := False;
   Err_Msg    : U.Unbounded_String;
   Print_Mode : Boolean := False;   --  suppress '>' as comparison in print args

   --  Forward declarations -----------------------------------------------------
   function Parse_Expr return Expr_Access;
   function Parse_Ternary return Expr_Access;
   function Parse_Or return Expr_Access;
   function Parse_And return Expr_Access;
   function Parse_In return Expr_Access;
   function Parse_Match return Expr_Access;
   function Parse_Comparison return Expr_Access;
   function Parse_Concat return Expr_Access;
   function Parse_Add return Expr_Access;
   function Parse_Mul return Expr_Access;
   function Parse_Unary return Expr_Access;
   function Parse_Pow return Expr_Access;
   function Parse_Postfix return Expr_Access;
   function Parse_Primary return Expr_Access;
   function Parse_Getline return Expr_Access;
   function Parse_Stmt return Stmt_Access;
   function Parse_Block return Stmt_Access;

   --  Token helpers ------------------------------------------------------------
   function Cur return L.Token is (Toks (Pos));
   function Kind return L.Token_Kind is (Toks (Pos).Kind);

   function Peek (N : Natural) return L.Token_Kind is
     (if Pos + N <= Toks.Last_Index then Toks (Pos + N).Kind else L.Tok_Eof);

   procedure Advance is
   begin
      if Pos < Toks.Last_Index then
         Pos := Pos + 1;
      end if;
   end Advance;

   function At_Kind (K : L.Token_Kind) return Boolean is (Kind = K);

   procedure Error (Msg : String) is
   begin
      if not Failed then
         Failed := True;
         Err_Msg := U.To_Unbounded_String
           ("line" & Positive'Image (Cur.Line) & ": " & Msg);
      end if;
   end Error;

   procedure Expect (K : L.Token_Kind; What : String) is
   begin
      if At_Kind (K) then
         Advance;
      else
         Error ("expected " & What);
      end if;
   end Expect;

   procedure Skip_Newlines is
   begin
      while At_Kind (L.Tok_Newline) loop
         Advance;
      end loop;
   end Skip_Newlines;

   procedure Skip_Terminators is
   begin
      while At_Kind (L.Tok_Newline) or else At_Kind (L.Tok_Semicolon) loop
         Advance;
      end loop;
   end Skip_Terminators;

   --  Node constructors --------------------------------------------------------
   function NA (E : Expr) return Expr_Access is (new Expr'(E));

   function Is_Lvalue (E : Expr_Access) return Boolean is
     (E /= null and then E.Kind in E_Var | E_Field | E_Subscript);

   function Starts_Value (K : L.Token_Kind) return Boolean is
     (K in L.Tok_Number | L.Tok_String | L.Tok_Ere | L.Tok_Name
         | L.Tok_Func_Name | L.Tok_Dollar | L.Tok_Not | L.Tok_Lparen
         | L.Tok_Incr | L.Tok_Decr | L.Tok_Getline);

   function Builtin_Of (Name : String; Found : out Boolean) return Builtin_Id is
   begin
      Found := True;
      if Name = "length" then return B_Length;
      elsif Name = "substr" then return B_Substr;
      elsif Name = "index" then return B_Index;
      elsif Name = "split" then return B_Split;
      elsif Name = "sub" then return B_Sub;
      elsif Name = "gsub" then return B_Gsub;
      elsif Name = "match" then return B_Match;
      elsif Name = "sprintf" then return B_Sprintf;
      elsif Name = "int" then return B_Int;
      elsif Name = "sin" then return B_Sin;
      elsif Name = "cos" then return B_Cos;
      elsif Name = "atan2" then return B_Atan2;
      elsif Name = "exp" then return B_Exp;
      elsif Name = "log" then return B_Log;
      elsif Name = "sqrt" then return B_Sqrt;
      elsif Name = "rand" then return B_Rand;
      elsif Name = "srand" then return B_Srand;
      elsif Name = "tolower" then return B_Tolower;
      elsif Name = "toupper" then return B_Toupper;
      elsif Name = "system" then return B_System;
      elsif Name = "close" then return B_Close;
      elsif Name = "fflush" then return B_Fflush;
      else
         Found := False;
         return B_Length;
      end if;
   end Builtin_Of;

   --  Comma-separated argument list up to a closing ')'.
   function Parse_Arg_List return Expr_Vectors.Vector is
      Args : Expr_Vectors.Vector;
   begin
      if not At_Kind (L.Tok_Rparen) then
         Args.Append (Parse_Expr);
         while At_Kind (L.Tok_Comma) loop
            Advance;
            Skip_Newlines;
            Args.Append (Parse_Expr);
         end loop;
      end if;
      return Args;
   end Parse_Arg_List;

   --  Expression grammar -------------------------------------------------------

   function Parse_Expr return Expr_Access is
      Left : constant Expr_Access := Parse_Ternary;
      A_Op : Assign_Op;
   begin
      if Is_Lvalue (Left) then
         case Kind is
            when L.Tok_Assign     => A_Op := As_Set;
            when L.Tok_Add_Assign => A_Op := As_Add;
            when L.Tok_Sub_Assign => A_Op := As_Sub;
            when L.Tok_Mul_Assign => A_Op := As_Mul;
            when L.Tok_Div_Assign => A_Op := As_Div;
            when L.Tok_Mod_Assign => A_Op := As_Mod;
            when L.Tok_Pow_Assign => A_Op := As_Pow;
            when others           => return Left;
         end case;
         Advance;
         Skip_Newlines;
         return NA ((Kind => E_Assign, Line => Left.Line,
                     Target => Left, A_Op => A_Op, Rhs => Parse_Expr));
      end if;
      return Left;
   end Parse_Expr;

   function Parse_Ternary return Expr_Access is
      C : constant Expr_Access := Parse_Or;
      T, F : Expr_Access;
   begin
      if At_Kind (L.Tok_Question) then
         Advance; Skip_Newlines;
         T := Parse_Expr;
         Expect (L.Tok_Colon, "':'"); Skip_Newlines;
         F := Parse_Expr;
         return NA ((Kind => E_Ternary, Line => C.Line,
                     Cond => C, T_Expr => T, F_Expr => F));
      end if;
      return C;
   end Parse_Ternary;

   function Parse_Or return Expr_Access is
      Left : Expr_Access := Parse_And;
   begin
      while At_Kind (L.Tok_Or) loop
         Advance; Skip_Newlines;
         Left := NA ((Kind => E_Or, Line => Left.Line,
                      Lg_L => Left, Lg_R => Parse_And));
      end loop;
      return Left;
   end Parse_Or;

   function Parse_And return Expr_Access is
      Left : Expr_Access := Parse_In;
   begin
      while At_Kind (L.Tok_And) loop
         Advance; Skip_Newlines;
         Left := NA ((Kind => E_And, Line => Left.Line,
                      Lg_L => Left, Lg_R => Parse_In));
      end loop;
      return Left;
   end Parse_And;

   function Parse_In return Expr_Access is
      Left : Expr_Access := Parse_Match;
      Subs : Expr_Vectors.Vector;
   begin
      while At_Kind (L.Tok_In) loop
         Advance;
         if not At_Kind (L.Tok_Name) then
            Error ("expected array name after 'in'");
            return Left;
         end if;
         Subs.Clear;
         Subs.Append (Left);
         declare
            Arr : constant U.Unbounded_String := Cur.Text;
         begin
            Advance;
            Left := NA ((Kind => E_In, Line => Left.Line,
                         In_Subs => Subs, In_Arr => Arr));
         end;
      end loop;
      return Left;
   end Parse_In;

   function Parse_Match return Expr_Access is
      Left : Expr_Access := Parse_Comparison;
      Neg  : Boolean;
   begin
      while At_Kind (L.Tok_Match) or else At_Kind (L.Tok_No_Match) loop
         Neg := At_Kind (L.Tok_No_Match);
         Advance; Skip_Newlines;
         Left := NA ((Kind => E_Match, Line => Left.Line,
                      M_Neg => Neg, M_L => Left, M_R => Parse_Comparison));
      end loop;
      return Left;
   end Parse_Match;

   function Parse_Comparison return Expr_Access is
      Left : Expr_Access := Parse_Concat;
      Op   : Bin_Op;
   begin
      loop
         case Kind is
            when L.Tok_Lt => Op := Op_Lt;
            when L.Tok_Le => Op := Op_Le;
            when L.Tok_Ge => Op := Op_Ge;
            when L.Tok_Eq => Op := Op_Eq;
            when L.Tok_Ne => Op := Op_Ne;
            when L.Tok_Gt =>
               exit when Print_Mode;   --  '>' is a redirect here
               Op := Op_Gt;
            when others => exit;
         end case;
         Advance; Skip_Newlines;
         Left := NA ((Kind => E_Binary, Line => Left.Line,
                      B_Op => Op, L => Left, R => Parse_Concat));
      end loop;
      return Left;
   end Parse_Comparison;

   function Parse_Concat return Expr_Access is
      Left : Expr_Access := Parse_Add;
   begin
      while Starts_Value (Kind)
        and then not (Print_Mode and then Kind = L.Tok_Getline)
      loop
         Left := NA ((Kind => E_Concat, Line => Left.Line,
                      C_L => Left, C_R => Parse_Add));
      end loop;
      return Left;
   end Parse_Concat;

   function Parse_Add return Expr_Access is
      Left : Expr_Access := Parse_Mul;
      Op   : Bin_Op;
   begin
      while At_Kind (L.Tok_Plus) or else At_Kind (L.Tok_Minus) loop
         Op := (if At_Kind (L.Tok_Plus) then Op_Add else Op_Sub);
         Advance; Skip_Newlines;
         Left := NA ((Kind => E_Binary, Line => Left.Line,
                      B_Op => Op, L => Left, R => Parse_Mul));
      end loop;
      return Left;
   end Parse_Add;

   function Parse_Mul return Expr_Access is
      Left : Expr_Access := Parse_Unary;
      Op   : Bin_Op;
   begin
      while At_Kind (L.Tok_Star) or else At_Kind (L.Tok_Slash)
        or else At_Kind (L.Tok_Percent)
      loop
         Op := (if At_Kind (L.Tok_Star) then Op_Mul
                elsif At_Kind (L.Tok_Slash) then Op_Div else Op_Mod);
         Advance; Skip_Newlines;
         Left := NA ((Kind => E_Binary, Line => Left.Line,
                      B_Op => Op, L => Left, R => Parse_Unary));
      end loop;
      return Left;
   end Parse_Mul;

   function Parse_Unary return Expr_Access is
      Op : Unary_Op;
   begin
      if At_Kind (L.Tok_Not) or else At_Kind (L.Tok_Minus)
        or else At_Kind (L.Tok_Plus)
      then
         Op := (if At_Kind (L.Tok_Not) then Un_Not
                elsif At_Kind (L.Tok_Minus) then Un_Neg else Un_Pos);
         Advance;
         return NA ((Kind => E_Unary, Line => Cur.Line,
                     U_Op => Op, Operand => Parse_Unary));
      end if;
      return Parse_Pow;
   end Parse_Unary;

   function Parse_Pow return Expr_Access is
      Base : constant Expr_Access := Parse_Postfix;
   begin
      if At_Kind (L.Tok_Caret) then
         Advance; Skip_Newlines;
         return NA ((Kind => E_Binary, Line => Base.Line,
                     B_Op => Op_Pow, L => Base, R => Parse_Unary));
      end if;
      return Base;
   end Parse_Pow;

   function Parse_Postfix return Expr_Access is
      E : Expr_Access := Parse_Primary;
   begin
      while (At_Kind (L.Tok_Incr) or else At_Kind (L.Tok_Decr))
        and then Is_Lvalue (E)
      loop
         E := NA ((Kind => E_Incr_Decr, Line => E.Line,
                   Is_Incr => At_Kind (L.Tok_Incr), Is_Pre => False, Lvalue => E));
         Advance;
      end loop;
      return E;
   end Parse_Postfix;

   --  Parse an lvalue used as a getline target: NAME[subs] or $field.
   function Parse_Lvalue return Expr_Access is
   begin
      if At_Kind (L.Tok_Dollar) then
         Advance;
         return NA ((Kind => E_Field, Line => Cur.Line, Fld => Parse_Primary));
      elsif At_Kind (L.Tok_Name) then
         declare
            Name : constant U.Unbounded_String := Cur.Text;
            Subs : Expr_Vectors.Vector;
         begin
            Advance;
            if At_Kind (L.Tok_Lbracket) then
               Advance;
               Subs.Append (Parse_Expr);
               while At_Kind (L.Tok_Comma) loop
                  Advance; Subs.Append (Parse_Expr);
               end loop;
               Expect (L.Tok_Rbracket, "']'");
               return NA ((Kind => E_Subscript, Line => Cur.Line,
                           Arr_Name => Name, Subs => Subs));
            end if;
            return NA ((Kind => E_Var, Line => Cur.Line, Var_Name => Name));
         end;
      end if;
      return null;
   end Parse_Lvalue;

   function Parse_Getline return Expr_Access is
      Var : Expr_Access := null;
      Src : Getline_Source := G_Main;
      Arg : Expr_Access := null;
   begin
      Advance;   --  'getline'
      if At_Kind (L.Tok_Name) or else At_Kind (L.Tok_Dollar) then
         Var := Parse_Lvalue;
      end if;
      if At_Kind (L.Tok_Lt) then
         Advance;
         Src := G_File;
         Arg := Parse_Concat;
      end if;
      return NA ((Kind => E_Getline, Line => Cur.Line,
                  GL_Var => Var, GL_Source => Src, GL_Arg => Arg));
   end Parse_Getline;

   function Parse_Primary return Expr_Access is
      Saved_Print : Boolean;
   begin
      case Kind is
         when L.Tok_Number =>
            declare
               N : constant Values.Number := Cur.Num;
            begin
               Advance;
               return NA ((Kind => E_Num, Line => Cur.Line, Num => N));
            end;

         when L.Tok_String =>
            declare
               S : constant U.Unbounded_String := Cur.Text;
            begin
               Advance;
               return NA ((Kind => E_Str, Line => Cur.Line, Str => S));
            end;

         when L.Tok_Ere =>
            declare
               R : constant U.Unbounded_String := Cur.Text;
            begin
               Advance;
               return NA ((Kind => E_Regex, Line => Cur.Line, Rx => R));
            end;

         when L.Tok_Dollar =>
            Advance;
            return NA ((Kind => E_Field, Line => Cur.Line, Fld => Parse_Primary));

         when L.Tok_Incr | L.Tok_Decr =>
            declare
               Inc : constant Boolean := At_Kind (L.Tok_Incr);
            begin
               Advance;
               return NA ((Kind => E_Incr_Decr, Line => Cur.Line,
                           Is_Incr => Inc, Is_Pre => True, Lvalue => Parse_Primary));
            end;

         when L.Tok_Getline =>
            return Parse_Getline;

         when L.Tok_Name =>
            declare
               Name  : constant U.Unbounded_String := Cur.Text;
               Found : Boolean;
               Bid   : constant Builtin_Id := Builtin_Of (U.To_String (Name), Found);
               Subs  : Expr_Vectors.Vector;
            begin
               Advance;
               if At_Kind (L.Tok_Lbracket) then
                  Advance;
                  Subs.Append (Parse_Expr);
                  while At_Kind (L.Tok_Comma) loop
                     Advance; Subs.Append (Parse_Expr);
                  end loop;
                  Expect (L.Tok_Rbracket, "']'");
                  return NA ((Kind => E_Subscript, Line => Cur.Line,
                              Arr_Name => Name, Subs => Subs));
               elsif Found and then Bid = B_Length then
                  --  bare 'length' == length($0)
                  return NA ((Kind => E_Builtin, Line => Cur.Line,
                              B_Id => B_Length, B_Args => Expr_Vectors.Empty_Vector));
               else
                  return NA ((Kind => E_Var, Line => Cur.Line, Var_Name => Name));
               end if;
            end;

         when L.Tok_Func_Name =>
            declare
               Name  : constant U.Unbounded_String := Cur.Text;
               Found : Boolean;
               Bid   : constant Builtin_Id := Builtin_Of (U.To_String (Name), Found);
               Args  : Expr_Vectors.Vector;
            begin
               Advance;
               Expect (L.Tok_Lparen, "'('");
               Args := Parse_Arg_List;
               Expect (L.Tok_Rparen, "')'");
               if Found then
                  return NA ((Kind => E_Builtin, Line => Cur.Line,
                              B_Id => Bid, B_Args => Args));
               else
                  return NA ((Kind => E_Call, Line => Cur.Line,
                              Fn_Name => Name, Args => Args));
               end if;
            end;

         when L.Tok_Lparen =>
            Advance;
            Saved_Print := Print_Mode;
            Print_Mode := False;
            declare
               First : constant Expr_Access := Parse_Expr;
               List  : Expr_Vectors.Vector;
            begin
               if At_Kind (L.Tok_Comma) then
                  List.Append (First);
                  while At_Kind (L.Tok_Comma) loop
                     Advance; Skip_Newlines;
                     List.Append (Parse_Expr);
                  end loop;
                  Expect (L.Tok_Rparen, "')'");
                  Print_Mode := Saved_Print;
                  if At_Kind (L.Tok_In) then
                     Advance;
                     declare
                        Arr : constant U.Unbounded_String := Cur.Text;
                     begin
                        Expect (L.Tok_Name, "array name");
                        return NA ((Kind => E_In, Line => Cur.Line,
                                    In_Subs => List, In_Arr => Arr));
                     end;
                  end if;
                  Error ("unexpected expression list");
                  return First;
               end if;
               Expect (L.Tok_Rparen, "')'");
               Print_Mode := Saved_Print;
               return NA ((Kind => E_Group, Line => First.Line, Inner => First));
            end;

         when others =>
            Error ("unexpected token in expression");
            Advance;
            return NA ((Kind => E_Num, Line => Cur.Line, Num => 0.0));
      end case;
   end Parse_Primary;

   --  Statement grammar --------------------------------------------------------

   function Parse_Simple_Stmt return Stmt_Access is
   begin
      return new Stmt'(Kind => S_Expr, Line => Cur.Line, E => Parse_Expr);
   end Parse_Simple_Stmt;

   function Parse_Print (Is_Printf : Boolean) return Stmt_Access is
      Args  : Expr_Vectors.Vector;
      Redir : Redirect_Kind := R_None;
      Dest  : Expr_Access := null;
      Ln    : constant Positive := Cur.Line;
   begin
      Advance;   --  print / printf
      if not (At_Kind (L.Tok_Newline) or else At_Kind (L.Tok_Semicolon)
              or else At_Kind (L.Tok_Rbrace) or else At_Kind (L.Tok_Eof)
              or else At_Kind (L.Tok_Gt) or else At_Kind (L.Tok_Append)
              or else At_Kind (L.Tok_Pipe))
      then
         Print_Mode := True;
         Args.Append (Parse_Expr);
         while At_Kind (L.Tok_Comma) loop
            Advance; Skip_Newlines;
            Args.Append (Parse_Expr);
         end loop;
         Print_Mode := False;
      end if;
      if At_Kind (L.Tok_Gt) then
         Advance; Redir := R_File; Dest := Parse_Expr;
      elsif At_Kind (L.Tok_Append) then
         Advance; Redir := R_Append; Dest := Parse_Expr;
      elsif At_Kind (L.Tok_Pipe) then
         Advance; Redir := R_Pipe; Dest := Parse_Expr;
      end if;
      if Is_Printf then
         return new Stmt'(Kind => S_Printf, Line => Ln,
                          P_Args => Args, Redir => Redir, Dest => Dest);
      else
         return new Stmt'(Kind => S_Print, Line => Ln,
                          P_Args => Args, Redir => Redir, Dest => Dest);
      end if;
   end Parse_Print;

   function Parse_If return Stmt_Access is
      Ln     : constant Positive := Cur.Line;
      Cond   : Expr_Access;
      Then_S : Stmt_Access;
      Else_S : Stmt_Access := null;
      Save   : Positive;
   begin
      Advance;   --  if
      Expect (L.Tok_Lparen, "'('");
      Cond := Parse_Expr;
      Expect (L.Tok_Rparen, "')'");
      Skip_Newlines;
      Then_S := Parse_Stmt;
      Save := Pos;
      Skip_Terminators;
      if At_Kind (L.Tok_Else) then
         Advance; Skip_Newlines;
         Else_S := Parse_Stmt;
      else
         Pos := Save;
      end if;
      return new Stmt'(Kind => S_If, Line => Ln,
                       If_Cond => Cond, Then_S => Then_S, Else_S => Else_S);
   end Parse_If;

   function Parse_While return Stmt_Access is
      Ln   : constant Positive := Cur.Line;
      Cond : Expr_Access;
   begin
      Advance;
      Expect (L.Tok_Lparen, "'('");
      Cond := Parse_Expr;
      Expect (L.Tok_Rparen, "')'");
      Skip_Newlines;
      return new Stmt'(Kind => S_While, Line => Ln,
                       W_Cond => Cond, W_Body => Parse_Stmt);
   end Parse_While;

   function Parse_Do return Stmt_Access is
      Ln   : constant Positive := Cur.Line;
      Body_S : Stmt_Access;
      Cond : Expr_Access;
   begin
      Advance; Skip_Newlines;
      Body_S := Parse_Stmt;
      Skip_Terminators;
      Expect (L.Tok_While, "'while'");
      Expect (L.Tok_Lparen, "'('");
      Cond := Parse_Expr;
      Expect (L.Tok_Rparen, "')'");
      return new Stmt'(Kind => S_Do, Line => Ln, D_Body => Body_S, D_Cond => Cond);
   end Parse_Do;

   function Parse_For return Stmt_Access is
      Ln : constant Positive := Cur.Line;
   begin
      Advance;
      Expect (L.Tok_Lparen, "'('");
      --  for (NAME in ARRAY)
      if At_Kind (L.Tok_Name) and then Peek (1) = L.Tok_In then
         declare
            Var : constant U.Unbounded_String := Cur.Text;
            Arr : U.Unbounded_String;
         begin
            Advance;   --  NAME
            Advance;   --  in
            Arr := Cur.Text;
            Expect (L.Tok_Name, "array name");
            Expect (L.Tok_Rparen, "')'");
            Skip_Newlines;
            return new Stmt'(Kind => S_For_In, Line => Ln,
                             FI_Var => Var, FI_Arr => Arr, FI_Body => Parse_Stmt);
         end;
      end if;
      --  C-style for (init; cond; post)
      declare
         Init : Stmt_Access := null;
         Cond : Expr_Access := null;
         Post : Stmt_Access := null;
      begin
         if not At_Kind (L.Tok_Semicolon) then
            Init := Parse_Simple_Stmt;
         end if;
         Expect (L.Tok_Semicolon, "';'");
         if not At_Kind (L.Tok_Semicolon) then
            Cond := Parse_Expr;
         end if;
         Expect (L.Tok_Semicolon, "';'");
         if not At_Kind (L.Tok_Rparen) then
            Post := Parse_Simple_Stmt;
         end if;
         Expect (L.Tok_Rparen, "')'");
         Skip_Newlines;
         return new Stmt'(Kind => S_For, Line => Ln,
                          Init => Init, F_Cond => Cond, Post => Post,
                          F_Body => Parse_Stmt);
      end;
   end Parse_For;

   function Parse_Delete return Stmt_Access is
      Ln   : constant Positive := Cur.Line;
      Name : U.Unbounded_String;
      Subs : Expr_Vectors.Vector;
   begin
      Advance;   --  delete
      Name := Cur.Text;
      Expect (L.Tok_Name, "array name");
      if At_Kind (L.Tok_Lbracket) then
         Advance;
         Subs.Append (Parse_Expr);
         while At_Kind (L.Tok_Comma) loop
            Advance; Subs.Append (Parse_Expr);
         end loop;
         Expect (L.Tok_Rbracket, "']'");
         return new Stmt'(Kind => S_Delete, Line => Ln,
                          Del_Arr => Name, Del_Subs => Subs);
      end if;
      return new Stmt'(Kind => S_Delete_All, Line => Ln, All_Arr => Name);
   end Parse_Delete;

   function Parse_Stmt return Stmt_Access is
      Ln : constant Positive := Cur.Line;
   begin
      case Kind is
         when L.Tok_Lbrace   => return Parse_Block;
         when L.Tok_If       => return Parse_If;
         when L.Tok_While    => return Parse_While;
         when L.Tok_Do       => return Parse_Do;
         when L.Tok_For      => return Parse_For;
         when L.Tok_Print    => return Parse_Print (Is_Printf => False);
         when L.Tok_Printf   => return Parse_Print (Is_Printf => True);
         when L.Tok_Delete   => return Parse_Delete;
         when L.Tok_Break    => Advance; return new Stmt'(Kind => S_Break, Line => Ln);
         when L.Tok_Continue => Advance; return new Stmt'(Kind => S_Continue, Line => Ln);
         when L.Tok_Next     => Advance; return new Stmt'(Kind => S_Next, Line => Ln);
         when L.Tok_Nextfile => Advance; return new Stmt'(Kind => S_Nextfile, Line => Ln);
         when L.Tok_Semicolon => return new Stmt'(Kind => S_Nop, Line => Ln);
         when L.Tok_Exit =>
            Advance;
            declare
               V : Expr_Access := null;
            begin
               if not (At_Kind (L.Tok_Newline) or else At_Kind (L.Tok_Semicolon)
                       or else At_Kind (L.Tok_Rbrace) or else At_Kind (L.Tok_Eof))
               then
                  V := Parse_Expr;
               end if;
               return new Stmt'(Kind => S_Exit, Line => Ln, Val => V);
            end;
         when L.Tok_Return =>
            Advance;
            declare
               V : Expr_Access := null;
            begin
               if not (At_Kind (L.Tok_Newline) or else At_Kind (L.Tok_Semicolon)
                       or else At_Kind (L.Tok_Rbrace) or else At_Kind (L.Tok_Eof))
               then
                  V := Parse_Expr;
               end if;
               return new Stmt'(Kind => S_Return, Line => Ln, Val => V);
            end;
         when others =>
            return Parse_Simple_Stmt;
      end case;
   end Parse_Stmt;

   function Parse_Block return Stmt_Access is
      Stmts : Stmt_Vectors.Vector;
      Ln    : constant Positive := Cur.Line;
   begin
      Expect (L.Tok_Lbrace, "'{'");
      Skip_Terminators;
      while not At_Kind (L.Tok_Rbrace) and then not At_Kind (L.Tok_Eof)
        and then not Failed
      loop
         Stmts.Append (Parse_Stmt);
         Skip_Terminators;
      end loop;
      Expect (L.Tok_Rbrace, "'}'");
      return new Stmt'(Kind => S_Block, Line => Ln, Stmts => Stmts);
   end Parse_Block;

   --  Top level ----------------------------------------------------------------

   procedure Parse_Function (Prog : in out Program) is
      Def : Func_Def;
   begin
      Advance;   --  function
      Def.Name := Cur.Text;
      if not (At_Kind (L.Tok_Name) or else At_Kind (L.Tok_Func_Name)) then
         Error ("expected function name");
         return;
      end if;
      Advance;
      Expect (L.Tok_Lparen, "'('");
      if not At_Kind (L.Tok_Rparen) then
         Def.Params.Append (Cur.Text);
         Expect (L.Tok_Name, "parameter name");
         while At_Kind (L.Tok_Comma) loop
            Advance; Skip_Newlines;
            Def.Params.Append (Cur.Text);
            Expect (L.Tok_Name, "parameter name");
         end loop;
      end if;
      Expect (L.Tok_Rparen, "')'");
      Skip_Newlines;
      Def.Body_S := Parse_Block;
      Prog.Funcs.Append (Def);
   end Parse_Function;

   procedure Parse_Rule (Prog : in out Program) is
      R : Rule;
   begin
      if At_Kind (L.Tok_Begin) then
         Advance; R.Pat := P_Begin; Skip_Newlines; R.Action := Parse_Block;
      elsif At_Kind (L.Tok_End) then
         Advance; R.Pat := P_End; Skip_Newlines; R.Action := Parse_Block;
      elsif At_Kind (L.Tok_Lbrace) then
         R.Pat := P_Always; R.Action := Parse_Block;
      else
         R.Expr1 := Parse_Expr;
         if At_Kind (L.Tok_Comma) then
            Advance; Skip_Newlines;
            R.Expr2 := Parse_Expr;
            R.Pat := P_Range;
         else
            R.Pat := P_Expr;
         end if;
         if At_Kind (L.Tok_Lbrace) then
            R.Action := Parse_Block;
         else
            R.Action := null;   --  default { print $0 }
         end if;
      end if;
      Prog.Rules.Append (R);
   end Parse_Rule;

   procedure Parse
     (Source  : String;
      Prog    : out Awklib.Ast.Program;
      Status  : out Result_Status;
      Message : out U.Unbounded_String)
   is
      Lex_Status : L.Result_Status;
      Lex_Msg    : U.Unbounded_String;
   begin
      Prog := (others => <>);
      Pos := 1;
      Failed := False;
      Err_Msg := U.Null_Unbounded_String;
      Print_Mode := False;

      L.Tokenize (Source, Toks, Lex_Status, Lex_Msg);
      if Lex_Status /= L.Ok then
         Status := Parse_Error;
         Message := Lex_Msg;
         return;
      end if;

      Skip_Terminators;
      while not At_Kind (L.Tok_Eof) and then not Failed loop
         if At_Kind (L.Tok_Function) then
            Parse_Function (Prog);
         else
            Parse_Rule (Prog);
         end if;
         Skip_Terminators;
      end loop;

      if Failed then
         Status := Parse_Error;
         Message := Err_Msg;
         Prog := (others => <>);
      else
         Status := Ok;
         Message := U.Null_Unbounded_String;
      end if;
   end Parse;

end Awklib.Parser;

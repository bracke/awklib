with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Awklib.Values;

package Awklib.Ast is
   --  Abstract syntax tree for an AWK program. Nodes are heap-allocated and
   --  live for the duration of a run; the tree is immutable once parsed.

   package U renames Ada.Strings.Unbounded;

   package String_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => U.Unbounded_String, "=" => U."=");

   --  Operators ---------------------------------------------------------------

   type Bin_Op is
     (Op_Add, Op_Sub, Op_Mul, Op_Div, Op_Mod, Op_Pow,
      Op_Lt, Op_Le, Op_Gt, Op_Ge, Op_Eq, Op_Ne);

   type Assign_Op is (As_Set, As_Add, As_Sub, As_Mul, As_Div, As_Mod, As_Pow);

   type Unary_Op is (Un_Neg, Un_Pos, Un_Not);

   type Builtin_Id is
     (B_Length, B_Substr, B_Index, B_Split, B_Sub, B_Gsub, B_Match, B_Sprintf,
      B_Int, B_Sin, B_Cos, B_Atan2, B_Exp, B_Log, B_Sqrt, B_Rand, B_Srand,
      B_Tolower, B_Toupper, B_System, B_Close, B_Fflush);

   type Getline_Source is (G_Main, G_File, G_Command);

   --  Expressions --------------------------------------------------------------

   type Expr;
   type Expr_Access is access Expr;

   package Expr_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Expr_Access);

   type Expr_Kind is
     (E_Num, E_Str, E_Regex, E_Var, E_Field, E_Subscript, E_Assign, E_Binary,
      E_Unary, E_Incr_Decr, E_Ternary, E_Match, E_In, E_And, E_Or, E_Call,
      E_Builtin, E_Getline, E_Group, E_Concat);

   type Expr (Kind : Expr_Kind) is record
      Line : Positive := 1;
      case Kind is
         when E_Num =>
            Num : Values.Number := 0.0;
         when E_Str =>
            Str : U.Unbounded_String;
         when E_Regex =>
            Rx : U.Unbounded_String;
         when E_Var =>
            Var_Name : U.Unbounded_String;
         when E_Field =>
            Fld : Expr_Access;
         when E_Subscript =>
            Arr_Name : U.Unbounded_String;
            Subs     : Expr_Vectors.Vector;
         when E_Assign =>
            Target : Expr_Access;
            A_Op   : Assign_Op;
            Rhs    : Expr_Access;
         when E_Binary =>
            B_Op : Bin_Op;
            L    : Expr_Access;
            R    : Expr_Access;
         when E_Unary =>
            U_Op    : Unary_Op;
            Operand : Expr_Access;
         when E_Incr_Decr =>
            Is_Incr : Boolean;       --  ++ vs --
            Is_Pre  : Boolean;       --  prefix vs postfix
            Lvalue  : Expr_Access;
         when E_Ternary =>
            Cond   : Expr_Access;
            T_Expr : Expr_Access;
            F_Expr : Expr_Access;
         when E_Match =>
            M_Neg : Boolean;         --  !~
            M_L   : Expr_Access;
            M_R   : Expr_Access;
         when E_In =>
            In_Subs : Expr_Vectors.Vector;
            In_Arr  : U.Unbounded_String;
         when E_And | E_Or =>
            Lg_L : Expr_Access;
            Lg_R : Expr_Access;
         when E_Call =>
            Fn_Name : U.Unbounded_String;
            Args    : Expr_Vectors.Vector;
         when E_Builtin =>
            B_Id   : Builtin_Id;
            B_Args : Expr_Vectors.Vector;
         when E_Getline =>
            GL_Var    : Expr_Access;        --  target lvalue or null ($0)
            GL_Source : Getline_Source;
            GL_Arg    : Expr_Access;        --  file/command expr or null
         when E_Group =>
            Inner : Expr_Access;
         when E_Concat =>
            C_L : Expr_Access;
            C_R : Expr_Access;
      end case;
   end record;

   --  Statements ---------------------------------------------------------------

   type Stmt;
   type Stmt_Access is access Stmt;

   package Stmt_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Stmt_Access);

   type Redirect_Kind is (R_None, R_File, R_Append, R_Pipe);

   type Stmt_Kind is
     (S_Expr, S_Print, S_Printf, S_If, S_While, S_Do, S_For, S_For_In,
      S_Break, S_Continue, S_Next, S_Nextfile, S_Exit, S_Return, S_Delete,
      S_Delete_All, S_Block, S_Nop);

   type Stmt (Kind : Stmt_Kind) is record
      Line : Positive := 1;
      case Kind is
         when S_Expr =>
            E : Expr_Access;
         when S_Print | S_Printf =>
            P_Args : Expr_Vectors.Vector;
            Redir  : Redirect_Kind := R_None;
            Dest   : Expr_Access;
         when S_If =>
            If_Cond : Expr_Access;
            Then_S  : Stmt_Access;
            Else_S  : Stmt_Access;
         when S_While =>
            W_Cond : Expr_Access;
            W_Body : Stmt_Access;
         when S_Do =>
            D_Body : Stmt_Access;
            D_Cond : Expr_Access;
         when S_For =>
            Init   : Stmt_Access;
            F_Cond : Expr_Access;
            Post   : Stmt_Access;
            F_Body : Stmt_Access;
         when S_For_In =>
            FI_Var  : U.Unbounded_String;
            FI_Arr  : U.Unbounded_String;
            FI_Body : Stmt_Access;
         when S_Exit | S_Return =>
            Val : Expr_Access;
         when S_Delete =>
            Del_Arr  : U.Unbounded_String;
            Del_Subs : Expr_Vectors.Vector;
         when S_Delete_All =>
            All_Arr : U.Unbounded_String;
         when S_Block =>
            Stmts : Stmt_Vectors.Vector;
         when others =>
            null;   --  S_Break, S_Continue, S_Next, S_Nextfile, S_Nop
      end case;
   end record;

   --  Program ------------------------------------------------------------------

   type Pattern_Kind is (P_Begin, P_End, P_Expr, P_Range, P_Always);

   type Rule is record
      Pat    : Pattern_Kind := P_Always;
      Expr1  : Expr_Access;
      Expr2  : Expr_Access;
      Action : Stmt_Access;   --  block; null => default { print $0 }
   end record;

   package Rule_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Rule);

   type Func_Def is record
      Name   : U.Unbounded_String;
      Params : String_Vectors.Vector;
      Body_S : Stmt_Access;
   end record;

   package Func_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Func_Def);

   type Program is record
      Rules : Rule_Vectors.Vector;
      Funcs : Func_Vectors.Vector;
   end record;

end Awklib.Ast;

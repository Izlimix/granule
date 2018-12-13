# `grin`—Granule Interactive

A REPL for the Granule language

## Contents
- [Getting Started](#getting-started)
- [REPL Commands and Use](#repl-commands-and-use)
  - [help](#help-h)
  - [quit](#quit-q)
  - [load](#load-filepath-l)
  - [type](#type-term-t)
  - [show](#show-term-s)
  - [parse](#parse-expression-or-type-p)
  - [lexer](#lexer-string-x)
  - [debug](#debug-filepath-d)
  - [dump](#dump)
  - [module](#module-filepathm)
  - [reload](#reload-r)
- [Configuration File](#configuration-file)
  - [Config File Creation](#config-file-creation)
  - [Config File Format](#config-file-format)
  - [Config File Use](#config-file-use)

## Getting Started

To install `grin`, run
```
$ stack install
```

To launch, run
```
$ grin
```

## REPL Commands and Use

The following commands are available for use in the REPL
```
:help                (:h)  
:quit                (:q)  
:type <term>         (:t)  
:type_scheme <type>  (:ts)
:show <term>         (:s)  
:parse <expression>  (:p)  
:lexer <string>      (:x)  
:debug <filepath>    (:d)  
:dump                ()   
:load <filepath>     (:l)  
:module <filepath>   (:m)
```


#### :help (:h)
<a id="help"></a>
Display the help menu

#### :quit (:q)
<a id="quit"></a>
Leave the REPL

#### :load <filepath\> (:l)
<a id="load"></a>
Load a file into the REPL.  This will erase content in state and replace with loaded file.
```
Granule> :l Vec.gr
S:\Documents\Research\granule\StdLib\Vec.gr, interpreted
```
#### :type <term\> (:t)
<a id="type"></a>
Display the type of a term in the REPL state
```
Granule> :l Vec.gr
S:\Documents\Research\granule\StdLib\Vec.gr, interpreted

Granule> :t head
head : forall a : Type, n : Nat. ((Vec n + 1 a) |1|) -> a
```

#### :show <term\> (:s)
<a id="show"></a>
Show the Def for a given term in the REPL state
```
Granule> :l Nat.gr
S:\Documents\Research\granule\StdLib\Nat.gr, interpreted

Granule> :s add
Def ((32,1),(36,27)) (Id "add" "add") (Case ((34,3),(36,27)) (Val ((34,8),(34,8)) (Var (Id "n" "n_0"))) [(PConstr ((35,7),(35,7)) (Id "Z" "Z") [],Val ((35,17),(35,17)) (Var (Id "m" "m_1"))),(PConstr ((36,8),(36,8)) (Id "S" "S") [PVar ((36,10),(36,10)) (Id "n'" "n'_4")],App ((36,17),(36,27)) (Val ((36,17),(36,17)) (Constr (Id "S" "S") [])) (App ((36,20),(36,27)) (App ((36,20),(36,24)) (Val ((36,20),(36,20)) (Var (Id "add" "add"))) (Val ((36,24),(36,24)) (Var (Id "n'" "n'_4")))) (Val ((36,27),(36,27)) (Var (Id "m" "m_1")))))]) [PVar ((33,5),(33,5)) (Id "n" "n_0"),PVar ((33,7),(33,7)) (Id "m" "m_1")] (Forall ((32,7),(32,35)) [((Id "n" "n_2"),kConstr (Id "Nat=" "Nat=")),((Id "m" "m_3"),kConstr (Id "Nat=" "Nat="))] (FunTy (TyApp (TyCon (Id "N" "N")) (TyVar (Id "n" "n_2"))) (FunTy (TyApp (TyCon (Id "N" "N")) (TyVar (Id "m" "m_3"))) (TyApp (TyCon (Id "N" "N")) (TyInfix "+" (TyVar (Id "n" "n_2")) (TyVar (Id "m" "m_3")))))))
```
#### :parse <expression or type\> (:p)
<a id="parse"></a>
Run Granule parser on an expression and display Expr.  If input is not an expression parser will attempt to run it against the TypeScheme parser and display the TypeScheme
```
Granule> :p sum (Cons 1(Cons 2 Nil))
App ((1,1),(1,20)) (Val ((1,1),(1,1)) (Var (Id "sum" "sum"))) (App ((1,6),(1,20)) (App ((1,6),(1,11)) (Val ((1,6),(1,6)) (Constr (Id "Cons" "Cons") [])) (Val ((1,11),(1,11)) (NumInt 1))) (App ((1,13),(1,20)) (App ((1,13),(1,18)) (Val ((1,13),(1,13)) (Constr (Id "Cons" "Cons") [])) (Val ((1,18),(1,18)) (NumInt 2))) (Val ((1,20),(1,20)) (Constr (Id "Nil" "Nil") []))))
```
```
Granule> :p Int -> Int
1:5: parse error
Input not an expression, checking for TypeScheme
Forall ((0,0),(0,0)) [] (FunTy (TyCon (Id "Int" "Int")) (TyCon (Id "Int" "Int")))
```
#### :lexer <string\> (:x)
<a id="lexer"></a>
Run lexer on a string and display [Token]
```
Granule> :x sum (Cons 1(Cons 2 Nil))
[TokenSym (AlexPn 0 1 1) "sum",TokenLParen (AlexPn 4 1 5),TokenConstr (AlexPn 5 1 6) "Cons",TokenInt (AlexPn 10 1 11) 1,TokenLParen (AlexPn 11 1 12),TokenConstr (AlexPn 12 1 13) "Cons",TokenInt (AlexPn 17 1 18) 2,TokenConstr (AlexPn 19 1 20) "Nil",TokenRParen (AlexPn 22 1 23),TokenRParen (AlexPn 23 1 24)]
```
#### :debug <filepath\> (:d)
<a id="debug"></a>
Run the Granule debugger and display its output while loading a file
```
Granule> :d CombinatoryLogic.gr
<...Full AST will display here...>
<...Full pretty printed AST will display here...>
Debug: Patterns.ctxtFromTypedPatterns
Called with span: ((1,1),(2,7))
type: TyVar (Id "a" "a_1")

Debug: + Compare for equality
a_1 = a_1

Debug: Solver predicate


Debug: Patterns.ctxtFromTypedPatterns
Called with span: ((4,1),(6,16))
type: TyVar (Id "c" "c_5")
```
#### :dump
Display the contents of the REPL state in the form of `term : term type`
```
Granule> :l example.gr
S:\Documents\Research\granule\tests\regression\good\example.gr, interpreted

Granule> :dump
["dub : ((Int) |2|) -> Int","main : Int","trip : ((Int) |3|) -> Int","twice : forall c : Nat. ((((Int) |c|) -> Int) |2|) -> ((Int) |2 * c|) -> Int"]
```

#### :module <filepath\>(:m)
<a id="module"></a>
Adds a file to the REPL by appending to the current REPL state
```
Granule> :m Files.gr
S:\Documents\Research\granule\examples\Files.gr, interpreted
```
#### :reload (:r)
Reload the last file loaded into the Repl
```
Granule> :l example.gr
S:\Documents\Research\granule\tests\regression\good\example.gr, interpreted
Granule> :r
S:\Documents\Research\granule\tests\regression\good\example.gr, interpreted
```
## Configuration File
<a id="configuration-file"></a>

The congiuration file contains various variables used for set up of the REPL
#### Config file creation
<a id="config-file-creation"></a>
The configuration file needs to be created by the user.  It needs to be named
`.granule.conf`.  This file needs to be placed in the home directory
###### Windows
```
C:\Users\<username>
```
###### Linux
```
/home/<username> or directory of users $HOME environmental variable
```
###### Mac OS X
```
/Users/<username>
```
#### Config File Format
<a id="config-file-format"></a>
The config file is set up so the config variable is on the far left (needs to be lowercase)
followed by an equals and then the value(s).  For multiple value a newline and white space
is needed.  
```
<config var 1> = someValue
<config var 2> = aValue1
                 aValue2
                 aValue3
```
#### Config File Use
<a id="config-file-use"></a>
Currently the config file uses a `path` variable to make loading files into the REPL easier.
If the path variable is set up you can use just a file name instead of the full path to load the files.  To set up add the `path = <directory paths>` to the config file.  
NOTE: The REPL will search subdirectories when looking for a matching file.
```
path = S:\Documents\Research\granule\StdLib
       S:\Documents\Research\granule\examples
       S:\Documents\Research\granule\tests\regression\good
```

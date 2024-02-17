Nonterminals List Type Root.
Terminals ',' '[' ']' '(' ')' indexed atom var integer typename.
Rootsymbol Root.

List -> Type indexed var ',' List: [{atom_to_binary(element(3,'$3'),utf8),{indexed,'$1'}} | '$5'].
List -> Type indexed var: [{atom_to_binary(element(3,'$3'),utf8),{indexed,'$1'}}].

List -> Type indexed atom ',' List: [{atom_to_binary(element(3,'$3'),utf8),{indexed,'$1'}} | '$5'].
List -> Type indexed atom: [{atom_to_binary(element(3,'$3'),utf8),{indexed,'$1'}}].

List -> Type indexed ',' List: [{<<>>,{indexed,'$1'}} | '$4'].
List -> Type indexed: [{<<>>,{indexed,'$1'}}].

List -> Type var ',' List: [{atom_to_binary(element(3,'$2'),utf8),'$1'} | '$4'].
List -> Type var: [{atom_to_binary(element(3,'$2'),utf8),'$1'}].

List -> Type atom ',' List: [{atom_to_binary(element(3,'$2'),utf8),'$1'} | '$4'].
List -> Type atom: [{atom_to_binary(element(3,'$2'),utf8),'$1'}].

List -> Type ',' List: [{<<>>,'$1'} | '$3'].
List -> Type : [{<<>>,'$1'}].

Root -> atom : {element(3,'$1'), undefined}.
Root -> atom '(' List ')' : {element(3,'$1'), '$3'}.
Root -> var '(' List ')' : {element(3,'$1'), '$3'}.
Root -> atom '(' ')' : {element(3,'$1'), []}.
Root -> var '(' ')' : {element(3,'$1'), []}.
Root -> '(' ')' : {undefined, []}.
Root -> '(' List ')' : {undefined, '$2'}.

Type -> '(' ')' : {'tuple',[]}.
Type -> '(' List ')' : {'tuple','$2'}.
Type -> Type '[' ']' : {'darray','$1'}.
Type -> Type '[' integer ']' : {{'fixarray',element(3,'$3')},'$1'}.
Type -> typename : element(3,'$1').


Nonterminals List ET Root.
Terminals ',' '[' ']' '(' ')' atom.
Rootsymbol Root.

List -> ET atom ',' List: [{atom_to_binary(element(3,'$2'),utf8),'$1'} | '$4'].
List -> ET ',' List: [{<<>>,'$1'} | '$3'].
List -> ET atom: [{atom_to_binary(element(3,'$2'),utf8),'$1'}].
List -> ET : [{<<>>,'$1'}].

Root -> atom : {element(3,'$1'), undefined}.
Root -> atom '(' List ')' : {element(3,'$1'), '$3'}.
Root -> atom '(' ')' : {element(3,'$1'), []}.
Root -> '(' ')' : {undefined, []}.
Root -> '(' List ')' : {undefined, '$2'}.

ET -> '(' ')' : {'tuple',[]}.
ET -> '(' List ')' : {'tuple','$2'}.
ET -> ET '[' ']' : {'array','$1'}.
ET -> atom : element(3,'$1').


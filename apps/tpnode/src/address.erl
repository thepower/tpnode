-module(address).

-export([pub2addr/2,pub2addrraw/2,check/1]).

pub2addr(node,Pub) ->
    Hash=crypto:hash(ripemd160,Pub),
    Crc=erlang:crc32(Hash),
    base58:encode( <<76,200,56,214, Crc:32/integer, Hash/binary>> );

pub2addr(Ver,Pub) ->
    H2H3=pub2addrraw(Ver,Pub),
    base58:encode(H2H3).

pub2addrraw(Ver,Pub) ->
    H1=crypto:hash(ripemd160,
                   crypto:hash(sha256,Pub)
                  ),
    H2= <<Ver:8/integer,H1/binary>>,
    <<H3:4/binary,_/binary>>=crypto:hash(sha256,crypto:hash(sha256,H2)),
    <<H2/binary,H3/binary>>.

check(Address) ->
    <<Ver:8/integer,RipeMD:20/binary,Check:4/binary>>=base58:decode(Address),
    <<H3:4/binary,_/binary>>=
        crypto:hash(sha256,
                    crypto:hash(sha256,<<Ver:8/integer,RipeMD:20/binary>>)
                   ),
        {Check==H3,Ver}.



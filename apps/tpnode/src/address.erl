-module(address).

-export([pub2caddr/2, pub2addr/2, pub2addrraw/2, check/1,
         encodekey/1, parsekey/1, paddr/1,
        addr2chain/2]).

-define(VER, 133).

paddr(PKey) ->
    Crc=erlang:crc32(PKey),
    <<"tp", (base58:encode( << Crc:32/integer, PKey/binary>> ))/binary>>.

pub2addr(node, Pub) ->
    Hash=crypto:hash(ripemd160, Pub),
    Crc=erlang:crc32(Hash),
    base58:encode( <<76, 200, 56, 214, Crc:32/integer, Hash/binary>> );

pub2addr(Ver, Pub) when is_integer(Ver) ->
    H2H3=pub2addrraw(Ver, Pub),
    base58:encode(H2H3);

pub2addr({ver, Ver}, Pub) when is_integer(Ver) ->
    H2H3=pub2addrraw(Ver, Pub),
    base58:encode(H2H3);

pub2addr({chain, Chain}, Pub) when is_integer(Chain) ->
    H2H3=pub2caddrraw(Chain, Pub),
    base58:encode(H2H3).

pub2caddr(Chain, Pub) ->
    H2H3=pub2caddrraw(Chain, Pub),
    base58:encode(H2H3).

pub2addrraw(Ver, Pub) ->
    H1=crypto:hash(ripemd160,
                   crypto:hash(sha256, Pub)
                  ),
    H2= <<Ver:8/integer, H1/binary>>,
    <<H3:4/binary, _/binary>>=crypto:hash(sha256, crypto:hash(sha256, H2)),
    <<H2/binary, H3/binary>>.

pub2caddrraw(Chain, Pub) ->
    H1=crypto:hash(ripemd160,
                   crypto:hash(sha256, Pub)
                  ),
    H2= <<?VER, H1/binary, Chain:32/big>>,
    <<H3:4/binary, _/binary>>=crypto:hash(sha256, H2),
    <<H2/binary, H3/binary>>.

addr2chain(Chain, Address) ->
    H2H3=addr2chainraw(Chain, Address),
    base58:encode(H2H3).

addr2chainraw(Chain, Address) ->
    case base58:decode(Address) of
        <<Ver:8/integer, RipeMD:20/binary, Check:4/binary>> ->
            <<H3:4/binary, _/binary>>=
            crypto:hash(sha256,
                        crypto:hash(sha256, <<Ver:8/integer, RipeMD:20/binary>>)
                       ),
            Check=H3,
            H2= <<?VER, RipeMD/binary, Chain:32/big>>,
            <<H3n:4/binary, _/binary>>=crypto:hash(sha256, H2),
            <<H2/binary, H3n/binary>>;
        <<?VER, RipeMD:20/binary, OldChain:32/big, Check:4/binary>> ->
            <<H3:4/binary, _/binary>>=
                        crypto:hash(sha256, <<?VER, RipeMD:20/binary, OldChain:32/big>>),
            Check=H3,
            H2= <<?VER, RipeMD/binary, Chain:32/big>>,
            <<H3n:4/binary, _/binary>>=crypto:hash(sha256, H2),
            <<H2/binary, H3n/binary>>
    end.

check(Address) ->
    try
        case base58:decode(Address) of
            <<Ver:8/integer, RipeMD:20/binary, Check:4/binary>> ->
                <<H3:4/binary, _/binary>>=
                crypto:hash(sha256,
                            crypto:hash(sha256, <<Ver:8/integer, RipeMD:20/binary>>)
                           ),
                {Check==H3, {ver, Ver}};
            <<?VER, RipeMD:20/binary, OldChain:32/big, Check:4/binary>> ->
                <<H3:4/binary, _/binary>>=
                crypto:hash(sha256, <<?VER, RipeMD:20/binary, OldChain:32/big>>),
                {Check==H3, {chain, OldChain}};
            _ ->
                {false, unknown}
        end
    catch _:_ ->
              {false, invalid}
    end.

encodekey(Pvt) ->
    H2= <<128, Pvt/binary>>,
    <<H3:4/binary, _/binary>>=crypto:hash(sha256, crypto:hash(sha256, H2)),
    base58:encode(<<H2/binary, H3/binary>>).

parsekey(<<"0x", BKey/binary>>) ->
    hex:parse(BKey);
parsekey(Base58) ->
    B58Decode=base58:decode(Base58),
    KS=size(B58Decode)-5,
    case B58Decode of
        <<128, KeyBody:KS/binary, KC:4/binary>> ->
            <<H3:4/binary, _/binary>>=
            crypto:hash(sha256,
                        crypto:hash(sha256, <<128:8/integer, KeyBody/binary>>)
                       ),
            if(KC==H3 andalso KS==32) ->
                  KeyBody;
              (KC==H3 andalso KS==33) ->
                  <<KB:32/binary, _:1/binary>>=KeyBody,
                  KB;
              true ->
                  error
            end;
        _ ->
            error
    end.



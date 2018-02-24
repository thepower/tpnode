-module(naddress).
-export([decode/1,encode/1,check/1]).
-export([construct_public/3,
         construct_private/2,
         splitby/2,
         parse/1]).
-export([g2i/1,i2g/1]).
-export([mine/1]).

% Numbering plan
% Whole address is 64 bit yet of which 61 bits are usable
% address must begin with bits 100 which is means public address
% or 101 for private addresses (in chain address)
%
% all addresses divided by block on 24 bit boundary (2^24 addresses
% in each block).
% Public address additionally divided into group (top level).
% Each group contains 2^21 blocks.
% Private addresses have no division on groups.
%
%
% binary representation
% 100GGGGG GGGGGGGG GGGBBBBB BBBBBBBB BBBBBBBB AAAAAAAA AAAAAAAA AAAAAAAA 
% 101BBBBB BBBBBBBB BBBBBBBB BBBBBBBB BBBBBBBB AAAAAAAA AAAAAAAA AAAAAAAA 

%% Make public address from components
construct_public(Group, Block, Address) when Group < 16#10000,
                                             Block <    16#200000,
                                             Address < 16#1000000 ->
    binary:encode_unsigned(Address bor (Block bsl 24) bor (Group bsl 45) bor (4 bsl 61)).

%% Make private address from components
construct_private(Block, Address) when Block<16#2000000000,
                                       Address<16#1000000 ->
    IntPart=Address bor (Block bsl 24),
    binary:encode_unsigned(IntPart bor (5 bsl 61)).

%% split address to components

parse(<<X:64/big>>) -> parse(X);

parse(Int) when is_integer(Int) andalso Int >= 9223372036854775808 
                 andalso Int < 13835058055282163712 ->
    case Int bsr 61 of
        4 -> #{ type=>public,
                address=>Int band 16#FFFFFF,
                block=>(Int bsr 24) band 16#1fffff,
                group=>(Int bsr 45) band 16#ffff
              };
        5 -> #{ type=>private,
                address=>Int band 16#FFFFFF,
                block=>(Int bsr 24) band 16#1FFFFFFFFF 
              }
    end.

%% encode address to human frendly format
encode(<<X:64/big>>) -> encode(X);
encode(Int) when is_integer(Int) andalso Int >= 9223372036854775808 
                 andalso Int < 13835058055282163712 ->
    Type=case Int bsr 61 of
             4 -> public;
             5 -> private
    end,
    CSum=erlang:crc32(<<Int:64/big>>),
    case Type of
        private ->
            iolist_to_binary(
                lists:flatten(
                  io_lib:format("~16.16.0B~2.16.0B",
                                [Int band ((1 bsl 61)-1),
                                 CSum rem 256
                                ])
                 )
             );
        public ->
            Digits=((1 bsl 45)-1) band Int,
            Prefix=(Int bsr 45),
            Group=Prefix band 65535,
            iolist_to_binary(
              [
               i2g(Group),
               lists:flatten(io_lib:format("~14.10.0B",[Digits])),
               io_lib:format("~2.10.0B",[CSum rem 100])
              ]
             )
    end.

check(UserAddr) ->
    try
        {true, parse(UserAddr)}
    catch _:_ ->
              {false, unknown}
    end.
%% decode address from human-frendly format to int and check checksum

decode(UserAddr) ->
    C=cleanup(UserAddr),
    case size(C) of 
        20 -> % public address
            <<H4:4/binary,B14:14/binary,BCRC:2/binary>>=C,
            IntPart=binary_to_integer(B14,10),
            CharPart=g2i(H4),
            Address=IntPart bor (CharPart bsl 45) bor (4 bsl 61),
            CSum=erlang:crc32(<<Address:64/big>>) rem 100,
            CRC=binary_to_integer(BCRC),
            if(CSum==CRC) ->
                  binary:encode_unsigned(Address);
              true ->
                  throw({error,address_crc})
            end;
        18 -> 
            PI=binary_to_integer(C,16),
            Address=(PI bsr 8) bor (5 bsl 61),
            CRC=PI band 255,
            CSum=erlang:crc32(<<Address:64/big>>) band 255,
            if(CSum==CRC) ->
                  binary:encode_unsigned(Address);
              true ->
                  throw({error,address_crc})
            end;
        _ -> throw('bad_addr')
    end.

%%%
%%% internal functions
%%%

splitby(String,N) when is_list(String) ->
    case String of 
        [H1,H2,H3,H4|Rest] ->
            [H1,H2,H3,H4," ",  splitby(Rest,N)];
        _ ->
            String
    end;

splitby(String,N) when is_binary(String) ->
    case String of 
        <<H1:N/binary,Rest/binary>> ->
            <<H1/binary," ",(splitby(Rest,N))/binary>>;
        _ ->
            String
    end.


binclean(<<>>) ->
    <<>>;

binclean(<<" ",Rest/binary>>) ->
    binclean(Rest);

binclean(<<I:8/integer,Rest/binary>>) ->
    <<I:8/integer,(binclean(Rest))/binary>>.

cleanup(Address) when is_binary(Address) ->
    binclean(Address);

cleanup(Address) when is_list(Address) ->
    list_to_binary(
      lists:filter( 
        fun(32) -> false;
           (_) -> true
        end, 
        Address)
     ).


bin2i(I) when I>=$a andalso $z>=I -> I-$a;
bin2i(I) when I>=$A andalso $Z>=I -> I-$A;
bin2i(_) -> throw({error,badchar}).


g2i(<<L1:8/integer,L2:8/integer,D:2/binary>>) -> 
    bin2i(L1) * 2600 + bin2i(L2) * 100 + binary_to_integer(D).

i2g(I) when I<65536 -> 
    L0=I rem 10,
    L1=(I div 10) rem 10,
    L2=(I div 100) rem 26,
    L3=I div 2600,
    <<($A+L3),($A+L2),($0+L1),($0+L0)>>.

mine(Num) ->
    Tail=Num div 100,
    CS=Num rem 100,
    lists:filtermap(
      fun(N) -> 
              B= <<4:3/big,N:16/big,Tail:45/big>>,
              C=erlang:crc32(B), 
              if C rem 100 == CS -> 
                     {true, encode(B) }; 
                 true -> false 
              end 
      end, 
      lists:usort(lists:seq(0,256) ++ 
                  lists:seq(65300,65535) ++
                  [ X*64 || X<-lists:seq(0,1024)])).


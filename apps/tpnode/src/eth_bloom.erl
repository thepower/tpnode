-module(eth_bloom).
-export([bloom_filter/2, bloom_filter20/2, bloom_filter32/2, bloom_pop_bits/1]).

%% We define the Bloom filter function, M, to reduce a log
%% entry into a single 256-byte hash:
%% (23) M(O) ≡ V_(t∈{Oa}∪Ot) (M3:2048(t))
%% where M3:2048 is a specialised Bloom filter that sets
%% three bits out of 2048, given an arbitrary byte sequence.
%% It does this through taking the low-order 11 bits of each
%% of the first three pairs of bytes in a Keccak-256 hash of
%% the byte sequence. Formally:
%% (24) M3:2048(x : x ∈ B) ≡ y : y ∈ B256 where:
%% (25) y = (0, 0, ..., 0) except:
%% (26) ∀i∈{0,2,4} : Bm(x,i)(y) = 1
%% (27) m(x, i) ≡ KEC(x)[i, i + 1] mod 2048
%% where B is the bit reference function such that Bj (x)
%% equals the bit of index j (indexed from 0) in the byte array x.

bloom_filter({hash,<<Hash:32/binary>>}, Filter) ->
    Bits = bloom_bits(Hash),
    Filter bor Bits;

bloom_filter(Data, Filter) ->
    Hash = contract_evm_abi:keccak(Data),
    Bits = bloom_bits(Hash),
    Filter bor Bits.

bloom_filter20(Data, Filter) when 20 >= size(Data) ->
    Hash = contract_evm_abi:keccak(<<0:((20-size(Data))*8)/big, Data/binary>>),
    Bits = bloom_bits(Hash),
    Filter bor Bits.

bloom_filter32(Data, Filter) when 32 >= size(Data) ->
    Hash = contract_evm_abi:keccak(<<0:((32-size(Data))*8)/big, Data/binary>>),
    Bits = bloom_bits(Hash),
    Filter bor Bits.


bloom_bits(Hash) ->
    {Bit1, Hash1} = bloom_bit(Hash),
    {Bit2, Hash2} = bloom_bit(Hash1),
    {Bit3,     _} = bloom_bit(Hash2),

    (1 bsl Bit1) bor (1 bsl Bit2) bor (1 bsl Bit3).

bloom_bit(<<Bits:16/integer, Rest/bitstring>>) ->
    {Bits band 2047, Rest}.

bloom_pop_bits(Bloom) ->
  pop_bits(Bloom,0,[]).

pop_bits(_,2048,A) -> A;
pop_bits(0,_,A) -> A;
pop_bits(I,N,A) when I band 1 == 1 ->
  pop_bits(I bsr 1, N+1,[N|A]);
pop_bits(I,N,A) ->
  pop_bits(I bsr 1, N+1,A).


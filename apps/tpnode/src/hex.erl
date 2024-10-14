-module(hex).
-export([encode/1, decode/1]).
-export([encodex/1]).
-export([parse/1]).

-export([hexdump/1]).
-export([hexdump/2]).

hexdump(Bin) ->
  dump(Bin,0).

%% hexdump/2 displays bin in two parts
hexdump(Bin,O) ->
  try
    <<B1:O/binary,B2/binary>> = Bin,
    dump(B1,0),
    dump(B2,0)
  catch _:_ ->
          dump(Bin,0)
  end.

dump(<<Bin:32/binary,Rest/binary>>,Off) ->
  io:format("~6.16B: ~s~n",[Off, hex:encode(Bin)]),
  dump(Rest,Off+32);
dump(Bin,Off) ->
  io:format("~6.16B: ~s~n",[Off,hex:encode(Bin)]).

parse(B) -> decode(B).

decode(B) when is_binary(B) ->
    decode(binary_to_list(B));

decode([$0, $x|L])  ->
    decode(L);

decode(L) when is_list(L) ->
    case length(L) rem 2 of
        0 -> ok;
        1 -> throw('bad_length')
    end,
    decode(string:to_lower(L), <<>>).

decode([], Acc) ->
    Acc;

decode([H1, H2|Rest], Acc) ->
    decode(Rest, <<Acc/binary, ((h2i(H1) bsl 4) bor h2i(H2))/integer>>).

h2i($0) -> 0;
h2i($1) -> 1;
h2i($2) -> 2;
h2i($3) -> 3;
h2i($4) -> 4;
h2i($5) -> 5;
h2i($6) -> 6;
h2i($7) -> 7;
h2i($8) -> 8;
h2i($9) -> 9;
h2i($a) -> 10;
h2i($b) -> 11;
h2i($c) -> 12;
h2i($d) -> 13;
h2i($e) -> 14;
h2i($f) -> 15;
h2i(Any) -> throw({'bad_symbol', Any}).

encodex(Integer) when is_integer(Integer) andalso Integer >=0 ->
  encode(binary:encode_unsigned(Integer),<<"0x">>);
encodex(List) when is_list(List) ->
    encode(list_to_binary(List),<<"0x">>);
encodex(B) when is_binary(B) ->
  encode(B, <<"0x">>).


encode(Integer) when is_integer(Integer) andalso Integer >=0 ->
  encode(binary:encode_unsigned(Integer),<<>>);
encode(List) when is_list(List) ->
    encode(list_to_binary(List),<<>>);
encode(B) when is_binary(B) ->
  encode(B, <<>>).

-define(H(X), (hex(X)):16).

encode(<<>>, Acc) -> Acc;
encode(<<X:8, Rest/binary>>, Acc) ->
  encode(Rest, <<Acc/binary, ?H(X)>>).

-compile({inline, [hex/1]}).
hex(X) ->
  element(
    X+1, {
16#3030, 16#3031, 16#3032, 16#3033, 16#3034, 16#3035, 16#3036, 16#3037,
16#3038, 16#3039, 16#3061, 16#3062, 16#3063, 16#3064, 16#3065, 16#3066,
16#3130, 16#3131, 16#3132, 16#3133, 16#3134, 16#3135, 16#3136, 16#3137,
16#3138, 16#3139, 16#3161, 16#3162, 16#3163, 16#3164, 16#3165, 16#3166,
16#3230, 16#3231, 16#3232, 16#3233, 16#3234, 16#3235, 16#3236, 16#3237,
16#3238, 16#3239, 16#3261, 16#3262, 16#3263, 16#3264, 16#3265, 16#3266,
16#3330, 16#3331, 16#3332, 16#3333, 16#3334, 16#3335, 16#3336, 16#3337,
16#3338, 16#3339, 16#3361, 16#3362, 16#3363, 16#3364, 16#3365, 16#3366,
16#3430, 16#3431, 16#3432, 16#3433, 16#3434, 16#3435, 16#3436, 16#3437,
16#3438, 16#3439, 16#3461, 16#3462, 16#3463, 16#3464, 16#3465, 16#3466,
16#3530, 16#3531, 16#3532, 16#3533, 16#3534, 16#3535, 16#3536, 16#3537,
16#3538, 16#3539, 16#3561, 16#3562, 16#3563, 16#3564, 16#3565, 16#3566,
16#3630, 16#3631, 16#3632, 16#3633, 16#3634, 16#3635, 16#3636, 16#3637,
16#3638, 16#3639, 16#3661, 16#3662, 16#3663, 16#3664, 16#3665, 16#3666,
16#3730, 16#3731, 16#3732, 16#3733, 16#3734, 16#3735, 16#3736, 16#3737,
16#3738, 16#3739, 16#3761, 16#3762, 16#3763, 16#3764, 16#3765, 16#3766,
16#3830, 16#3831, 16#3832, 16#3833, 16#3834, 16#3835, 16#3836, 16#3837,
16#3838, 16#3839, 16#3861, 16#3862, 16#3863, 16#3864, 16#3865, 16#3866,
16#3930, 16#3931, 16#3932, 16#3933, 16#3934, 16#3935, 16#3936, 16#3937,
16#3938, 16#3939, 16#3961, 16#3962, 16#3963, 16#3964, 16#3965, 16#3966,
16#6130, 16#6131, 16#6132, 16#6133, 16#6134, 16#6135, 16#6136, 16#6137,
16#6138, 16#6139, 16#6161, 16#6162, 16#6163, 16#6164, 16#6165, 16#6166,
16#6230, 16#6231, 16#6232, 16#6233, 16#6234, 16#6235, 16#6236, 16#6237,
16#6238, 16#6239, 16#6261, 16#6262, 16#6263, 16#6264, 16#6265, 16#6266,
16#6330, 16#6331, 16#6332, 16#6333, 16#6334, 16#6335, 16#6336, 16#6337,
16#6338, 16#6339, 16#6361, 16#6362, 16#6363, 16#6364, 16#6365, 16#6366,
16#6430, 16#6431, 16#6432, 16#6433, 16#6434, 16#6435, 16#6436, 16#6437,
16#6438, 16#6439, 16#6461, 16#6462, 16#6463, 16#6464, 16#6465, 16#6466,
16#6530, 16#6531, 16#6532, 16#6533, 16#6534, 16#6535, 16#6536, 16#6537,
16#6538, 16#6539, 16#6561, 16#6562, 16#6563, 16#6564, 16#6565, 16#6566,
16#6630, 16#6631, 16#6632, 16#6633, 16#6634, 16#6635, 16#6636, 16#6637,
16#6638, 16#6639, 16#6661, 16#6662, 16#6663, 16#6664, 16#6665, 16#6666

%16#3030, 16#3031, 16#3032, 16#3033, 16#3034, 16#3035, 16#3036,
%16#3037, 16#3038, 16#3039, 16#3041, 16#3042, 16#3043, 16#3044,
%16#3045, 16#3046, 16#3130, 16#3131, 16#3132, 16#3133, 16#3134,
%16#3135, 16#3136, 16#3137, 16#3138, 16#3139, 16#3141, 16#3142,
%16#3143, 16#3144, 16#3145, 16#3146, 16#3230, 16#3231, 16#3232,
%16#3233, 16#3234, 16#3235, 16#3236, 16#3237, 16#3238, 16#3239,
%16#3241, 16#3242, 16#3243, 16#3244, 16#3245, 16#3246, 16#3330,
%16#3331, 16#3332, 16#3333, 16#3334, 16#3335, 16#3336, 16#3337,
%16#3338, 16#3339, 16#3341, 16#3342, 16#3343, 16#3344, 16#3345,
%16#3346, 16#3430, 16#3431, 16#3432, 16#3433, 16#3434, 16#3435,
%16#3436, 16#3437, 16#3438, 16#3439, 16#3441, 16#3442, 16#3443,
%16#3444, 16#3445, 16#3446, 16#3530, 16#3531, 16#3532, 16#3533,
%16#3534, 16#3535, 16#3536, 16#3537, 16#3538, 16#3539, 16#3541,
%16#3542, 16#3543, 16#3544, 16#3545, 16#3546, 16#3630, 16#3631,
%16#3632, 16#3633, 16#3634, 16#3635, 16#3636, 16#3637, 16#3638,
%16#3639, 16#3641, 16#3642, 16#3643, 16#3644, 16#3645, 16#3646,
%16#3730, 16#3731, 16#3732, 16#3733, 16#3734, 16#3735, 16#3736,
%16#3737, 16#3738, 16#3739, 16#3741, 16#3742, 16#3743, 16#3744,
%16#3745, 16#3746, 16#3830, 16#3831, 16#3832, 16#3833, 16#3834,
%16#3835, 16#3836, 16#3837, 16#3838, 16#3839, 16#3841, 16#3842,
%16#3843, 16#3844, 16#3845, 16#3846, 16#3930, 16#3931, 16#3932,
%16#3933, 16#3934, 16#3935, 16#3936, 16#3937, 16#3938, 16#3939,
%16#3941, 16#3942, 16#3943, 16#3944, 16#3945, 16#3946, 16#4130,
%16#4131, 16#4132, 16#4133, 16#4134, 16#4135, 16#4136, 16#4137,
%16#4138, 16#4139, 16#4141, 16#4142, 16#4143, 16#4144, 16#4145,
%16#4146, 16#4230, 16#4231, 16#4232, 16#4233, 16#4234, 16#4235,
%16#4236, 16#4237, 16#4238, 16#4239, 16#4241, 16#4242, 16#4243,
%16#4244, 16#4245, 16#4246, 16#4330, 16#4331, 16#4332, 16#4333,
%16#4334, 16#4335, 16#4336, 16#4337, 16#4338, 16#4339, 16#4341,
%16#4342, 16#4343, 16#4344, 16#4345, 16#4346, 16#4430, 16#4431,
%16#4432, 16#4433, 16#4434, 16#4435, 16#4436, 16#4437, 16#4438,
%16#4439, 16#4441, 16#4442, 16#4443, 16#4444, 16#4445, 16#4446,
%16#4530, 16#4531, 16#4532, 16#4533, 16#4534, 16#4535, 16#4536,
%16#4537, 16#4538, 16#4539, 16#4541, 16#4542, 16#4543, 16#4544,
%16#4545, 16#4546, 16#4630, 16#4631, 16#4632, 16#4633, 16#4634,
%16#4635, 16#4636, 16#4637, 16#4638, 16#4639, 16#4641, 16#4642,
%16#4643, 16#4644, 16#4645, 16#4646
}).

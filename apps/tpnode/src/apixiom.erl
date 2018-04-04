-module(apixiom).
-export([bodyjs/1, body_data/1]).
-export([init/2]).

%% API
init(Req0, {Target, Opts}) ->
    Method = cowboy_req:method(Req0),
    {Format, Req1} = get_format(Req0),
    Path = cowboy_req:path_info(Req1),
%%    lager:info("request: ~p ~p", [Format, Req1]),
    PRes = handle_request(Method, Path, Req1, Target, Format, Opts),
    Req2 =
        case erlang:function_exported(Target, before_filter, 1) of
            true ->
                Target:before_filter(Req1);
            false ->
                Req1
        end,
    {Status, Body, ResReq} = process_response(PRes, Format, Req2),
    Response =
        case erlang:function_exported(Target, after_filter, 1) of
            true ->
                Target:after_filter(ResReq);
            false ->
                ResReq
        end,
    %lager:debug("Res ~p", [Response]),
    {ok, cowboy_req:reply(Status, #{}, Body, Response), Opts}.

bodyjs(Req) ->
    maps:get(request_data, Req, undefined).

body_data(Req) ->
    bodyjs(Req).

%% Internals

get_format(#{<<"content-type">> := <<"application/msgpack">>} = Req) ->
    {<<"msgpack">>, Req};

get_format(#{<<"content-type">> := <<"application/json">>} = Req) ->
    {<<"json">>, Req};

get_format(Req) ->
    Path = cowboy_req:path(Req),
    PathInfo = cowboy_req:path_info(Req),
    PathInfoLast = lists:last(PathInfo),
    PathSplit = binary:split(PathInfoLast, <<".">>, [global]),
    if
        length(PathSplit) > 1 ->
            Format = lists:last(PathSplit),
            NewPath = binary:part(Path, 0, byte_size(Path) - byte_size(Format) - 1),
            NewPathInfoLast =
                binary:part(PathInfoLast, 0, byte_size(PathInfoLast) - byte_size(Format) - 1),
            NewPathInfo = lists:droplast(PathInfo) ++ [NewPathInfoLast],

            {Format, Req#{
                path => NewPath,
                path_info => NewPathInfo
            }};
        true ->
            {<<"json">>, Req}
    end.


handle_request(Method, Path, Req, Target, Format, _Opts) ->
	try
        Req1 =
            case Format of
                <<"json">> ->
                    parse_reqjs(Req);
                <<"msgpack">> ->
                    parse_msgpack(Req);
                _ ->
                    Req
               end,
        Target:h(Method, Path, Req1)
	catch
		throw:{return, Code, MSG} when is_list(MSG) ->
			{Code, #{error=>list_to_binary(MSG)}};
		throw:{return, Code, MSG} ->
			{Code, #{error=>MSG}};
		throw:{return, MSG} when is_list(MSG) ->
			{500, #{error=>list_to_binary(MSG)}};
		throw:{return, MSG} ->
			{500, #{error=>MSG}};
		error:function_clause ->
			case erlang:get_stacktrace() of
%				[{Target, h, _, _}|_] ->
				[{_, h, _, _}|_] ->
					ReqPath = cowboy_req:path(Req),
					{404, #{
                        error=><<"not found">>,
                        format=>Format,
                        path=>ReqPath,
                        method=>Method,
                        p=>Path}
                    };
%				[{_, h, [Method, Path, _], _}|_] ->
%					ReqPath = cowboy_req:path(Req),
%					{404, #{error=><<"not found">>, path=>ReqPath, method=>Method, p=>Path}};
				Stack ->
                    ST = format_stack(Stack),
                    {500, #{
                        error=>unknown_fc,
                        format => Format,
                        ecee=><<"error:function_clause">>,
                        stack=>ST}
                    }
			end;
		Ec:Ee ->
			EcEe=iolist_to_binary(io_lib:format("~p:~p", [Ec, Ee])),
                        ST=format_stack(erlang:get_stacktrace()),
			{500, #{error=>unknown, format=>Format, ecee=>EcEe, stack=>ST}}
	end.

format_stack(Stack) ->
    FormatAt=fun(PL) ->
                     try
                         File=proplists:get_value(file, PL),
                         Line=proplists:get_value(line, PL),
                         iolist_to_binary(io_lib:format("~s:~w", [File, Line]))
                     catch _:_ ->
                               iolist_to_binary(io_lib:format("~p", [PL]))
                     end
             end,
    lists:map(
      fun
          ({M, F, A, FL}) when is_list(A)->
              #{ mfa=>iolist_to_binary(io_lib:format("~p:~p(~p)", [M, F, A])),
                 at=> FormatAt(FL)
               };
          ({M, F, A, FL}) when is_integer(A)->
              #{ mf=>iolist_to_binary(io_lib:format("~p:~p/~w", [M, F, A])),
                 at=> FormatAt(FL)
               };
          (SE) ->
              iolist_to_binary(io_lib:format("~p", [SE]))
      end, Stack).


process_response({Status, [], Body}, Format, Req)
    when is_integer(Status) ->
    process_response({Status, Body}, Format, Req);

process_response({Status, [{Hdr, Val}|Headers], Body}, Format, Req)
    when is_integer(Status) ->
    %lager:debug("resp ~p: ~p", [Hdr, Val]),
    process_response(
        {Status, Headers, Body},
        Format,
        cowboy_req:set_resp_header(Hdr, Val, Req)
    );

process_response({Status, Body}, <<"mp">> = _Format, Req) ->
    process_response({Status, Body}, <<"msgpack">>, Req);

process_response({Status, Body}, <<"msgpack">> = Format, Req)
    when is_integer(Status) andalso is_map(Body) ->
    process_response({Status,
        [{<<"Content-Type">>, <<"application/msgpack">>}],
        msgpack:pack(Body)
    }, Format, Req);

%% json is default answer format
process_response({Status, Body}, Format, Req)
    when is_integer(Status) andalso is_map(Body) ->
    process_response({Status,
        [{<<"Content-Type">>, <<"application/json">>}],
        jsx:encode(Body)
    }, Format, Req);

process_response({Status, Body}, _Format, Req)
    when is_integer(Status) andalso is_binary(Body) ->
    {Status, Body, Req};

process_response({Status, Body}, _Format, Req)
    when is_integer(Status) andalso is_list(Body) ->
    {Status, Body, Req};

process_response({Req, Status, Body}, _Format, _XReq)
    when is_integer(Status) andalso is_binary(Body) ->
    {Status, Body, Req};

process_response({Req, Status, Body}, _Format, _XReq)
    when is_integer(Status) andalso is_list(Body) ->
    {Status, Body, Req}.

parse_reqjs(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            try
                {ok, ReqBody, NewReq} = cowboy_req:read_body(Req),
                ReqJSON=jsx:decode(ReqBody, [return_maps]),
                maps:put(request_data, ReqJSON, NewReq)
            catch _:_ ->
                lager:error("json parse error: ~p", [Req]),
                throw({return, "invalid json"})
            end;
        _ ->
            Req
    end.


parse_msgpack(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            try
                {ok, ReqBody, NewReq} = cowboy_req:read_body(Req),
                ReqData = msgpack:unpack(ReqBody, [{unpack_str, as_binary}]),
                maps:put(request_data, ReqData, NewReq)
            catch _:_ ->
                lager:error("msgpack parse error: ~p", [Req]),
                throw({return, "invalid msgpack"})
            end;
        _ ->
            Req
    end.

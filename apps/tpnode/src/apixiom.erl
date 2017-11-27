-module(apixiom).
-export([bodyjs/1]).
-export([init/2]).

%% API

init(Req0, {Target, Opts}) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    Req1=parse_reqjs(Req0),
    PRes=handle_json(Method, Path, Req1, Target, Opts),
    {Status,Body,ResReq}=process_response(PRes,Req1),
    Response=case erlang:function_exported(Target,after_filter,1) of
                 true ->
                     Target:after_filter(ResReq);
                 false ->
                     ResReq
             end,
    %lager:debug("Res ~p",[Response]),
    {ok, cowboy_req:reply(Status, #{}, Body, Response), Opts}.

bodyjs(Req) ->
	maps:get(request_json, Req, undefined).

%% Internals

handle_json(Method, Path, Req, Target, _Opts) ->
	try
		Target:h(Method,Path, Req)
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
%				[{Target,h,_,_}|_] ->
				[{_,h,_,_}|_] ->
					ReqPath = cowboy_req:path(Req),
					{404, #{error=><<"not found">>,path=>ReqPath,method=>Method,p=>Path}};
%				[{_,h,[Method,Path,_],_}|_] ->
%					ReqPath = cowboy_req:path(Req),
%					{404, #{error=><<"not found">>,path=>ReqPath,method=>Method,p=>Path}};
				Stack ->
					ST=iolist_to_binary(io_lib:format("~p",[Stack])),
					{400, #{error=>unknown_fc,ecee=><<"error:function_clause">>,stack=>ST}}
			end;
		Ec:Ee ->
			EcEe=iolist_to_binary(io_lib:format("~p:~p",[Ec,Ee])),
			ST=iolist_to_binary(io_lib:format("~p",[erlang:get_stacktrace()])),
			{400, #{error=>unknown,ecee=>EcEe,stack=>ST}}
	end.


process_response({Status, [], Body}, Req) when is_integer(Status) ->
    process_response({Status, Body}, Req);

process_response({Status, [{Hdr,Val}|Headers], Body}, Req) when is_integer(Status) ->
    %lager:debug("resp ~p: ~p",[Hdr,Val]),
    process_response(
      {Status, Headers, Body}, 
      cowboy_req:set_resp_header(Hdr, Val, Req)
     );

process_response({Status, Body}, Req) when is_integer(Status) andalso is_map(Body) ->
	process_response({Status, 
                          [{<<"Content-Type">>, <<"application/json">>}], 
                          jsx:encode(Body)
                         }, Req);

process_response({Status, Body}, Req) when is_integer(Status) andalso is_binary(Body) ->
    {Status, Body, Req};

process_response({Status, Body}, Req) when is_integer(Status) andalso is_list(Body) ->
    {Status, Body, Req};

process_response({Req, Status, Body}, _xReq) when is_integer(Status) andalso is_binary(Body) ->
    {Status, Body, Req};

process_response({Req, Status, Body}, _xReq) when is_integer(Status) andalso is_list(Body) ->
    {Status, Body, Req}.

parse_reqjs(Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> ->
            try
                {ok, ReqBody, NewReq} = cowboy_req:read_body(Req),
                ReqJSON=jsx:decode(ReqBody,[return_maps]),
                maps:put(request_json, ReqJSON, NewReq)
            catch _:_ -> 
                      maps:put(request_json, #{}, Req)
            end;
        _ ->
            Req
    end.


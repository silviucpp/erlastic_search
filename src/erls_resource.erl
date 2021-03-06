%%%-------------------------------------------------------------------
%%% @author Tristan Sloughter <>
%%% @copyright (C) 2010, Tristan Sloughter
%%% @doc
%%% Thanks couchbeam! http://github.com/benoitc/couchbeam
%%% From which most of this was taken :)
%%%
%%% @end
%%% Created : 14 Feb 2010 by Tristan Sloughter <>
%%%-------------------------------------------------------------------
-module(erls_resource).

-export([get/5
        ,get/6
        ,head/5
        ,delete/5
        ,delete/6
        ,post/6
        ,put/6]).

-include("erlastic_search.hrl").
-include("erlastic_search_internal.hrl").

get(State, Path, Headers, Params, Opts) ->
    request(State, get, Path, Headers, Params, [], Opts).

get(State, Path, Headers, Params, Body, Opts) ->
    request(State, get, Path, Headers, Params, Body, Opts).

head(State, Path, Headers, Params, Opts) ->
    request(State, head, Path, Headers, Params, [], Opts).

delete(State, Path, Headers, Params, Opts) ->
    request(State, delete, Path, Headers, Params, [], Opts).

delete(State, Path, Headers, Params, Body, Opts) ->
    request(State, delete, Path, Headers, Params, Body, Opts).

post(State, Path, Headers, Params, Body, Opts) ->
    request(State, post, Path, Headers, Params, Body, Opts).

put(State, Path, Headers, Params, Body, Opts) ->
    request(State, put, Path, Headers, Params, Body, Opts).

request(State, Method, Path, Headers, Params, Body, Options) ->
    Path1 = <<Path/binary,
              (case Params of
                  [] -> <<>>;
                  Props -> <<"?", (encode_query(Props))/binary>>
              end)/binary>>,
    {Headers2, Options1, Body} = make_body(Body, Headers, Options),
    Headers3 = default_header(<<"Content-Type">>, <<"application/json">>, Headers2),
    do_request(State, Method, Path1, Headers3, Body, Options1).

do_request(#erls_params{host=Host, port=Port, timeout=Timeout, ctimeout=CTimeout},
           Method, Path, Headers, Body, Options) ->
    % Ugly, but to keep backwards compatibility: add recv_timeout and
    % connect_timeout when *not* present in Options.
    NewOptions = lists:foldl(
        fun({BCOpt, Value}, Acc) ->
            case proplists:get_value(BCOpt, Acc) of
                undefined -> [{BCOpt, Value}|Acc];
                _ -> Acc
            end
        end,
        Options,
        [{recv_timeout, Timeout}, {connect_timeout, CTimeout}]
    ),

    RequestUrl = <<Host/binary, ":", (list_to_binary(integer_to_list(Port)))/binary, "/", Path/binary>>,
    StartTsMs = erls_utils:now_ms(),

    case hackney:request(Method, RequestUrl, Headers, Body, NewOptions) of
        {ok, Status, _Headers, Client} when Status =:= 200; Status =:= 201 ->
            case hackney:body(Client) of
                {ok, RespBody} ->
                    should_debug_query(ok, StartTsMs, Method, RequestUrl, Headers, Body, NewOptions),
                    {ok, erls_json:decode(RespBody)};
                {error, _Reason} = Error ->
                    should_debug_query(Error, StartTsMs, Method, RequestUrl, Headers, Body, NewOptions),
                    Error
            end;
        {ok, Status, _Headers, Client} ->
            Error = case hackney:body(Client) of
                {ok, RespBody} ->
                    {error, {Status, erls_json:decode(RespBody)}};
                {error, _Reason} ->
                    {error, Status}
            end,
            should_debug_query(Error, StartTsMs, Method, RequestUrl, Headers, Body, NewOptions),
            Error;
        {ok, 200, _Headers} ->
            %% we hit this case for HEAD requests, or more generally when
            %% there's no response body
            ok;
        {ok, Not200, _Headers} ->
            should_debug_query({error, Not200}, StartTsMs, Method, RequestUrl, Headers, Body, NewOptions),
            {error, Not200};
        {ok, ClientRef} ->
            %% that's when the options passed to hackney included `async'
            %% this reference can then be used to match the messages from
            %% hackney when ES replies; see the hackney doc for more information
            {ok, {async, ClientRef}};
        {error, R} ->
            should_debug_query({error, R}, StartTsMs, Method, RequestUrl, Headers, Body, NewOptions),
            {error, R}
    end.

should_debug_query(Response, StartTs, Method, RequestUrl, Headers, Body, ClientOptions) ->
    ElapsedTs = erls_utils:now_ms() - StartTs,
    SlowQThreshold = erls_config:get_slow_query_threshold(),

    case Response of
        ok ->
            case SlowQThreshold =/= false andalso ElapsedTs >= SlowQThreshold of
                true ->
                    ?WARNING_MSG("ELS slow query (~p ms) -> ~p ~p headers: ~p body: ~p client_opt: ~p response: ~p", [ElapsedTs, Method, RequestUrl, Headers, Body, ClientOptions, Response]);
                    _ ->
                    ok
            end;
        _ ->
            ?ERROR_MSG("ELS error -> ~p ~p headers: ~p body: ~p client_opt: ~p response: ~p elapsed: ~p ms", [Method, RequestUrl, Headers, Body, ClientOptions, Response, ElapsedTs])
    end.

encode_query(Props) ->
    P = fun({A,B}, AccIn) -> io_lib:format("~s=~s&", [A,B]) ++ AccIn end,
    iolist_to_binary((lists:foldr(P, [], Props))).

default_header(K, V, H) ->
    case proplists:is_defined(K, H) of
        true -> H;
        false -> [{K, V}|H]
    end.

default_content_length(B, H) ->
    default_header(<<"Content-Length">>, list_to_binary(integer_to_list(erlang:iolist_size(B))), H).

make_body(Body, Headers, Options) ->
    {default_content_length(Body, Headers), Options, Body}.

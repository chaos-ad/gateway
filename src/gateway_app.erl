-module(gateway_app).
-behaviour(application).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([start/2, stop/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(_StartType, _StartArgs) ->
    {ok, Pid} = gateway_sup:start_link(),
    start_listeners(),
    {ok, Pid}.

stop(_State) ->
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_listeners() ->
    case application:get_env(gateway, protocols) of
        undefined -> lager:warning("No protocols are enabled, gateway will be useless");
        {ok, []}  -> lager:warning("No protocols are enabled, gateway will be useless");
        {ok, Protocols} ->
            [ start_listeners(Proto, Opts) || {Proto, Opts} <- Protocols ]
    end.

start_listeners(tcp, Options) ->
    Host = proplists:get_value(bind_host, Options, {0,0,0,0}),
    Port = proplists:get_value(bind_port, Options, 5555),
    Pool = proplists:get_value(acceptors, Options, 5),
    ranch:start_listener(
        tcp, Pool,
        ranch_tcp, [{ip, Host},{port, Port}],
        gateway_tcp_connection, Options
    );

start_listeners(websockets, Options) ->
    Host = proplists:get_value(bind_host, Options, {0,0,0,0}),
    Port = proplists:get_value(bind_port, Options, 8081),
    Pool = proplists:get_value(acceptors, Options, 5),
    Dispatch = cowboy_router:compile([
        {'_', [{"/websocket", gateway_ws_connection, Options}]}
    ]),
    cowboy:start_http(
        websockets, Pool,
        [{ip, Host},{port, Port}],
        [{env, [{dispatch, Dispatch}]}]
    ).

-module(gateway_ws_connection).
-behaviour(cowboy_websocket_handler).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

-compile(export_all).

-include("piqi/gateway_piqi.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    userid,
    endpoint,
    state_name,
    sid2pid = dict:new(),
    pid2sid = dict:new()
}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

websocket_init(_TransportName, Req, Options) ->
    {{IP, Port}, _} = cowboy_req:peer(Req),
    Endpoint = lists:flatten(io_lib:format("~s:~B", [inet_parse:ntoa(IP), Port])),
    lager:debug("['~s']: accepted", [Endpoint]),
    Timeout = proplists:get_value(auth_timeout, Options, 5000),
    erlang:send_after(Timeout, self(), timeout),
    {ok, Req, #state{endpoint=Endpoint, state_name=authenticating}}.

websocket_handle(RequestRaw, Req, State=#state{endpoint=Endpoint, userid=undefined, state_name=StateName}) ->
    lager:debug("['~s']: request received: ~p", [Endpoint, RequestRaw]),
    Request = decode(RequestRaw),
    lager:debug("['~s']: request parsed: ~p", [Endpoint, Request]),
    ?MODULE:StateName(Request, Req, State);

websocket_handle(RequestRaw, Req, State=#state{endpoint=Endpoint, userid=UserID, state_name=StateName}) ->
    lager:debug("['~s']['~s']: request received: ~p", [Endpoint, UserID, RequestRaw]),
    Request = decode(RequestRaw),
    lager:debug("['~s']['~s']: request received: ~p", [Endpoint, UserID, Request]),
    ?MODULE:StateName(Request, Req, State).

websocket_info(Info, Req, State=#state{state_name=StateName}) ->
    ?MODULE:StateName(Info, Req, State).

websocket_terminate(Reason, _Req, #state{endpoint=Endpoint, userid=undefined}) ->
    lager:debug("['~s']: terminated: ~p", [Endpoint, Reason]);

websocket_terminate(Reason, _Req, #state{endpoint=Endpoint, userid=UserID}) ->
    lager:debug("['~s']['~s']: terminated: ~p", [Endpoint, UserID, Reason]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

authenticating({FrameType, {login, #login{userid=UserID, passwd=Passwd}}}, Req,
        State=#state{endpoint=Endpoint}) ->
    try
        lager:debug("['~s']: logging in as '~s'...", [Endpoint, UserID]),
        ok = gateway_auth:login(UserID, Passwd),
        ResponseRaw = encode({FrameType, ok}),
        lager:debug("['~s']: logging in as '~s': ok", [Endpoint, UserID]),
        {reply, ResponseRaw, Req, State#state{userid=UserID, state_name=authenticated}}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']: logging in as '~s': ~s", [Endpoint, UserID, Message]),
            self() ! shutdown,
            {reply, encode({FrameType, {error, Error}}), Req, State};
        throw:Error ->
            lager:error("['~s']: logging in as '~s': ~p", [Endpoint, UserID, Error]),
            self() ! shutdown,
            {reply, encode({FrameType, {error, Error}}), Req, State};
        _:Error ->
            Args = [Endpoint, UserID, Error, erlang:get_stacktrace()],
            lager:error("['~s']: logging in as '~s': ~p is thrown from ~p", Args),
            self() ! shutdown,
            {reply, encode({FrameType, {error, Error}}), Req, State}
    end;

authenticating(timeout, Req, State) ->
    {shutdown, Req, State};

authenticating(shutdown, Req, State) ->
    {shutdown, Req, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

authenticated({FrameType, {_, #service_enable{service=ServiceID}}}, Req,
        State=#state{endpoint=Endpoint, userid=UserID}) ->
    try
        lager:debug("['~s']['~s']: enabling service '~s'...", [Endpoint, UserID, ServiceID]),
        {ok, NewState} = enable_service(ServiceID, State),
        ResponseRaw = encode({FrameType, ok}),
        lager:debug("['~s']['~s']: enabling service '~s': ok", [Endpoint, UserID, ServiceID]),
        {reply, ResponseRaw, Req, NewState}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']['~s']: enabling service '~s': ~s", [Endpoint, UserID, ServiceID, Message]),
            {reply, encode({FrameType, {error, Error}}), Req, State};
        throw:Error ->
            lager:error("['~s']['~s']: enabling service '~s': ~p", [Endpoint, UserID, ServiceID, Error]),
            {reply, encode({FrameType, {error, Error}}), Req, State};
        _:Error ->
            Args = [Endpoint, UserID, ServiceID, Error, erlang:get_stacktrace()],
            lager:error("['~s']['~s']: enabling service '~s': ~p is thrown from ~p", Args),
            {reply, encode({FrameType, {error, Error}}), Req, State}
    end;

authenticated({FrameType, {_, #service_disable{service=ServiceID}}}, Req,
        State=#state{endpoint=Endpoint, userid=UserID}) ->
    try
        lager:debug("['~s']['~s']: disabling service '~s'...", [Endpoint, UserID, ServiceID]),
        {ok, NewState} = disable_service(ServiceID, State),
        ResponseRaw = encode({FrameType, ok}),
        lager:debug("['~s']['~s']: disabling service '~s': ok", [Endpoint, UserID, ServiceID]),
        {reply, ResponseRaw, Req, NewState}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']['~s']: disabling service '~s': ~s", [Endpoint, UserID, ServiceID, Message]),
            {reply, encode({FrameType, {error, Error}}), Req, State};
        throw:Error ->
            lager:error("['~s']['~s']: disabling service '~s': ~p", [Endpoint, UserID, ServiceID, Error]),
            {reply, encode({FrameType, {error, Error}}), Req, State};
        _:Error ->
            Args = [Endpoint, UserID, ServiceID, Error, erlang:get_stacktrace()],
            lager:error("['~s']['~s']: disabling service '~s': ~p is thrown from ~p", Args),
            {reply, encode({FrameType, {error, Error}}), Req, State}
    end;

authenticated({FrameType, {_, #service_request{service=ServiceID, payload=Request}}}, Req,
    State=#state{endpoint=Endpoint, userid=UserID}) ->
    try
        lager:debug("['~s']['~s']: dispatching request to '~s'...", [Endpoint, UserID, ServiceID]),
        {ok, Response, NewState} = dispatch_request(ServiceID, Request, State),
        ResponseRaw = encode({FrameType, Response}),
        lager:debug("['~s']['~s']: dispatching request to '~s': ok", [Endpoint, UserID, ServiceID]),
        {reply, ResponseRaw, Req, NewState}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']['~s']: dispatching request to '~s': ~s", [Endpoint, UserID, ServiceID, Message]),
            {reply, encode({FrameType, {error, Error}}), Req, State};
        throw:Error ->
            lager:error("['~s']['~s']: dispatching request to '~s': ~p", [Endpoint, UserID, ServiceID, Error]),
            {reply, encode({FrameType, {error, Error}}), Req, State};
        _:Error ->
            Args = [Endpoint, UserID, ServiceID, Error, erlang:get_stacktrace()],
            lager:error("['~s']['~s']: dispatching request to '~s': ~p is thrown from ~p", Args),
            {reply, encode({FrameType, {error, Error}}), Req, State}
    end;

authenticated({event, ServiceID, Payload}, Req, State) ->
    ServiceEvent = #service_event{service=ServiceID, payload=Payload},
    Packet = {service_event, ServiceEvent},
    {reply, encode({text, Packet}), Req, State};

authenticated({'EXIT', ServicePid, Reason}, Req, State=#state{endpoint=Endpoint, userid=UserID}) ->
    case dict:find(ServicePid, State#state.pid2sid) of
        error -> {ok, Req, State};
        {ok, ServiceID} ->
            lager:debug("['~s']['~s']: service '~s' disabled with reason ~p", [Endpoint, UserID, ServiceID, Reason]),
            NewState = State#state{
                sid2pid = dict:erase(ServiceID, State#state.sid2pid),
                pid2sid = dict:erase(ServicePid, State#state.pid2sid)
            },
            {reply, encode({text, {gateway_event, {service_disabled, ServiceID}}}), Req, NewState}
    end;

authenticated(timeout, Req, State) ->
    {ok, Req, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

enable_service(ServiceID, State=#state{userid=UserID}) ->
    case dict:find(ServiceID, State#state.sid2pid) of
        {ok, _} -> throw({service_enabled, <<"service enabled">>});
        error ->
            case pg2:get_closest_pid({service, ServiceID}) of
                {error, {no_such_group, _}} -> throw({service_unknown, <<"service unknown">>});
                {error, {no_process, _}} -> throw({service_unavailable, <<"service unavailable">>});
                ServicePid ->
                    {ok, Result} = gen:call(ServicePid, login, [UserID, self(), [{encoding, json}]]),
                    case Result of
                        {error, Error} -> throw(Error);
                        {ok, ResultPid} ->
                            erlang:link(ResultPid),
                            {ok, State#state{
                                sid2pid = dict:store(ServiceID, ResultPid, State#state.sid2pid),
                                pid2sid = dict:store(ResultPid, ServiceID, State#state.pid2sid)
                            }}
                    end
            end
    end.

disable_service(ServiceID, State=#state{}) ->
    case dict:find(ServiceID, State#state.sid2pid) of
        error -> throw({service_disabled, <<"service disabled">>});
        {ok, ServicePid} when is_pid(ServicePid) ->
            erlang:unlink(ServicePid),
            exit(ServicePid, shutdown),
            {ok, State#state{
                sid2pid = dict:erase(ServiceID, State#state.sid2pid),
                pid2sid = dict:erase(ServicePid, State#state.pid2sid)
            }}
    end.

dispatch_request(ServiceID, Request, State=#state{}) ->
    case dict:find(ServiceID, State#state.sid2pid) of
        error -> throw({service_disabled, <<"service disabled">>});
        {ok, ServicePid} when is_pid(ServicePid) ->
            {ok, Reply} = gen:call(ServicePid, request, Request),
            case Reply of
                ok             -> {ok, ok, State};
                {ok, Response} -> {ok, {service_response, Response}, State};
                {error, Error} -> throw(Error)
            end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

decode({FrameType, Data}) ->
    {FrameType, gateway_piqi:parse_client2gateway(Data, format(FrameType), [])}.

encode({FrameType, {error, Error}}) ->
    try
        {FrameType, gateway_piqi:gen_gateway2client({error, Error}, format(FrameType), [])}
    catch
        _:_ ->
            {FrameType, gateway_piqi:gen_gateway2client({error, internal_error}, format(FrameType), [])}
    end;
encode({FrameType, Data}) ->
    {FrameType, gateway_piqi:gen_gateway2client(Data, format(FrameType), [])}.

format(text) -> json;
format(binary) -> pb.

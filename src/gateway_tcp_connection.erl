-module(gateway_tcp_connection).
-behaviour(gen_fsm).
-behaviour(ranch_protocol).

-include("piqi/gateway_piqi.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_fsm callbacks:
-export([init/1, handle_info/3, handle_event/3, handle_sync_event/4, terminate/3, code_change/4]).
-export([authenticating/2, authenticated/2]).

%% ranch_protocol callbacks:
-export([start_link/4]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    userid,
    socket,
    endpoint,
    transport,
    sid2pid = dict:new(),
    pid2sid = dict:new()
}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(ListenerPid, Socket, Transport, Opts) ->
    proc_lib:start_link(?MODULE, init, [[ListenerPid, Socket, Transport, Opts]]).

init([ListenerPid, Socket, Transport, Options]) ->
    process_flag(trap_exit, true),
    ok = proc_lib:init_ack({ok, self()}),
    ok = ranch:accept_ack(ListenerPid),
    Transport:setopts(Socket, [binary, {packet, 4}, {active, once}]),
    {ok, {IP, Port}} = Transport:peername(Socket),
    Endpoint = lists:flatten(io_lib:format("~s:~B", [inet_parse:ntoa(IP), Port])),
    lager:debug("['~s']: accepted", [Endpoint]),
    State = #state{socket=Socket, transport=Transport, endpoint=Endpoint},
    Timeout = proplists:get_value(auth_timeout, Options, 5000),
    gen_fsm:enter_loop(?MODULE, [], authenticating, State, Timeout).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

authenticating({request, {_, #login{userid=UserID, passwd=Passwd}}},
        State=#state{endpoint=Endpoint}) ->
    try
        lager:debug("['~s']: logging in as '~s'...", [Endpoint, UserID]),
        ok = gateway_auth:login(UserID, Passwd),
        ok = send(ok, State),
        lager:debug("['~s']: logging in as '~s': ok", [Endpoint, UserID]),
        {next_state, authenticated, State#state{userid=UserID}}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']: logging in as '~s': ~s", [Endpoint, UserID, Message]),
            send_error(Error, State),
            {stop, {shutdown, Error}, State};
        throw:Error ->
            lager:error("['~s']: logging in as '~s': ~p", [Endpoint, UserID, Error]),
            send_error(Error, State),
            {stop, {shutdown, Error}, State};
        _:Error ->
            Args = [Endpoint, UserID, Error, erlang:get_stacktrace()],
            lager:error("['~s']: logging in as '~s': ~p is thrown from ~p", Args),
            send_error(Error, State),
            {stop, {shutdown, Error}, State}
    end;

authenticating(timeout, State=#state{}) ->
    {stop, {shutdown, timeout}, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

authenticated({request, {_, #service_enable{service=ServiceID}}},
        State=#state{endpoint=Endpoint, userid=UserID}) ->
    try
        lager:debug("['~s']['~s']: enabling service '~s'...", [Endpoint, UserID, ServiceID]),
        {ok, NewState} = enable_service(ServiceID, State),
        send(ok, NewState),
        lager:debug("['~s']['~s']: enabling service '~s': ok", [Endpoint, UserID, ServiceID]),
        {next_state, authenticated, NewState}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']['~s']: enabling service '~s': ~s", [Endpoint, UserID, ServiceID, Message]),
            send_error(Error, State),
            {next_state, authenticated, State};
        throw:Error ->
            lager:error("['~s']['~s']: enabling service '~s': ~p", [Endpoint, UserID, ServiceID, Error]),
            send_error(Error, State),
            {next_state, authenticated, State};
        _:Error ->
            Args = [Endpoint, UserID, ServiceID, Error, erlang:get_stacktrace()],
            lager:error("['~s']['~s']: enabling service '~s': ~p is thrown from ~p", Args),
            send_error(Error, State),
            {next_state, authenticated, State}
    end;

authenticated({request, {_, #service_disable{service=ServiceID}}},
        State=#state{endpoint=Endpoint, userid=UserID}) ->
    try
        lager:debug("['~s']['~s']: disabling service '~s'...", [Endpoint, UserID, ServiceID]),
        {ok, NewState} = disable_service(ServiceID, State),
        send(ok, NewState),
        lager:debug("['~s']['~s']: disabling service '~s': ok", [Endpoint, UserID, ServiceID]),
        {next_state, authenticated, NewState}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']['~s']: disabling service '~s': ~s", [Endpoint, UserID, ServiceID, Message]),
            send_error(Error, State),
            {next_state, authenticated, State};
        throw:Error ->
            lager:error("['~s']['~s']: disabling service '~s': ~p", [Endpoint, UserID, ServiceID, Error]),
            send_error(Error, State),
            {next_state, authenticated, State};
        _:Error ->
            Args = [Endpoint, UserID, ServiceID, Error, erlang:get_stacktrace()],
            lager:error("['~s']['~s']: disabling service '~s': ~p is thrown from ~p", Args),
            send_error(Error, State),
            {next_state, authenticated, State}
    end;

authenticated({request, {_, #service_request{service=ServiceID, payload=Request}}},
    State=#state{endpoint=Endpoint, userid=UserID}) ->
    try
        lager:debug("['~s']['~s']: dispatching request to '~s'...", [Endpoint, UserID, ServiceID]),
        {ok, Response, NewState} = dispatch_request(ServiceID, Request, State),
        send(Response, NewState),
        lager:debug("['~s']['~s']: dispatching request to '~s': ok", [Endpoint, UserID, ServiceID]),
        {next_state, authenticated, NewState}
    catch
        throw:{Error, Message} when is_atom(Error), is_binary(Message) ->
            lager:error("['~s']['~s']: dispatching request to '~s': ~s", [Endpoint, UserID, ServiceID, Message]),
            send_error(Error, State),
            {next_state, authenticated, State};
        throw:Error ->
            lager:error("['~s']['~s']: dispatching request to '~s': ~p", [Endpoint, UserID, ServiceID, Error]),
            send_error(Error, State),
            {next_state, authenticated, State};
        _:Error ->
            Args = [Endpoint, UserID, ServiceID, Error, erlang:get_stacktrace()],
            lager:error("['~s']['~s']: dispatching request to '~s': ~p is thrown from ~p", Args),
            send_error(Error, State),
            {next_state, authenticated, State}
    end;

authenticated({event, ServiceID, Payload}, State) ->
    send({service_event, #service_event{service=ServiceID, payload=Payload}}, State),
    {next_state, authenticated, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_event(Event, StateName, State) ->
    lager:warning("Unhandled event: ~p", [Event]),
    {next_state, StateName, State}.

handle_sync_event(Event, _, StateName, State) ->
    lager:warning("Unhandled sync event: ~p", [Event]),
    {next_state, StateName, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_info({event, _, _}=Event, StateName, State=#state{}) ->
    ?MODULE:StateName(Event, State);

handle_info({tcp, Socket, Data}, StateName, State=#state{socket=Socket, transport=Transport}) ->
    ok = Transport:setopts(Socket, [{active, once}]),
    ?MODULE:StateName({request, decode_packet(Data)}, State);

handle_info({tcp_closed, Socket}, _, State=#state{socket=Socket}) ->
    {stop, normal, State};

handle_info({tcp_error, Socket, Reason}, _, State=#state{socket=Socket}) ->
    {stop, {shutdown, Reason}, State};

handle_info({'EXIT', ServicePid, Reason}, StateName, State=#state{endpoint=Endpoint, userid=UserID}) ->
    case dict:find(ServicePid, State#state.pid2sid) of
        error -> {noreply, State};
        {ok, ServiceID} ->
            lager:debug("['~s']['~s']: service '~s' disabled with reason ~p", [Endpoint, UserID, ServiceID, Reason]),
            NewState = State#state{
                sid2pid = dict:erase(ServiceID, State#state.sid2pid),
                pid2sid = dict:erase(ServicePid, State#state.pid2sid)
            },
            send({gateway_event, {service_disabled, ServiceID}}, NewState),
            {next_state, StateName, NewState}
    end;

handle_info(Info, StateName, State) ->
    lager:warning("Unhandled info: ~p", [Info]),
    {next_state, StateName, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

terminate(Reason, authenticating, #state{endpoint=Endpoint}) ->
    lager:debug("['~s']: terminated: ~p", [Endpoint, Reason]);
terminate(Reason, authenticated, #state{endpoint=Endpoint, userid=UserID}) ->
    lager:debug("['~s']['~s']: terminated: ~p", [Endpoint, UserID, Reason]).

code_change(_, StateName, State, _) ->
    {ok, StateName, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions:

enable_service(ServiceID, State=#state{userid=UserID}) ->
    case dict:find(ServiceID, State#state.sid2pid) of
        {ok, _} -> throw({service_enabled, <<"service enabled">>});
        error ->
            case pg2:get_closest_pid({service, ServiceID}) of
                {error, {no_such_group, _}} -> throw({service_unknown, <<"service unknown">>});
                {error, {no_process, _}} -> throw({service_unavailable, <<"service unavailable">>});
                ServicePid ->
                    {ok, Result} = gen:call(ServicePid, login, [UserID, self(), [{encoding, pb}]]),
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

send_error(Error, State) ->
    try
        send({error, Error}, State)
    catch
        error:encoding_failed ->
            send({error, internal_error}, State)
    end.

send(Packet, #state{transport=Transport, socket=Socket}) ->
    case Transport:send(Socket, encode_packet(Packet)) of
        ok -> ok;
        {error, _} -> ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

decode_packet(Binary) ->
    try
        gateway_piqi:parse_client2gateway(Binary)
    catch
        _:_ -> error(decoding_failed, [Binary])
    end.

encode_packet(Packet) ->
    try
        gateway_piqi:gen_gateway2client(Packet)
    catch
        _:_ -> error(encoding_failed, [Packet])
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

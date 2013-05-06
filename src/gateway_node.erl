-module(gateway_node).
-behaviour(gen_server).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% gen_server callbacks:
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% api:
-export([start/3]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {
    sid,
    nodeid,
    conn,
    service_pid
}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(SID, NodeID, Conn) ->
    gen_server:start(?MODULE, [NodeID, SID, Conn], []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([NodeID, SID, Conn]) ->
    process_flag(trap_exit, true),
    State = update_data(#state{sid=SID, nodeid=NodeID, conn=Conn}),
    lager:info("Node '~s' of service '~s' discovered", [NodeID, SID]),
    {ok, State}.

handle_call(_Call, _, State=#state{}) ->
    {noreply, State}.

handle_cast(_Cast, State=#state{}) ->
    {noreply, State}.

handle_info({login, {From, Ref}, [UserID, ConnPid, Options]}, State=#state{service_pid=ServicePid}) ->
    {ok, Result} = gen:call(ServicePid, login, [UserID, ConnPid, Options]),
    From ! {Ref, Result},
    {noreply, State};

handle_info({{ezk, _}, {_,data_changed,_}}, State) ->
    {noreply, update_data(State)};

handle_info({{ezk, _}, {_,node_deleted,_}}, State) ->
    {stop, {shutdown, node_deleted}, State};

handle_info({watchlost, {ezk, _}, _}, State) ->
    {stop, {shutdown, watchlost}, State};

handle_info({'DOWN',_,_,_,Reason}, State) ->
    {stop, {shutdown, Reason}, State}.

terminate({shutdown, Reason}, #state{sid=SID, nodeid=NodeID}) ->
    lager:info("Node '~s' of service '~s' disappeared: ~p", [NodeID, SID, Reason]).

code_change(_, State, _) ->
    {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_data(State=#state{conn=Conn, sid=SID, nodeid=NodeID}) ->
    Path = lists:flatten(io_lib:format("/services/~s/~s", [SID, NodeID])),
    {NodeData, _MetaData} = get_data(Conn, Path),
    Options = binary_to_term(NodeData),
    Node = proplists:get_value(node, Options),
    Cookie = proplists:get_value(cookie, Options),
    ServicePid = proplists:get_value(pid, Options),
    erlang:set_cookie(Node, Cookie),
    erlang:monitor(process, ServicePid),
    ok = pg2:join({service, SID}, self()),
    State#state{service_pid=ServicePid}.

get_data(Conn, Path) ->
    case ezk:get(Conn, Path, self(), {ezk, Conn}) of
        {ok, Data} -> Data;
        {error, {no_zk_connection, _}} -> error(disconnected);
        {error, Error} -> error(Error)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

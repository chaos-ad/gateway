-module(gateway_service).
-behaviour(gen_server).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% gen_server callbacks:
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% api:
-export([start/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {sid, conn, nodes=orddict:new()}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(SID, Conn) ->
    gen_server:start(?MODULE, [SID, Conn], []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([SID, Conn]) ->
    process_flag(trap_exit, true),
    ok = pg2:create({service, SID}),
    State = update_nodes(#state{sid=SID, conn=Conn}),
    lager:info("Service '~s' discovered", [SID]),
    {ok, State}.

handle_call(_Call, _, State=#state{}) ->
    {reply, ok, State}.

handle_cast(_Cast, State=#state{}) ->
    {noreply, State}.

handle_info({{ezk, _}, {_,child_changed,_}}, State) ->
    {noreply, update_nodes(State)};

handle_info({{ezk, _}, {_,node_deleted,_}}, State) ->
    {stop, {shutdown, node_deleted}, State};

handle_info({watchlost, {ezk, _}, _}, State) ->
    {stop, {shutdown, watchlost}, State}.

terminate({shutdown, Reason}, #state{sid=SID}) ->
    ok = pg2:delete({service, SID}),
    lager:info("Service '~s' disappeared: ~p", [SID, Reason]).

code_change(_, State, _) ->
    {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_nodes(State=#state{conn=Conn, sid=SID, nodes=OldNodes}) ->
    Old = ordsets:from_list(orddict:fetch_keys(OldNodes)),
    New = ordsets:from_list(ls(Conn, "/services/" ++ binary_to_list(SID))),
    Deleted = ordsets:subtract(Old, New),
    Created = ordsets:subtract(New, Old),
    NewState1 = lists:foldl(fun del_node/2, State, Deleted),
    NewState2 = lists:foldl(fun add_node/2, NewState1, Created),
    NewState2.

del_node(NodeID, State) ->
    State#state{nodes=orddict:erase(NodeID, State#state.nodes)}.

add_node(NodeID, State=#state{sid=SID, conn=Conn}) ->
    try 
        {ok, NodePid} = gateway_node:start(SID, NodeID, Conn),
        State#state{nodes=orddict:store(NodeID, NodePid, State#state.nodes)}
    catch
        _:_ -> State
    end.

ls(Conn, Path) ->
    case ezk:ls(Conn, Path, self(), {ezk, Conn}) of
        {ok, ChildNames} ->
            ChildNames;
        {error, {no_zk_connection, _}} ->
            error(disconnected);
        {error, Error} ->
            error(Error)
    end.

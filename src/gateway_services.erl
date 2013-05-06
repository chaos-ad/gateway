-module(gateway_services).
-behaviour(gen_fsm).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% gen_fsm callbacks:
-export([init/1, handle_info/3, handle_event/3, handle_sync_event/4, terminate/3, code_change/4]).

%% api:
-export([start_link/0]).
-compile(export_all).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {conn, services = orddict:new()}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
    process_flag(trap_exit, true),
    gen_fsm:send_event_after(0, connect),
    {ok, disconnected, #state{}}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

disconnected(connect, State=#state{}) ->
    try
        Conn = connect(),
        {next_state, connected, update_services(State#state{conn=Conn})}
    catch
        _:disconnected ->
            lager:warning("Zookeeper is unreachable"),
            gen_fsm:send_event_after(5000, connect),
            {next_state, disconnected, State}
    end;

disconnected({{ezk, _}, _}, State) ->
    {next_state, disconnected, State};

disconnected({watchlost, {ezk, _}, _}, State) ->
    {next_state, disconnected, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% TODO: Generate events

connected({{ezk, Conn}, {_,child_changed,_}}, State=#state{conn=Conn}) ->
    {next_state, connected, update_services(State)};

connected({watchlost, {ezk, Conn}, _}, #state{conn=Conn}) ->
    lager:warning("Zookeeper is unreachable"),
    gen_fsm:send_event_after(5000, connect),
    {next_state, disconnected, #state{}};

connected({{ezk, _}, _}, State) ->
    {next_state, connected, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _, StateName, State) ->
    {next_state, StateName, State}.

handle_info(Info, StateName, State) ->
    ?MODULE:StateName(Info, State).

terminate(_, _, _) ->
    ok.

code_change(_, StateName, State, _) ->
    {ok, StateName, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions:

connect() ->
    case application:get_env(zookeeper_servers) of
        {ok, Nodes} -> connect(Nodes);
        undefined   -> connect([])
    end.

connect(Nodes) ->
    case ezk_connection_manager:start_connection(Nodes, [self()]) of
        {ok, Conn} -> Conn;
        {error, no_server_reached} -> error(disconnected)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_services(State=#state{conn=Conn, services=OldServices}) ->
    Old = ordsets:from_list(orddict:fetch_keys(OldServices)),
    New = ordsets:from_list(ls(Conn, "/services")),
    Deleted = ordsets:subtract(Old, New),
    Created = ordsets:subtract(New, Old),
    NewState1 = lists:foldl(fun del_service/2, State, Deleted),
    NewState2 = lists:foldl(fun add_service/2, NewState1, Created),
    NewState2.

del_service(ServiceID, State) ->
    State#state{services=orddict:erase(ServiceID, State#state.services)}.

add_service(ServiceID, State) ->
    try 
        {ok, ServicePid} = gateway_service:start(ServiceID, State#state.conn),
        NewServices = orddict:store(ServiceID, ServicePid, State#state.services),
        State#state{services=NewServices}
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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

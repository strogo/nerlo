%% @doc This is the Erlang server maintaining connections
%% to the hidden Java node.
%% 
%% This one is trapping exists. You should always use ej_srv:stop()
%% to shutdown the server and the linked Java node. If the Java 
%% node dies it will be restarted. 
%%
%% To use this module in your code you should include ej.hrl.
%%
%% <pre>
%% (shell@host)1> {ok,Pid} = ej_srv:start().
%% (shell@host)2> ej_srv:ping().
%% (shell@host)3> ej_srv:stop().
%% </pre>
%% @author Ingo Schramm

-module(ej_srv).
-behaviour(gen_server).

% public interface
-export([send/2, call/2, call/3, callback/3, ping/0, restart_peer/0]).
-export([start/0, start/1, start/2, start_link/0, start_link/1, start_link/2, stop/0]).

% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-author("Ingo Schramm").

-include("global.hrl").
-include("ej.hrl").
-include_lib("eunit/include/eunit.hrl").

-ifdef(DEBUG).
-export([bad/0]).
-endif. 

-define(DEFAULT_N, erlang:system_info(schedulers_online) * 2).
-define(SRVNAME, ?MODULE).
-define(STARTSPEC, {local, ?SRVNAME}).
-define(PEERNAME, jnode).
-define(PEERSTR, atom_to_list(?PEERNAME)).
-define(BINDIR, ".").
-define(JNODEBIN, "jnode").
-define(BLOCKING_TIMEOUT, 1000).

-record(ej, {workers  = []
            ,worker   = no
            ,n        = 0
            ,peer     = null
            ,bindir   = ?BINDIR
            ,stopping = false
            ,callbacks= null
            }).

%% ------ PUBLIC -----

start() ->
    start(?DEFAULT_N).

start(N) ->
    gen_server:start(?STARTSPEC, ?MODULE, #ej{n=N}, []).

start(N,Bindir) ->
    gen_server:start(?STARTSPEC, ?MODULE, #ej{n=N,bindir=Bindir}, []).

start_link() ->
    start_link(?DEFAULT_N). 
    
start_link(N) ->
    gen_server:start_link(?STARTSPEC, ?MODULE, #ej{n=N}, []).

start_link(N,Bindir) ->
    gen_server:start_link(?STARTSPEC, ?MODULE, #ej{n=N,bindir=Bindir}, []).

stop() ->
    gen_server:cast(?SRVNAME, {'STOP'}).

% @doc Send a message to the peer and return immediately.
send(Tag,Msg = [_|_]) ->
    gen_server:call(?SRVNAME, {send, get_ref(), Tag, Msg}),
    ok.

% @doc Send a message to the peer and wait for an answer.
% This runs with a default timeout of 10 seconds.
call(Tag,Msg) ->
    call(Tag,Msg,10).       

% @doc Send a message to the peer and wait for an answer.
% After Timeout seconds {error,timeout} will be returned.
% Set Timeout to 'infinity' to wait forever.
call(Tag,Msg = [_|_],Timeout) ->
    gen_server:call(?SRVNAME, {send, Ref=get_ref(), Tag, Msg}),
    receive
        {_From, Ref, Result} -> Result
    after
        Timeout * 1000 -> {error,timeout}
    end.

% @doc Set a fun to be called each time the peer sends a
% fragmented message.
callback(Tag,Msg = [_|_],Fun) when is_function(Fun) ->
    gen_server:cast(?SRVNAME, {callback, Ref=get_ref(), Tag, Msg}),
    callback_loop(Ref,Fun).

% @doc Ping the peer. This will not use net_adm:ping but
% the ej_srv message channel to the Java node to test this
% particular channel.
ping() ->
    gen_server:call(?SRVNAME, {ping}).

% @doc Restart the Java node.
restart_peer() ->
    gen_server:call(?SRVNAME, {restart}).

%% ------ GENERIC -----


% @hidden    
init(S) ->
    S1 =
    case S#ej.worker of
        yes -> S;
        no  -> initialize(S)
    end,
    log:info(self(), "~w initialized with state ~w", [?MODULE, S1]),
    {ok,S1}.

% @hidden     
handle_call({send,Ref,Tag,Msg},From,S) ->
    {W, L} = f:lrot(S#ej.workers),
    gen_server:cast(W,{send,From,Ref,Tag,Msg}),
    {noreply, S#ej{workers=L}};
handle_call({ping},_From,S) ->
    Reply = send_ping(S#ej.peer),
    {reply, Reply,S};
handle_call({restart},_From,S) ->
    {Reply, NewS} =
    case shutdown_peer(S#ej.peer) of
        ok ->
            Peer = handshake(S#ej.bindir),
            {ok, populate_peer(Peer,S)};
        _Any -> 
            {{error,shutdown},S}
    end,
    {reply, Reply, NewS};
handle_call({bad},_From,S) ->
    erlang:foobar(),
    {noreply,S};
handle_call(Msg,From,S) ->
    log:warn(self(), "Cannot understand call from ~w: ~w", [From,Msg]),
    {reply, {error, unknown_msg}, S}.

% @hidden
handle_cast({send,From,Ref,Tag,Msg}, S) ->
    Result = send_peer(S#ej.peer,Ref,Tag,Msg),
    gen_server:reply(From, Result),
    {noreply, S};
handle_cast({set_peer, Peer}, S) ->
    log:debug(self(), "replacing peer ~p with ~p: ", [S#ej.peer, Peer]),
    {noreply, S#ej{peer=Peer}};
handle_cast({callback, Ref, Tag, Msg}, S) ->
    log:debug(self(), "callback: ~p", [Ref]),
    send_peer(S#ej.peer,Ref,Tag,Msg),
    {noreply,S};
handle_cast({'STOP'}, S) ->
    case S#ej.worker of
        yes -> nop;
        no  -> shutdown(S#ej.peer,S)
    end,
    log:info(self(),"stopping with state: ~w", [S]),
    {noreply, S#ej{stopping=true}};
handle_cast(Msg,S) ->
    log:info(self(),"cannot handle cast: ~w", [Msg]),
    {noreply, S}.

% @hidden
% port messages
handle_info({Port,{data,"\n"}},S) when is_port(Port) ->
    {noreply,S};
handle_info({Port,{data,Msg}},S) when is_port(Port) ->
    log:info(self(),"port says: ~p", [Msg]),
    {noreply,S};
% ej_srv messages
handle_info({From,_Ref,{?TAG_OK,[?EJMSGPART(call,handshake)]}},S) ->
    log:debug(self(), "info handshake from: ~w", [From]),
    {noreply, populate_peer(From,S)};
handle_info(Msg={'EXIT', Pid, Reason},S) ->
    log:warn(self(), "EXIT from ~w with reason: ~w", [Pid,Reason]),
    S1 =
    case is_port(Pid) of
        true  -> S;
        false -> handle_exit(Msg,S)
    end,
    {noreply, S1}; 
handle_info({'STOP'},S) ->
    case S#ej.worker of
        yes -> 
            log:info(self(),"stopping with state: ~w", [S]),
            {stop, normal, S};
        no  -> 
            {noreply,S}
    end;
% messages to be routed to client
handle_info({From,Ref={Client,_Id},M={?TAG_FRAGMENT,Msg}},S) ->
    log:debug(self(), "got fragment: From=~w Ref=~w Msg=~w", [From,Ref,M]),
    if
        Client =:= self() -> log:error(self(), "possible message loop", []);
        true              -> Client ! {self(),Ref,Msg}
    end,
    {noreply, S};
handle_info({From,Ref={Client,_Id},Msg},S) ->
    log:debug(self(), "got result: From=~w Ref=~w Msg=~w", [From,Ref,Msg]),
    if
        Client =:= self() -> log:error(self(), "possible message loop", []);
        true              -> Client ! {self(),Ref,Msg}
    end,
    {noreply, S};
% unknown
handle_info(Msg,S) ->
    log:info(self(),"info: ~p", [Msg]),
    {noreply,S}.

% @hidden     
terminate(_Reason,S) ->
    {noreply, S}.

% @hidden     
code_change(_OldVsn, S, _Extra) -> 
    {ok, S}.


%% ------ PRIVATE -----

send_peer(Peer,Ref,Tag,Msg) ->
    log:debug(self(), "send_peer ~w: ~w", [Peer,?EJMSG(Ref,Tag,Msg)]),
    Peer ! ?EJMSG(Ref,Tag,Msg).

start_worker(S) ->
    gen_server:start(?MODULE, S#ej{worker=yes}, []).

initialize(S) ->
    process_flag(trap_exit, true),
    {ok,Cwd} = file:get_cwd(),
    timer:start(),
    Bindir = 
        if 
            S#ej.bindir =:= ?BINDIR -> Cwd;
            true                      -> S#ej.bindir
        end,
    % callbacks=ets:new(erlang:make_ref(),[])
    S2 = S#ej{peer=handshake(Bindir)},
    Workers =
        lists:foldl(fun(_I,Acc) -> 
                            case start_worker(S2) of
                                {ok,Pid} -> [Pid|Acc];
                                _Any     -> Acc
                            end
                    end, [], lists:seq(1,S#ej.n)),
    S2#ej{workers=Workers,bindir=Bindir}.

handshake(Bindir) ->
    {ok, Hostname} = inet:gethostname(),
    Peer = {?PEERNAME,list_to_atom(?PEERSTR ++ "@" ++ Hostname)},
    case quick_handshake(Peer) of
        {ok,From}         -> From;
        {error,no_answer} -> full_handshake(Peer,Bindir)
    end.
    
quick_handshake(Peer) ->
    log:info(self(), "quick handshake to: ~w", [Peer]),
    run_handshake(Peer).

% TODO we should retry handshake after opening port
% for at least 3 times to allow first JVM startup ever
% to be a little slower (not yet cached in the OS)
full_handshake(Peer,Bindir) ->
    log:info(self(), "full handshake to: ~w", [Peer]),
    port(Bindir),
    timer:sleep(500),
    case run_handshake(Peer) of
        {ok,From}         -> From;
        {error,no_answer} -> Peer
    end.

port(Bindir) ->
    % TODO pass args to open_port canonically
    Args = "-peer " ++ atom_to_list(node())
        ++ " -sname " ++ ?PEERSTR
        ++ " -cookie " ++ atom_to_list(erlang:get_cookie()),
    Cmd  = Bindir ++ "/" ++ ?JNODEBIN ++ " " ++ Args ++ " &",
    log:info(self(), "open port to org.ister.ej.Node: ~p", [Cmd]),
    Port = erlang:open_port({spawn, Cmd},[stderr_to_stdout]),
    log:info(self(), "port: ~w", [Port]).

run_handshake(Peer) ->
    send_peer(Peer, Ref=get_ref(), ?TAG_NODE, [?EJMSGPART(call,handshake)]),
    receive
        {From,Ref,{?TAG_OK,[?EJMSGPART(call,handshake)]}} -> 
            log:info(self(), "got handshake from: ~w", [From]),
            erlang:link(From),
            {ok,From}
    after
        ?BLOCKING_TIMEOUT -> 
            log:info(self(), "handshake timeout", []),
            {error,no_answer}
    end.

shutdown(Peer,S) ->
    lists:map(fun(W) -> W ! {'STOP'} end, S#ej.workers),
    shutdown_peer(Peer).

shutdown_peer(Peer) ->
    send_peer(Peer, Ref=get_ref(), ?TAG_NODE, [?EJMSGPART(call,shutdown)]),
    receive
        {Peer,Ref,{?TAG_OK,[?EJMSGPART(call,bye)]}} -> 
            log:info(self(), "shutdown confirmed by peer", []),
            ok
    after
        ?BLOCKING_TIMEOUT ->
            log:error(self(), "shutdown timeout: no ok from peer", []),
            well
    end.

handle_exit({'EXIT', Peer, noconnection}, S) when Peer =:= S#ej.peer ->
    case S#ej.stopping of
        true  -> S;
        false ->
            NewPeer = handshake(S#ej.bindir),
            populate_peer(NewPeer,S)
    end;
handle_exit(Any,S) ->
    log:debug(self(), "don't know how to handle exit: ~w", [Any]),
    S.

send_ping(Peer) ->
    send_peer(Peer,Ref=get_ref(),?TAG_NODE,Msg=[?EJMSGPART(call,ping)]),
    receive
        {Peer,Ref,{ok,Msg}} -> pong;
        _                   -> pang
    after
        ?BLOCKING_TIMEOUT   -> pang
    end.

get_ref() ->
    ?EJMSGREF(self(),erlang:make_ref()).

populate_peer(Peer,S) ->
    lists:map(fun(W) -> gen_server:cast(W,{set_peer,Peer}) end, S#ej.workers),
    S#ej{peer=Peer}.

callback_loop(Ref, Fun) ->
    receive
        {_From, Ref, [{result,Result}]} ->
            Fun(Result),
            callback_loop(Ref, Fun);
        {_From, Ref, {?TAG_OK, [{result,?EJCALLBACKSTOP}]}} ->
            ok;
        % TODO apply timeout
        {_From, Ref, {?TAG_ERROR, [{result,?EJCALLBACKTIMEOUT}]}} ->
            {error, timeout};
        {_From, Ref, {?TAG_ERROR, Reason}} ->
            {error,Reason};        
        Any ->
            {error, bogus_message_received, {self=Ref}, {answer=Any}}
    end.


-ifdef(DEBUG).
bad() -> 
    gen_server:call(?SRVNAME, {bad}).
-endif.


%% ------ TESTS ------

start_stop_test() ->
    {ok,Pid} = start(2,"../bin"),
    timer:sleep(500),
    ?assert(is_pid(Pid)),
    stop(),
    timer:sleep(500).






  

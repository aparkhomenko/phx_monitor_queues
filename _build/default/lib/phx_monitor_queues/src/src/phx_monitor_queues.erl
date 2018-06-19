-module(phx_monitor_queues).

-behaviour(gen_server).

-export([start_link/0, start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([store_show/0, heavy_process_show/0]).

-record(state, {
          store,
          store_cnt,
          store_limit,
          timer,
          max_messages,
          max_message_queue_len,
          last_heavy_process
         }).

-record(process, {
          name,
          status,
          memory,
          last_messages,
          message_queue_len
         }).

-record(snapshot, {
          total_processes,
          total_messages_in_queues,
          total_messages_in_filtered_processes,
          total_filtered_processes,
          filtered_processes
         }).

-define(SERVER, ?MODULE).
-define(DEFAULT_OPTIONS, [{store_limit, 11}, {max_messages, 30}, {max_message_queue_len, 30}]).

start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

init(Options) ->
    F = fun({Key, Value}) ->
                case proplists:get_value(Key, Options, undefined) of
                    undefined ->
                        {Key, Value};
                    NewValue when NewValue > 0 ->
                        {Key, NewValue};
                    _ ->
                        {Key, Value}
                end
        end,

    Opts = lists:map(F, ?DEFAULT_OPTIONS),
    State = #state{
               store = [],
               store_cnt = 0,
               store_limit = proplists:get_value(store_limit, Opts),
               max_messages = proplists:get_value(max_messages, Opts),
               max_message_queue_len = proplists:get_value(max_message_queue_len, Opts),
               last_heavy_process = #process{}
              },

    {ok, start_timer(State)}.

store_show() ->
    gen_server:cast(?SERVER, {store, show}).

heavy_process_show() ->
    gen_server:cast(?SERVER, {heavy_process, show}).

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({store, show}, State) ->
    io:format("~p~n", [State#state.store]),
    {noreply, State};

handle_cast({heavy_process, show}, State) ->
    io:format("~p~n", [State#state.last_heavy_process]),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(update, State) ->
    cancel_timer(State),
    {noreply, start_timer(walk_processes(State))};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions
cancel_timer(State) ->
    erlang:cancel_timer(State#state.timer).

start_timer(State) ->
    State#state{timer = erlang:send_after(1000, self(), update)}.

walking(Processes, MaxMsgQueueLen, MaxMsgs) ->
    S = #snapshot{
           total_processes = 0,
           total_messages_in_queues = 0,
           total_messages_in_filtered_processes = 0,
           total_filtered_processes = 0,
           filtered_processes = []
          },

    walking(Processes, MaxMsgQueueLen, MaxMsgs, S).

walking([], _MaxMsgQueueLen, _MaxMsgs, S) ->
    S;

walking([Pid|T], MaxMsgQueueLen, MaxMsgs, S) ->
    case erlang:process_info(Pid, [registered_name, memory, status, messages, message_queue_len]) of
        undefined ->
            walking(T, MaxMsgQueueLen, MaxMsgs, S);
        Info ->
            MsgQueueLen = proplists:get_value(message_queue_len, Info, 0),

            {FilteredProcesses, FilteredMsgQueueLen} =
            case MsgQueueLen >= MaxMsgQueueLen of
                true ->
                    Index = case MaxMsgs > MsgQueueLen of
                                true ->
                                    0;
                                _ ->
                                    MsgQueueLen - MaxMsgs
                            end,

                    Name = case proplists:get_value(registered_name, Info, []) of
                               [] ->
                                   Pid;
                               N ->
                                   N
                           end,

                    Proc = #process{
                              name = Name,
                              status = proplists:get_value(status, Info),
                              memory = proplists:get_value(memory, Info),
                              last_messages = lists:nthtail(Index, proplists:get_value(messages, Info, [])),
                              message_queue_len = MsgQueueLen
                             },

                    {lists:append(S#snapshot.filtered_processes, [Proc]), MsgQueueLen};
                _ ->
                    {S#snapshot.filtered_processes, 0}
            end,

            walking(T, MaxMsgQueueLen, MaxMsgs, S#snapshot{
                                                  total_processes = S#snapshot.total_processes + 1,
                                                  total_messages_in_queues = S#snapshot.total_messages_in_queues + MsgQueueLen,
                                                  total_messages_in_filtered_processes = S#snapshot.total_messages_in_filtered_processes + FilteredMsgQueueLen,
                                                  total_filtered_processes = if FilteredMsgQueueLen > 0 -> S#snapshot.total_filtered_processes + 1; true -> S#snapshot.total_filtered_processes end,
                                                  filtered_processes = FilteredProcesses
                                                 })
    end.

walk_processes(State) ->
    Snapshot = walking(erlang:processes(), State#state.max_message_queue_len, State#state.max_messages),

    case Snapshot#snapshot.filtered_processes of
        [] ->
            State;
        _ ->
            Time = os:timestamp(),
            {Store, StoreCnt} = case State#state.store_cnt >= State#state.store_limit of
                                    true ->
                                        Index = State#state.store_limit div 2,
                                        NewStore = lists:nthtail(Index, State#state.store),
                                        {NewStore, State#state.store_cnt - Index};
                                    _ -> 
                                        {State#state.store, State#state.store_cnt}
                                end,

            State#state{
              store = lists:append(Store, [{Time, Snapshot}]),
              last_heavy_process = find_heavy_process(Snapshot#snapshot.filtered_processes),
              store_cnt = StoreCnt + 1
             }
    end.

find_heavy_process([]) ->
    #process{};

find_heavy_process([H|T]) ->
    find_heavy_process(H, T).

find_heavy_process(Cur, [H|T]) ->
    case Cur#process.message_queue_len > H#process.message_queue_len of
        true ->
            find_heavy_process(Cur, T);
        false ->
            find_heavy_process(H, T)
    end;

find_heavy_process(Cur, []) ->
    Cur.

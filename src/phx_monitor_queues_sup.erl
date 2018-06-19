%%%-------------------------------------------------------------------
%% @doc phx_monitor_queues top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(phx_monitor_queues_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    SupFlags = {_RestartStrategy=one_for_one, _MaxRestarts=0, _MaxSecondsBetweenRestarts=1},
    Childs = [phx_monitor_queues_worker(application:get_all_env())],

    {ok, { SupFlags, Childs} }.

%%====================================================================
%% Internal functions
%%====================================================================
phx_monitor_queues_worker(Opts) ->
    Type = worker,
    {Type, {phx_monitor_queues, start_link, [Opts]}, _Restart=permanent, _Shutdown=2000, Type, [worker]}.

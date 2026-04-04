-module(xmpp_swarm_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
  Children = [{
    xmpp_swarm_connection,
    {xmpp_swarm_connection, start_link, ["localhost", 5222, "user1@localhost"]},
    permanent,
    5000,
    worker,
    [xmpp_swarm_connection]
  }],
  {ok, { {one_for_one, 5, 10}, Children} }.

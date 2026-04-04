-module(xmpp_swarm_connection).
-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

-include_lib("xmpp/include/xmpp.hrl").

-record(state, {
  socket,
  host,
  port,
  jid
}).

start_link(Host, Port, JID) ->
  gen_server:start_link(?MODULE, {Host, Port, JID}, []).

init({Host, Port, JID}) ->
  process_flag(trap_exit, true),

  %% 1. TCP connect
  {ok, Socket} = gen_tcp:connect(Host, Port, [
      binary,
      {packet, raw},
      {active, once}
  ]),


  %% 3. Open XMPP stream
  Domain = extract_domain(JID),

  StreamStart = io_lib:format(
      "<?xml version='1.0'?><stream:stream to='~s' "
      "xmlns='jabber:client' "
      "xmlns:stream='http://etherx.jabber.org/streams' "
      "version='1.0'>",
      [Domain]
  ),

  gen_tcp:send(Socket, lists:flatten(StreamStart)),

  io:format("Stream opened to ~s~n", [Domain]),

  {ok, #state{
    socket = Socket,
    host = Host,
    port = Port,
    jid = JID
  }}.


handle_info({tcp, Socket, Data}, State) ->
  io:format("RAW RECV: ~p~n", [{Socket, Data}]),

  {noreply, State};
handle_info({tcp_closed, Socket}, State) ->
  io:format("Socket closed ~p~n", [Socket]),
  {stop, normal, State}.

handle_call(Request, From, State) ->
  io:format("Unhandled call ~p~n", [{From, Request}]),
  {reply, ok, State}.

handle_cast(Request, State) ->
  io:format("Unhandled cast ~p~n", [Request]),
  {noreply, State}.

handle_event(Event) ->
  io:format("XMPP EVENT: ~p~n", [Event]).

terminate(_Reason, _State) ->
  ok.

extract_domain(JID) ->
  [_User, Domain] = string:split(JID, "@"),
  Domain.

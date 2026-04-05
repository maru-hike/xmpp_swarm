-module(xmpp_swarm_connection).
-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2]).

-include_lib("xmpp/include/xmpp.hrl").

-record(user_info, {jid = <<>>, password = <<>>}).
-record(state, {
  socket,
  host,
  port,
  user_info = #user_info{},
  stream = undefined
}).

start_link(Host, Port, UserOpts) ->
  gen_server:start_link(?MODULE, {Host, Port, UserOpts}, []).

init({Host, Port, UserOpts}) ->
  process_flag(trap_exit, true),

  %% 1. TCP connect
  {ok, Socket} = gen_tcp:connect(Host, Port, [
      binary,
      {packet, raw},
      {active, once}
  ]),


  %% 3. Open XMPP stream
  Domain = extract_domain(maps:get(jid, UserOpts)),

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
    user_info = opts_to_user_info(UserOpts),
    stream = fxml_stream:new(self())
  }}.


handle_info({tcp, Socket, Data}, State) ->
  % io:format("RAW RECV: ~p~n", [Data]),
  Stream1 = fxml_stream:parse(State#state.stream, Data),

  % lists:foreach(fun(E) ->
  %   handle_event(E, State)
  % end, Events),

  inet:setopts(Socket, [{active, once}]),
  {noreply, State#state{stream = Stream1}};
handle_info({'$gen_event', {xmlstreamstart, Name, _Attrs}}, State) ->
  io:format("STREAM START: ~p ~n", [Name]),
  {noreply, State};

handle_info({'$gen_event', {xmlstreamend, Name}}, State) ->
  io:format("STREAM END: ~p~n", [Name]),
  {noreply, State};

handle_info({'$gen_event', {xmlstreamelement, El}}, State) ->
  Decoded = xmpp:decode(El),
  io:format("DECODED: ~p~n", [Decoded]),
  handle_stanza(Decoded, State),
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

terminate(_Reason, _State) ->
  ok.

extract_domain(JID) ->
  [_User, Domain] = string:split(JID, "@"),
  Domain.

%%%===================================================================
%%% Internal
%%%===================================================================

opts_to_user_info(#{jid := JID, password := Pass}) ->
  #user_info{jid = JID, password = Pass}.

handle_stanza(#stream_features{sub_els = Elements} = _Features, State) ->
  case lists:keyfind(sasl_mechanisms, 1, Elements) of
    false ->
      io:format("No mechanisms found~n"),
      State;
    {sasl_mechanisms, Mechs} ->
      maybe_start_auth(Mechs, State)
  end;
handle_stanza(#sasl_success{}, State) ->
  io:format("SASL SUCCESS - restarting stream~n"),

  restart_stream(State),
  State;
handle_stanza(Stanza, State) ->
  io:format("OTHER STANZA: ~p~n", [Stanza]),
  State.

maybe_start_auth(Mechs, State) ->
  case lists:member(<<"PLAIN">>, Mechs) of
    true ->
      send_sasl_plain(State);
    false ->
      io:format("PLAIN not supported~n"),
      State
  end.

send_sasl_plain(State = #state{socket = Socket, user_info = #user_info{jid = JID, password = Pass}}) ->
  User = jid_to_user(JID),
  Auth = #sasl_auth{
    mechanism = <<"PLAIN">>,
    text = <<0, User/binary, 0, Pass/binary>>
    % text = Payload
  },

  Xml = xmpp:encode(Auth),
  Packet = fxml:element_to_binary(Xml),
  io:format("Sending SASL PLAIN~p~n", [Packet]),
  gen_tcp:send(Socket, Packet),

  State.

jid_to_user(JID) ->
  case binary:split(JID, <<"@">>) of
    [User, _Domain] -> User;
    [User] -> User
  end.

restart_stream(State = #state{socket = Socket, user_info = UserInfo}) ->
  Domain = extract_domain(UserInfo#user_info.jid),
  io:format("Restarting stream...~n"),

  Stream =
    <<"<stream:stream to='", Domain/binary, "' ",
      "xmlns='jabber:client' ",
      "xmlns:stream='http://etherx.jabber.org/streams' ",
      "version='1.0'>">>,

  ok = gen_tcp:send(Socket, Stream),

  fxml_stream:reset(State#state.stream),
  State#state{stream = fxml_stream:new(self())}.

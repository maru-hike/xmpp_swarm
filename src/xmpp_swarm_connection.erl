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
  stream = undefined,
  phase = unauthenticated,
  pending = []
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

  {ok, #state{
    socket = Socket,
    host = Host,
    port = Port,
    user_info = opts_to_user_info(UserOpts),
    stream = fxml_stream:new(self())
  }}.


handle_info({tcp, Socket, Data}, State) ->
  io:format("RAW RECV: ~p~n", [Data]),
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
  % io:format("DECODED: ~p~n", [Decoded]),
  State1 = handle_stanza(Decoded, State),
  {noreply, State1};
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

handle_stanza(Stanza, #state{phase = unauthenticated} = State) ->
  handle_unauthenticated(Stanza, State);
handle_stanza(Stanza, #state{phase = authenticated} = State) ->
  handle_authenticated(Stanza, State).

handle_unauthenticated(#stream_features{sub_els = Elements} = _Features, State) ->
  case lists:keyfind(sasl_mechanisms, 1, Elements) of
    false ->
      io:format("No mechanisms found~n"),
      State;
    {sasl_mechanisms, Mechs} ->
      maybe_start_auth(Mechs, State)
  end;
handle_unauthenticated(#sasl_success{}, State) ->
  io:format("SASL SUCCESS - restarting stream~n"),
  restart_stream(State);
handle_unauthenticated(Stanza, State) ->
  io:format("OTHER STANZA: ~p~n", [Stanza]),
  State.

handle_authenticated(#stream_features{sub_els = Features}, State) ->
  lists:map(fun(#bind{}) ->
      %% Do binding logic here
      send_bind(State),
      State;
    (Feature) ->
      io:format("IGNORING STREAM FEATURE:~p~n", [Feature])
  end, Features),
  State;
handle_authenticated(#iq{type = get, id = Id, from = From, sub_els = [#ping{}]}, State) ->
  Reply = #iq{type = result, id = Id, to = From, sub_els = []},
  send_xmpp(Reply, State);
handle_authenticated(#iq{type = result, id = <<"bind_1">>, sub_els = [#bind{jid = JID}]}, State) ->
  io:format("BOUND successfully as ~s~n", [jid:encode(JID)]),
  State;
handle_authenticated(#iq{type = error} = IQ, State) ->
  io:format("IQ ERROR: ~p~n", [IQ]),
  State;
handle_authenticated(Stanza, State) ->
  io:format("UNHANDLED AUTHENTICATED STANZA: ~p~n", [Stanza]),
  State.

send_bind(State) ->
  Resource = <<"xmpp-swarm">>,
  IQ = #iq{type = set, id = <<"bind_1">>, sub_els = [#bind{resource = Resource}]},
  send_xmpp(IQ, State).

send_xmpp(XMPP, #state{pending = Pending} =State) ->
  % io:format("Sending XMPP:~p", [XMPP]),
  case get_id(XMPP) of
    undefined ->
      io:format("ID FIELD NOT FOUND:~p~n", [XMPP]),
      State;
    Id ->
      XML = fxml:element_to_binary(xmpp:encode(XMPP)),
      io:format("Sending XML:~p", [XML]),
      ok = gen_tcp:send(State#state.socket, XML),
      State#state{pending = [Id|Pending]}
  end.

get_id(#iq{id = Id}) -> Id;
get_id(_) -> undefined.

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
  State#state{stream = fxml_stream:new(self()), phase = authenticated}.

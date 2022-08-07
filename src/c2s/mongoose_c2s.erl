-module(mongoose_c2s).

-behaviour(gen_statem).
-include("mongoose_logger.hrl").
-include("mongoose.hrl").
-include("jlib.hrl").
-include_lib("exml/include/exml_stream.hrl").
-define(AUTH_RETRIES, 3).
-define(BIND_RETRIES, 5).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).

%% utils
-export([get_host_type/1, get_lserver/1, get_sid/1, get_jid/1,
         get_handler/2, remove_handler/2,
         get_ip/1, get_socket/1, get_lang/1, get_stream_id/1]).
-export([filter_mechanism/1, c2s_stream_error/2, maybe_retry_state/1,
         reroute/2, stop/2, merge_states/2]).

-ignore_xref([get_ip/1, get_socket/1]).

-record(state, {
          host_type = ?MYNAME :: mongooseim:host_type(),
          lserver = ?MYNAME :: jid:lserver(),
          lang = ?MYLANG :: ejabberd:lang(),
          sid = ejabberd_sm:make_new_sid() :: ejabberd_sm:sid(),
          streamid = new_stream_id() :: binary(),
          jid :: undefined | jid:jid(),
          ip :: undefined | {inet:ip_address(), inet:port_number()},
          ranch_ref :: ranch:ref(),
          transport :: transport(),
          socket :: ranch_transport:socket(),
          parser :: undefined | exml_stream:parser(),
          shaper :: undefined | shaper:shaper(),
          listener_opts :: mongoose_listener:options(),
          handlers = #{} :: #{module() => term()}
         }).
-type transport() :: ranch_tcp | ranch_ssl | fast_tls.
-type c2s_data() :: #state{}.
-type maybe_ok() :: ok | {error, atom()}.
-type fsm_res() :: gen_statem:event_handler_result(c2s_state(), c2s_data()).
-type packet() :: {jid:jid(), jid:jid(), exml:element()}.

%% C2S hooks and handlers
-type takeover_fn() :: fun( (c2s_data(), c2s_state()) -> fsm_res()).
-type handler_fn() :: fun( (atom(), c2s_data()) -> mongoose_c2s_acc:t()).
-export_type([handler_fn/0, takeover_fn/0]).

-type retries() :: 0..8.
-type stream_state() :: stream_start | authenticated.
-type c2s_state() :: connect
                   | {wait_for_stream, stream_state()}
                   | {wait_for_feature_before_auth, cyrsasl:sasl_state(), retries()}
                   | {wait_for_feature_after_auth, retries()}
                   | {wait_for_sasl_response, cyrsasl:sasl_state(), retries()}
                   | session_established.

-export_type([packet/0, c2s_data/0, c2s_state/0]).

%%%----------------------------------------------------------------------
%%% gen_statem
%%%----------------------------------------------------------------------

-spec stop(gen_statem:server_ref(), atom()) -> ok.
stop(Pid, Reason) ->
    gen_statem:cast(Pid, {stop, Reason}).

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    handle_event_function.

-spec init({ranch:ref(), transport(), mongoose_listener:options()}) ->
    gen_statem:init_result(c2s_state(), c2s_data()).
init({Ref, Transport, Opts}) ->
    StateData = #state{ranch_ref = Ref, transport = Transport, listener_opts = Opts},
    ConnectEvent = {next_event, internal, connect},
    {ok, connect, StateData, ConnectEvent}.

-spec handle_event(gen_statem:event_type(), term(), c2s_state(), c2s_data()) -> fsm_res().
handle_event(info, {route, Acc}, C2SState, StateData) ->
    handle_incoming_stanza(StateData, C2SState, Acc);
handle_event(info, {route, _From, _To, Acc}, C2SState, StateData) ->
    handle_incoming_stanza(StateData, C2SState, Acc);
handle_event(info, {TcpOrSSl, _Socket, Packet} = SocketData, _FsmState, StateData)
  when TcpOrSSl =:= tcp orelse TcpOrSSl =:= ssl ->
    ?LOG_DEBUG(#{what => received_xml_on_stream, packet => Packet, c2s_pid => self()}),
    handle_socket_data(StateData, SocketData);
handle_event(info, {Closed, _Socket} = SocketData, C2SState, StateData)
  when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    handle_socket_closed(StateData, C2SState, SocketData);
handle_event(info, {Error, _Socket} = SocketData, C2SState, StateData)
  when Error =:= tcp_error; Error =:= ssl_error ->
    handle_socket_error(StateData, C2SState, SocketData);
handle_event(info, replaced, _FsmState, StateData) ->
    StreamConflict = mongoose_xmpp_errors:stream_conflict(),
    send_element_from_server_jid(StateData, StreamConflict),
    send_trailer(StateData),
    {stop, {shutdown, replaced}};
handle_event(info, {exit, Reason}, _, StateData) ->
    StreamConflict = mongoose_xmpp_errors:stream_conflict(),
    send_element_from_server_jid(StateData, StreamConflict),
    send_trailer(StateData),
    {stop, {shutdown, Reason}};
handle_event(info, {stop, Reason}, C2SState, StateData) ->
    handle_stop_request(StateData, C2SState, Reason);

handle_event(internal, connect, connect,
             StateData = #state{listener_opts = #{shaper := ShaperName,
                                                  max_stanza_size := MaxStanzaSize}}) ->
    {ok, Parser} = exml_stream:new_parser([{max_child_size, MaxStanzaSize}]),
    Shaper = shaper:new(ShaperName),
    StateData1 = handle_socket_proxy_ip_blacklist_ssl(StateData),
    StateData2 = StateData1#state{parser = Parser, shaper = Shaper},
    {next_state, {wait_for_stream, stream_start}, StateData2, state_timeout()};

handle_event(internal, #xmlstreamstart{name = Name, attrs = Attrs}, {wait_for_stream, StreamState}, StateData) ->
    StreamStart = #xmlel{name = Name, attrs = Attrs},
    handle_stream_start(StateData, StreamStart, StreamState);
handle_event(internal, _Unexpected, {wait_for_stream, _}, StateData = #state{lserver = LServer}) ->
    case mongoose_config:get_opt(hide_service_name, false) of
        true ->
            {stop, {shutdown, stream_error}};
        false ->
            send_header(StateData, LServer, <<"1.0">>, <<>>),
            c2s_stream_error(StateData, mongoose_xmpp_errors:xml_not_well_formed())
    end;
handle_event(internal, #xmlstreamstart{}, _, StateData) ->
    c2s_stream_error(StateData, mongoose_xmpp_errors:policy_violation());

handle_event(internal, #xmlstreamend{}, _, StateData) ->
    send_trailer(StateData),
    {stop, {shutdown, stream_end}};
handle_event(internal, #xmlstreamerror{name = <<"child element too big">> = Err}, _, StateData) ->
    c2s_stream_error(StateData, mongoose_xmpp_errors:policy_violation(StateData#state.lang, Err));
handle_event(internal, #xmlstreamerror{name = Err}, _, StateData) ->
    c2s_stream_error(StateData, mongoose_xmpp_errors:xml_not_well_formed(StateData#state.lang, Err));
handle_event(internal, #xmlel{name = <<"starttls">>} = El, {wait_for_feature_before_auth, SaslState, Retries}, StateData) ->
    case exml_query:attr(El, <<"xmlns">>) of
        ?NS_TLS ->
            handle_starttls(StateData, El, SaslState, Retries);
        _ ->
            c2s_stream_error(StateData, mongoose_xmpp_errors:invalid_namespace())
    end;
handle_event(internal, #xmlel{name = <<"auth">>} = El, {wait_for_feature_before_auth, SaslState, Retries}, StateData) ->
    case exml_query:attr(El, <<"xmlns">>) of
        ?NS_SASL ->
            handle_auth_start(StateData, El, SaslState, Retries);
        _ ->
            c2s_stream_error(StateData, mongoose_xmpp_errors:invalid_namespace())
    end;
handle_event(internal, #xmlel{name = <<"response">>} = El, {wait_for_sasl_response, SaslState, Retries}, StateData) ->
    case exml_query:attr(El, <<"xmlns">>) of
        ?NS_SASL ->
            handle_auth_continue(StateData, El, SaslState, Retries);
        _ ->
            c2s_stream_error(StateData, mongoose_xmpp_errors:invalid_namespace())
    end;
handle_event(internal, #xmlel{name = <<"iq">>} = El, {wait_for_feature_after_auth, Retries} = C2SState, StateData) ->
    case jlib:iq_query_info(El) of
        #iq{type = set, xmlns = ?NS_BIND} = IQ ->
            handle_bind_resource(StateData, C2SState, IQ, El, Retries);
        _ ->
            Err = jlib:make_error_reply(El, mongoose_xmpp_errors:bad_request()),
            send_element_from_server_jid(StateData, Err),
            maybe_retry_state(StateData, {wait_for_feature_after_auth, Retries})
    end;
handle_event(internal, #xmlel{} = El, session_established, StateData) ->
    case verify_from(El, StateData#state.jid) of
        false ->
            c2s_stream_error(StateData, mongoose_xmpp_errors:invalid_from());
        true ->
            handle_c2s_packet(StateData, session_established, El)
    end;

%% This is an xml packet in any state other than session_established,
%% which is not one of the default ones defined in the RFC. For example stream management.
handle_event(internal, #xmlel{} = El, C2SState, StateData) ->
    handle_foreign_packet(StateData, C2SState, El);

handle_event(internal, {Name, Handler}, C2SState, StateData) when is_atom(Name), is_function(Handler, 2) ->
    C2sAcc = Handler(Name, StateData),
    handle_state_result(StateData, C2SState, undefined, C2sAcc);

handle_event({timeout, activate_socket}, activate_socket, _, StateData) ->
    activate_socket(StateData),
    keep_state_and_data;
handle_event({timeout, replaced_wait_timeout}, ReplacedPids, C2SState, StateData) ->
    [ case erlang:is_process_alive(Pid) of
          false -> ok;
          true ->
              ?LOG_WARNING(#{what => c2s_replaced_wait_timeout,
                             text => <<"Some processes are not responding when handling replace messages">>,
                             replaced_pid => Pid, state_name => C2SState, c2s_state => StateData})
      end || Pid <- ReplacedPids ],
    keep_state_and_data;
handle_event({timeout, Name}, Handler, C2SState, StateData) when is_atom(Name), is_function(Handler, 2) ->
    C2sAcc = Handler(Name, StateData),
    handle_state_result(StateData, C2SState, undefined, C2sAcc);

handle_event(state_timeout, state_timeout_termination, _FsmState, StateData) ->
    StreamConflict = mongoose_xmpp_errors:connection_timeout(),
    send_element_from_server_jid(StateData, StreamConflict),
    send_trailer(StateData),
    {stop, {shutdown, state_timeout}};

handle_event(EventType, EventContent, C2SState, StateData) ->
    handle_foreign_event(StateData, C2SState, EventType, EventContent).

-spec terminate(term(), c2s_state(), c2s_data()) -> term().
terminate(Reason, C2SState, #state{host_type = HostType, lserver = LServer} = StateData) ->
    ?LOG_DEBUG(#{what => c2s_statem_terminate, reason => Reason, c2s_state => C2SState, c2s_data => StateData}),
    Acc0 = mongoose_acc:new(#{host_type => HostType, lserver => LServer, location => ?LOCATION}),
    Acc1 = mongoose_acc:set(c2s, terminate, Reason, Acc0),
    Acc2 = mongoose_c2s_hooks:user_terminate(HostType, Acc1, hook_arg(StateData)),
    close_session(StateData, C2SState, Acc2, Reason),
    close_parser(StateData),
    close_socket(StateData),
    bounce_messages(StateData),
    ok.

%%%----------------------------------------------------------------------
%%% socket helpers
%%%----------------------------------------------------------------------

-spec handle_socket_proxy_ip_blacklist_ssl(c2s_data()) -> c2s_data().
handle_socket_proxy_ip_blacklist_ssl(StateData = #state{ranch_ref = Ref,
                                                        listener_opts = #{proxy_protocol := true}}) ->
    {ok, #{src_address := PeerIp, src_port := PeerPort}} = ranch:recv_proxy_header(Ref, 1000),
    verify_ip_is_not_blacklisted(PeerIp),
    {ok, Socket} = ranch:handshake(Ref),
    NewStateData = StateData#state{ip = {PeerIp, PeerPort}},
    handle_socket_and_ssl_config(NewStateData, Socket);
handle_socket_proxy_ip_blacklist_ssl(StateData = #state{ranch_ref = Ref,
                                                        listener_opts = #{proxy_protocol := false}}) ->
    {ok, Socket} = ranch:handshake(Ref),
    {ok, {PeerIp, _PeerPort} = IP} = ranch_tcp:peername(Socket),
    verify_ip_is_not_blacklisted(PeerIp),
    NewStateData = StateData#state{ip = IP},
    handle_socket_and_ssl_config(NewStateData, Socket).

-spec handle_socket_and_ssl_config(c2s_data(), ranch_transport:socket()) -> c2s_data().
handle_socket_and_ssl_config(
  StateData = #state{listener_opts = #{tls := #{mode := tls, module := TlsMod, opts := TlsOpts}}},
  TcpSocket) ->
    case tcp_to_tls(TlsMod, TcpSocket, TlsOpts) of
        {ok, TlsSocket} ->
            NewStateData = StateData#state{transport = TlsMod, socket = TlsSocket},
            activate_socket(NewStateData),
            NewStateData;
        {error, closed} ->
            throw({stop, {shutdown, tls_closed}});
        {error, timeout} ->
            throw({stop, {shutdown, tls_timeout}});
        {error, {tls_alert, TlsAlert}} ->
            throw({stop, TlsAlert})
    end;
handle_socket_and_ssl_config(StateData, Socket) ->
    StateData1 = StateData#state{socket = Socket},
    activate_socket(StateData1),
    StateData1.

-spec tcp_to_tls(fast_tls | just_tls, ranch_transport:socket(), list()) ->
    {ok, ranch_transport:socket()} | {error, _}.
tcp_to_tls(fast_tls, TcpSocket, TlsOpts) ->
    case fast_tls:tcp_to_tls(TcpSocket, TlsOpts) of
        {ok, TlsSocket} ->
            fast_tls:recv_data(TlsSocket, <<>>),
            {ok, TlsSocket};
        Other -> Other
    end;
tcp_to_tls(just_tls, TcpSocket, TlsOpts) ->
    case ranch_ssl:handshake(TcpSocket, TlsOpts, 1000) of
        {ok, TlsSocket, _} -> {ok, TlsSocket};
        Other -> Other
    end.

-spec verify_ip_is_not_blacklisted(inet:ip_address()) -> ok | no_return().
verify_ip_is_not_blacklisted(PeerIp) ->
    case mongoose_hooks:check_bl_c2s(PeerIp) of
        true ->
            ?LOG_INFO(#{what => c2s_blacklisted_ip, ip => PeerIp,
                        text => <<"Connection attempt from blacklisted IP">>}),
            throw({stop, {shutdown, ip_blacklisted}});
        false ->
            ok
    end.

-spec handle_socket_data(c2s_data(), {_, _, iodata()}) -> fsm_res().
handle_socket_data(StateData = #state{transport = fast_tls, socket = TlsSocket}, {tcp, _Socket, Data}) ->
    mongoose_metrics:update(global, [data, xmpp, received, encrypted_size], iolist_size(Data)),
    case fast_tls:recv_data(TlsSocket, Data) of
        {ok, DecryptedData} ->
            handle_socket_packet(StateData, DecryptedData);
        {error, _Reason} ->
            {stop, {shutdown, socket_error}, StateData}
    end;
handle_socket_data(StateData = #state{transport = ranch_tcp}, {tcp, _Socket, Data}) ->
    handle_socket_packet(StateData, Data);
handle_socket_data(StateData = #state{transport = ranch_ssl}, {ssl, _Socket, Data}) ->
    mongoose_metrics:update(global, [data, xmpp, received, encrypted_size], iolist_size(Data)),
    handle_socket_packet(StateData, Data).

handle_socket_packet(StateData = #state{parser = Parser, shaper = Shaper}, Packet) ->
    case exml_stream:parse(Parser, Packet) of
        {error, Reason} ->
            NextEvent = {next_event, internal, #xmlstreamerror{name = iolist_to_binary(Reason)}},
            {keep_state, StateData, NextEvent};
        {ok, NewParser, XmlElements} ->
            Size = iolist_size(Packet),
            {NewShaper, Pause} = shaper:update(Shaper, Size),
            mongoose_metrics:update(global, [data, xmpp, received, xml_stanza_size], Size),
            NewStateData = StateData#state{parser = NewParser, shaper = NewShaper},
            MaybePauseTimeout = maybe_pause(NewStateData, Pause),
            StreamEvents = [ {next_event, internal, XmlEl} || XmlEl <- XmlElements ],
            {keep_state, NewStateData, MaybePauseTimeout ++ StreamEvents}
    end.

-spec activate_socket(c2s_data()) -> any().
activate_socket(#state{socket = Socket, transport = fast_tls}) ->
    fast_tls:setopts(Socket, [{active, once}]);
activate_socket(#state{socket = Socket, transport = ranch_tcp}) ->
    ranch_tcp:setopts(Socket, [{active, once}]);
activate_socket(#state{socket = Socket, transport = ranch_ssl}) ->
    ranch_ssl:setopts(Socket, [{active, once}]).

-spec maybe_pause(c2s_data(), integer()) -> any().
maybe_pause(_StateData, Pause) when Pause > 0 ->
    [{{timeout, activate_socket}, Pause, activate_socket}];
maybe_pause(StateData, _) ->
    activate_socket(StateData),
    [].

-spec close_socket(c2s_data()) -> term().
close_socket(#state{socket = Socket, transport = fast_tls}) when Socket =/= undefined ->
    fast_tls:close(Socket);
close_socket(#state{socket = Socket, transport = ranch_tcp}) when Socket =/= undefined ->
    ranch_tcp:close(Socket);
close_socket(#state{socket = Socket, transport = ranch_ssl}) when Socket =/= undefined ->
    ranch_ssl:close(Socket);
close_socket(_) ->
    ok.

-spec send_text(c2s_data(), iodata()) -> maybe_ok().
send_text(StateData = #state{socket = Socket, transport = Transport}, Text) ->
    ?LOG_DEBUG(#{what => c2s_send_text, text => <<"Send XML to the socket">>,
                 send_text => Text, c2s_state => StateData}),
    send_text(Socket, Text, Transport).

send_text(Socket, Text, ranch_tcp) ->
    ranch_tcp:send(Socket, Text);
send_text(Socket, Text, fast_tls) ->
    fast_tls:send(Socket, Text);
send_text(Socket, Text, ranch_ssl) ->
    ranch_ssl:send(Socket, Text).

%%%----------------------------------------------------------------------
%%% error handler helpers
%%%----------------------------------------------------------------------

-spec handle_foreign_event(c2s_data(), c2s_state(), gen_statem:event_type(), term()) -> fsm_res().
handle_foreign_event(StateData = #state{host_type = HostType, lserver = LServer},
                     C2SState, EventType, EventContent) ->
    Params = (hook_arg(StateData, C2SState))#{event_type => EventType, event_content => EventContent},
    AccParams = #{host_type => HostType, lserver => LServer, location => ?LOCATION},
    Acc0 = mongoose_acc:new(AccParams),
    case mongoose_c2s_hooks:foreign_event(HostType, Acc0, Params) of
        {ok, _Acc1} ->
            ?LOG_WARNING(#{what => unknown_statem_event, c2s_state => C2SState,
                           event_type => EventType, event_content => EventContent}),
            keep_state_and_data;
        {stop, Acc1} ->
            handle_state_after_packet(StateData, C2SState, Acc1)
    end.

-spec handle_stop_request(c2s_data(), c2s_state(), atom()) -> fsm_res().
handle_stop_request(StateData = #state{host_type = HostType, lserver = LServer}, C2SState, Reason) ->
    Params = (hook_arg(StateData, C2SState))#{extra => Reason},
    AccParams = #{host_type => HostType, lserver => LServer, location => ?LOCATION},
    Acc0 = mongoose_acc:new(AccParams),
    Res = mongoose_c2s_hooks:user_stop_request(HostType, Acc0, Params),
    stop_if_unhandled(StateData, C2SState, Res, Reason).

-spec handle_socket_closed(c2s_data(), c2s_state(), term()) -> fsm_res().
handle_socket_closed(StateData = #state{host_type = HostType, lserver = LServer}, C2SState, Reason) ->
    Params = (hook_arg(StateData, C2SState))#{extra => Reason},
    AccParams = #{host_type => HostType, lserver => LServer, location => ?LOCATION},
    Acc0 = mongoose_acc:new(AccParams),
    Res = mongoose_c2s_hooks:user_socket_closed(HostType, Acc0, Params),
    stop_if_unhandled(StateData, C2SState, Res, socket_closed).

-spec handle_socket_error(c2s_data(), c2s_state(), term()) -> fsm_res().
handle_socket_error(StateData = #state{host_type = HostType, lserver = LServer}, C2SState, Reason) ->
    Params = (hook_arg(StateData, C2SState))#{extra => Reason},
    AccParams = #{host_type => HostType, lserver => LServer, location => ?LOCATION},
    Acc0 = mongoose_acc:new(AccParams),
    Res = mongoose_c2s_hooks:user_socket_error(HostType, Acc0, Params),
    stop_if_unhandled(StateData, C2SState, Res, socket_error).

%% These conditions required that one and only one handler declared full control over it,
%% by making the hook stop at that point. If so, the process remains alive,
%% in control of the handler, otherwise, the condition is treated as terminal.
-spec stop_if_unhandled(c2s_data(), c2s_state(), gen_hook:hook_fn_res(mongoose_acc:t()), atom()) -> fsm_res().
stop_if_unhandled(StateData, C2SState, {stop, Acc}, _) ->
    handle_state_after_packet(StateData, C2SState, Acc);
stop_if_unhandled(_, _, {ok, _Acc}, Reason) ->
    {stop, {shutdown, Reason}}.

%%%----------------------------------------------------------------------
%%% helpers
%%%----------------------------------------------------------------------

-spec handle_stream_start(c2s_data(), exml:element(), stream_state()) -> fsm_res().
handle_stream_start(S0, StreamStart, StreamState) ->
    Lang = get_xml_lang(StreamStart),
    LServer = jid:nameprep(exml_query:attr(StreamStart, <<"to">>, <<>>)),
    case {StreamState,
          exml_query:attr(StreamStart, <<"xmlns:stream">>, <<>>),
          exml_query:attr(StreamStart, <<"version">>, <<>>),
          mongoose_domain_api:get_domain_host_type(LServer)} of
        {stream_start, ?NS_STREAM, <<"1.0">>, {ok, HostType}} ->
            S = S0#state{host_type = HostType, lserver = LServer, lang = Lang},
            stream_start_features_before_auth(S);
        {authenticated, ?NS_STREAM, <<"1.0">>, {ok, HostType}} ->
            S = S0#state{host_type = HostType, lserver = LServer, lang = Lang},
            stream_start_features_after_auth(S);
        {_, ?NS_STREAM, _Pre1_0, {ok, HostType}} ->
            %% (http://xmpp.org/rfcs/rfc6120.html#streams-negotiation-features)
            S = S0#state{host_type = HostType, lserver = LServer, lang = Lang},
            stream_start_error(S, mongoose_xmpp_errors:unsupported_version());
        {_, ?NS_STREAM, _, {error, not_found}} ->
            stream_start_error(S0, mongoose_xmpp_errors:host_unknown());
        {_, _, _, _} ->
            stream_start_error(S0, mongoose_xmpp_errors:invalid_namespace())
    end.

-spec handle_starttls(c2s_data(), exml:element(), cyrsasl:sasl_state(), retries()) -> fsm_res().
handle_starttls(StateData = #state{transport = ranch_tcp,
                                   socket = TcpSocket,
                                   parser = Parser,
                                   listener_opts = #{tls := #{module := TlsMod, opts := TlsOpts}}},
                _, _, _) ->
    ranch_tcp:setopts(TcpSocket, [{active, false}]),
    send_xml(StateData, mongoose_c2s_stanzas:tls_proceed()), %% send last negotiation chunk via tcp
    case tcp_to_tls(TlsMod, TcpSocket, TlsOpts) of
        {ok, TlsSocket} ->
            {ok, NewParser} = exml_stream:reset_parser(Parser),
            NewStateData = StateData#state{transport = TlsMod,
                                           socket = TlsSocket,
                                           parser = NewParser,
                                           streamid = new_stream_id()},
            activate_socket(NewStateData),
            {next_state, {wait_for_stream, stream_start}, NewStateData, state_timeout()};
        {error, closed} ->
            {stop, {shutdown, tls_closed}};
        {error, timeout} ->
            {stop, {shutdown, tls_timeout}};
        {error, {tls_alert, TlsAlert}} ->
            {stop, TlsAlert}
    end;
handle_starttls(StateData, El, SaslState, Retries) ->
    Err = jlib:make_error_reply(El, mongoose_xmpp_errors:bad_request(StateData#state.lang, <<"bad_config">>)),
    send_element_from_server_jid(StateData, Err),
    maybe_retry_state(StateData, {wait_for_feature_before_auth, SaslState, Retries}).

-spec handle_auth_start(c2s_data(), exml:element(), cyrsasl:sasl_state(), retries()) -> fsm_res().
handle_auth_start(StateData, El, SaslState, Retries) ->
    case {StateData#state.transport, StateData#state.listener_opts} of
        {ranch_tcp, #{tls := #{mode := starttls_required}}} ->
            c2s_stream_error(StateData, mongoose_xmpp_errors:policy_violation(StateData#state.lang, <<"Use of STARTTLS required">>));
        _ ->
            do_handle_auth_start(StateData, El, SaslState, Retries)
    end.

-spec do_handle_auth_start(c2s_data(), exml:element(), cyrsasl:sasl_state(), retries()) -> fsm_res().
do_handle_auth_start(StateData, El, SaslState, Retries) ->
    Mech = exml_query:attr(El, <<"mechanism">>),
    ClientIn = base64:mime_decode(exml_query:cdata(El)),
    HostType = StateData#state.host_type,
    AuthMech = [M || M <- cyrsasl:listmech(HostType), filter_mechanism(M)],
    SocketData = #{socket => StateData#state.socket, auth_mech => AuthMech},
    StepResult = cyrsasl:server_start(SaslState, Mech, ClientIn, SocketData),
    handle_sasl_step(StateData, StepResult, SaslState, Retries).

-spec handle_auth_continue(c2s_data(), exml:element(), cyrsasl:sasl_state(), retries()) -> fsm_res().
handle_auth_continue(StateData, El, SaslState, Retries) ->
    ClientIn = base64:mime_decode(exml_query:cdata(El)),
    StepResult = cyrsasl:server_step(SaslState, ClientIn),
    handle_sasl_step(StateData, StepResult, SaslState, Retries).

-spec handle_sasl_step(c2s_data(), term(), cyrsasl:sasl_state(), retries()) -> fsm_res().
handle_sasl_step(StateData, {ok, Creds}, _, _) ->
    handle_sasl_success(StateData, Creds);
handle_sasl_step(StateData, {continue, ServerOut, NewSaslState}, _, Retries) ->
    Challenge  = [#xmlcdata{content = jlib:encode_base64(ServerOut)}],
    send_element_from_server_jid(StateData, mongoose_c2s_stanzas:sasl_challenge_stanza(Challenge)),
    {next_state, {wait_for_sasl_response, NewSaslState, Retries}, StateData, state_timeout()};
handle_sasl_step(#state{host_type = HostType, lserver = Server} = StateData,
                 {error, Error, Username}, SaslState, Retries) ->
    ?LOG_INFO(#{what => auth_failed,
                text => <<"Failed SASL authentication">>,
                user => Username, lserver => Server, c2s_state => StateData}),
    mongoose_hooks:auth_failed(HostType, Server, Username),
    send_element_from_server_jid(StateData, mongoose_c2s_stanzas:sasl_failure_stanza(Error)),
    maybe_retry_state(StateData, {wait_for_feature_before_auth, SaslState, Retries});
handle_sasl_step(#state{host_type = HostType, lserver = Server} = StateData,
                 {error, Error}, SaslState, Retries) ->
    mongoose_hooks:auth_failed(HostType, Server, unknown),
    send_element_from_server_jid(StateData, mongoose_c2s_stanzas:sasl_failure_stanza(Error)),
    maybe_retry_state(StateData, {wait_for_feature_before_auth, SaslState, Retries}).

-spec handle_sasl_success(c2s_data(), term()) -> fsm_res().
handle_sasl_success(State, Creds) ->
    ServerOut = mongoose_credentials:get(Creds, sasl_success_response, undefined),
    send_element_from_server_jid(State, mongoose_c2s_stanzas:sasl_success_stanza(ServerOut)),
    User = mongoose_credentials:get(Creds, username),
    NewState = State#state{streamid = new_stream_id(),
                           jid = jid:make_bare(User, State#state.lserver)},
    ?LOG_INFO(#{what => auth_success, text => <<"Accepted SASL authentication">>,
                c2s_state => NewState}),
    {next_state, {wait_for_stream, authenticated}, NewState, state_timeout()}.

-spec stream_start_features_before_auth(c2s_data()) -> fsm_res().
stream_start_features_before_auth(#state{host_type = HostType, lserver = LServer,
                                         lang = Lang, listener_opts = LOpts} = S) ->
    send_header(S, LServer, <<"1.0">>, Lang),
    CredOpts = mongoose_credentials:make_opts(LOpts),
    Creds = mongoose_credentials:new(LServer, HostType, CredOpts),
    SASLState = cyrsasl:server_new(<<"jabber">>, LServer, HostType, <<>>, [], Creds),
    StreamFeatures = mongoose_c2s_stanzas:stream_features_before_auth(HostType, LServer, LOpts),
    send_element_from_server_jid(S, StreamFeatures),
    {next_state, {wait_for_feature_before_auth, SASLState, ?AUTH_RETRIES}, S, state_timeout()}.

-spec stream_start_features_after_auth(c2s_data()) -> fsm_res().
stream_start_features_after_auth(#state{host_type = HostType, lserver = LServer, lang = Lang} = S) ->
    send_header(S, LServer, <<"1.0">>, Lang),
    StreamFeatures = mongoose_c2s_stanzas:stream_features_after_auth(HostType, LServer),
    send_element_from_server_jid(S, StreamFeatures),
    {next_state, {wait_for_feature_after_auth, ?BIND_RETRIES}, S, state_timeout()}.

-spec handle_bind_resource(c2s_data(), c2s_state(), jlib:iq(), exml:element(), retries()) -> fsm_res().
handle_bind_resource(StateData, C2SState, #iq{sub_el = SubEl} = IQ, El, Retries) ->
    R1 = exml_query:path(SubEl, [{element, <<"resource">>}, cdata]),
    R2 = jid:resourceprep(R1),
    handle_bind_resource(StateData, C2SState, IQ, R2, El, Retries).

-spec handle_bind_resource(c2s_data(), c2s_state(), jlib:iq(), jid:lresource() | error, exml:element(), retries()) ->
    fsm_res().
handle_bind_resource(StateData, _, _, error, El, Retries) ->
    Err = jlib:make_error_reply(El, mongoose_xmpp_errors:bad_request()),
    send_element_from_server_jid(StateData, Err),
    maybe_retry_state(StateData, {wait_for_feature_after_auth, Retries});
handle_bind_resource(StateData, C2SState, IQ, <<>>, _, _) ->
    do_bind_resource(StateData, C2SState, IQ, generate_random_resource());
handle_bind_resource(StateData, C2SState, IQ, Res, _, _) ->
    do_bind_resource(StateData, C2SState, IQ, Res).

%% As stated in BCP47, 4.4.1:
%% Protocols or specifications that specify limited buffer sizes for
%% language tags MUST allow for language tags of at least 35 characters.
%% Do not store long language tag to avoid possible DoS/flood attacks
-spec get_xml_lang(exml:element()) -> <<_:8, _:_*8>>.
get_xml_lang(StreamStart) ->
    case exml_query:attr(StreamStart, <<"xml:lang">>) of
        Lang when is_binary(Lang), 0 < byte_size(Lang), byte_size(Lang) =< 35 ->
            Lang;
        _ ->
            ?MYLANG
    end.

%% Note that RFC 3921 said:
%% > Upon establishing a session, a connected resource is said to be an "active resource".
%% But, RFC 6121 says:
%% > [RFC3921] specified one additional
%%  precondition: formal establishment of an instant messaging and
%%  presence session.  Implementation and deployment experience has
%%  shown that this additional step is unnecessary.  However, for
%%  backward compatibility an implementation MAY still offer that
%%  feature.  This enables older software to connect while letting
%%  newer software save a round trip.
-spec do_bind_resource(c2s_data(), c2s_state(), jlib:iq(), jid:lresource()) -> fsm_res().
do_bind_resource(StateData, C2SState, IQ, Res) ->
    Jid = jid:replace_resource(StateData#state.jid, Res),
    open_session(StateData#state{jid = Jid}, C2SState, IQ, Jid).

%% Note that RFC 3921 said:
%% > If no priority is provided, a server SHOULD consider the priority to be zero.
%% But, RFC 6121 says:
%% > If no priority is provided, the processing server or client MUST consider the priority to be zero.
-spec open_session(c2s_data(), c2s_state(), jlib:iq(), jid:jid()) -> fsm_res().
open_session(#state{host_type = HostType, lserver = LServer} = StateData, C2SState, IQ, Jid) ->
    BindResult = mongoose_c2s_stanzas:successful_resource_binding(IQ, Jid),
    MAcc = mongoose_c2s_acc:new(#{c2s_state => session_established, socket_send => [BindResult]}),
    AccParams = #{host_type => HostType, lserver => LServer, location => ?LOCATION, statem_acc => MAcc},
    Acc0 = mongoose_acc:new(AccParams),
    Params = (hook_arg(StateData, C2SState)),
    ?LOG_INFO(#{what => c2s_opened_session, text => <<"Opened session">>, c2s_state => StateData}),
    case mongoose_c2s_hooks:user_open_session(HostType, Acc0, Params) of
        {ok, Acc1} ->
            do_open_session(StateData, C2SState, Acc1);
        {stop, _Acc1} ->
            c2s_stream_error(StateData, mongoose_xmpp_errors:stream_not_authorized()),
            {stop, StateData}
    end.

-spec do_open_session(c2s_data(), c2s_state(), mongoose_acc:t()) -> fsm_res().
do_open_session(#state{host_type = HostType, sid = SID, jid = Jid} = StateData, C2SState, Acc) ->
    FsmActions = case ejabberd_sm:open_session(HostType, SID, Jid, 0, #{}) of
                     [] -> [];
                     ReplacedPids ->
                         Timeout = mongoose_config:get_opt({replaced_wait_timeout, HostType}),
                         [{{timeout, replaced_wait_timeout}, Timeout, ReplacedPids}]
                 end,
    Acc1 = mongoose_c2s_acc:to_acc(Acc, actions, FsmActions),
    handle_state_after_packet(StateData, C2SState, Acc1).

-spec maybe_retry_state(c2s_data(), c2s_state()) -> fsm_res().
maybe_retry_state(StateData, C2SState) ->
    case maybe_retry_state(C2SState) of
        {stop, Reason} ->
            {stop, Reason, StateData};
        NextFsmState ->
            {next_state, NextFsmState, StateData, state_timeout()}
    end.

-spec maybe_retry_state(c2s_state()) -> c2s_state() | {stop, term()}.
maybe_retry_state(connect) -> connect;
maybe_retry_state(session_established) -> session_established;
maybe_retry_state({wait_for_stream, StreamState}) ->
    {wait_for_stream, StreamState};
maybe_retry_state({wait_for_feature_after_auth, 0}) ->
    {stop, {shutdown, retries}};
maybe_retry_state({wait_for_feature_before_auth, _, 0}) ->
    {stop, {shutdown, retries}};
maybe_retry_state({wait_for_sasl_response, _, 0}) ->
    {stop, {shutdown, retries}};
maybe_retry_state({wait_for_feature_after_auth, Retries}) ->
    {wait_for_feature_after_auth, Retries - 1};
maybe_retry_state({wait_for_feature_before_auth, SaslState, Retries}) ->
    {wait_for_feature_before_auth, SaslState, Retries - 1};
maybe_retry_state({wait_for_sasl_response, SaslState, Retries}) ->
    {wait_for_sasl_response, SaslState, Retries - 1}.

%% @doc Check 'from' attribute in stanza RFC 6120 Section 8.1.2.1
-spec verify_from(exml:element(), jid:jid()) -> boolean().
verify_from(El, StateJid) ->
    case exml_query:attr(El, <<"from">>) of
        undefined -> true;
        SJid ->
            jid:are_equal(jid:from_binary(SJid), StateJid)
    end.

-spec handle_foreign_packet(c2s_data(), c2s_state(), exml:element()) -> fsm_res().
handle_foreign_packet(StateData = #state{host_type = HostType, lserver = LServer}, C2SState, El) ->
    ServerJid = jid:make_noprep(<<>>, LServer, <<>>),
    AccParams = #{host_type => HostType, lserver => LServer, location => ?LOCATION,
                  element => El, from_jid => ServerJid, to_jid => ServerJid},
    Acc0 = mongoose_acc:new(AccParams),
    Params = hook_arg(StateData, C2SState),
    {_, Acc1} = mongoose_c2s_hooks:user_send_xmlel(HostType, Acc0, Params),
    handle_state_after_packet(StateData, C2SState, Acc1).

-spec handle_c2s_packet(c2s_data(), c2s_state(), exml:element()) -> fsm_res().
handle_c2s_packet(StateData = #state{host_type = HostType}, C2SState, El) ->
    Acc0 = element_to_origin_accum(StateData, El),
    Acc1 = mongoose_hooks:c2s_preprocessing_hook(HostType, Acc0, StateData),
    case mongoose_acc:get(hook, result, undefined, Acc1) of
        drop -> {next_state, session_established, StateData};
        _ -> do_handle_c2s_packet(StateData, C2SState, Acc1)
    end.

-spec do_handle_c2s_packet(c2s_data(), c2s_state(), mongoose_acc:t()) -> fsm_res().
do_handle_c2s_packet(StateData = #state{host_type = HostType}, C2SState, Acc) ->
    case mongoose_c2s_hooks:user_send_packet(HostType, Acc, hook_arg(StateData)) of
        {ok, Acc1} ->
            Acc2 = handle_outgoing_stanza(StateData, Acc1, mongoose_acc:stanza_name(Acc1)),
            handle_state_after_packet(StateData, C2SState, Acc2);
        {stop, Acc1} ->
            handle_state_after_packet(StateData, C2SState, Acc1)
    end.

%% @doc Process packets sent by the user (coming from user on c2s XMPP connection)
-spec handle_outgoing_stanza(c2s_data(), mongoose_acc:t(), binary()) -> mongoose_acc:t().
handle_outgoing_stanza(StateData = #state{host_type = HostType}, Acc, <<"message">>) ->
    TS0 = mongoose_acc:timestamp(Acc),
    Acc1 = mongoose_c2s_hooks:user_send_message(HostType, Acc, hook_arg(StateData)),
    Acc2 = maybe_route(Acc1),
    TS1 = erlang:system_time(microsecond),
    mongoose_metrics:update(HostType, [data, xmpp, sent, message, processing_time], (TS1 - TS0)),
    Acc2;
handle_outgoing_stanza(StateData = #state{host_type = HostType}, Acc, <<"iq">>) ->
    Acc1 = mongoose_c2s_hooks:user_send_iq(HostType, Acc, hook_arg(StateData)),
    maybe_route(Acc1);
handle_outgoing_stanza(StateData = #state{host_type = HostType}, Acc, <<"presence">>) ->
    {_, Acc1} = mongoose_c2s_hooks:user_send_presence(HostType, Acc, hook_arg(StateData)),
    Acc1;
handle_outgoing_stanza(StateData = #state{host_type = HostType}, Acc, _) ->
    {_, Acc1} = mongoose_c2s_hooks:user_send_xmlel(HostType, Acc, hook_arg(StateData)),
    Acc1.

-spec handle_incoming_stanza(c2s_data(), c2s_state(), mongoose_acc:t()) -> fsm_res().
handle_incoming_stanza(StateData = #state{host_type = HostType}, C2SState, Acc) ->
    case mongoose_c2s_hooks:user_receive_packet(HostType, Acc, hook_arg(StateData)) of
        {ok, Acc1} ->
            Res = process_incoming_stanza(StateData, Acc1, mongoose_acc:stanza_name(Acc1)),
            Acc2 = maybe_deliver(StateData, Res),
            handle_state_after_packet(StateData, C2SState, Acc2);
        {stop, _Acc1} ->
            keep_state_and_data
    end.

%% @doc Process packets sent to the user (coming from user on c2s XMPP connection)
-spec process_incoming_stanza(c2s_data(), mongoose_acc:t(), binary()) ->
    gen_hook:hook_fn_ret(mongoose_acc:t()).
process_incoming_stanza(StateData = #state{host_type = HostType}, Acc, <<"message">>) ->
    mongoose_c2s_hooks:user_received_message(HostType, Acc, hook_arg(StateData));
process_incoming_stanza(StateData = #state{host_type = HostType}, Acc, <<"iq">>) ->
    mongoose_c2s_hooks:user_received_iq(HostType, Acc, hook_arg(StateData));
process_incoming_stanza(StateData = #state{host_type = HostType}, Acc, <<"presence">>) ->
    mongoose_c2s_hooks:user_received_presence(HostType, Acc, hook_arg(StateData));
process_incoming_stanza(StateData = #state{host_type = HostType}, Acc, _) ->
    mongoose_c2s_hooks:user_received_xmlel(HostType, Acc, hook_arg(StateData)).

-spec handle_state_after_packet(c2s_data(), c2s_state(), mongoose_acc:t()) -> fsm_res().
handle_state_after_packet(StateData, C2SState, Acc) ->
    handle_state_result(StateData, C2SState, Acc, mongoose_c2s_acc:get_statem_result(Acc)).

-spec handle_state_result(c2s_data(),
                          c2s_state(),
                          undefined | mongoose_acc:t(),
                          mongoose_c2s_acc:t()) -> fsm_res().
handle_state_result(StateData, _, _, #{hard_stop := Reason}) when Reason =/= undefined ->
    {stop, {shutdown, Reason}, StateData};
handle_state_result(StateData0, C2SState, MaybeAcc,
                    #{handlers := MaybeHandlers, actions := MaybeActions,
                      c2s_state := MaybeNewFsmState, c2s_data := MaybeNewFsmData,
                      socket_send := MaybeSocketSend}) ->
    NextFsmState = case MaybeNewFsmState of
                       undefined -> C2SState;
                       _ -> MaybeNewFsmState
                   end,
    StateData1 = case MaybeNewFsmData of
                     undefined -> StateData0;
                     _ -> MaybeNewFsmData
                 end,
    StateData2 = case map_size(MaybeHandlers) of
                     0 -> StateData1;
                     _ -> merge_handlers(StateData1, MaybeHandlers)
                 end,
    maybe_send_xml(StateData2, MaybeAcc, MaybeSocketSend),
    {next_state, NextFsmState, StateData2, MaybeActions}.

maybe_send_xml(_StateData, _Acc, []) ->
    ok;
maybe_send_xml(StateData = #state{host_type = HostType, lserver = LServer}, undefined, ToSend) ->
    Acc = mongoose_acc:new(#{host_type => HostType, lserver => LServer, location => ?LOCATION}),
    send_element(StateData, ToSend, Acc);
maybe_send_xml(StateData, Acc, ToSend) ->
    send_element(StateData, ToSend, Acc).

-spec maybe_deliver(c2s_data(), gen_hook:hook_fn_ret(mongoose_acc:t())) -> mongoose_acc:t().
maybe_deliver(StateData, {ok, Acc}) ->
    {From, To, El} = mongoose_acc:packet(Acc),
    FinalEl = jlib:replace_from_to(From, To, El),
    send_element(StateData, FinalEl, Acc),
    Acc;
maybe_deliver(_, {stop, Acc}) ->
    Acc.

-spec maybe_route(gen_hook:hook_fn_ret(mongoose_acc:t())) -> mongoose_acc:t().
maybe_route({ok, Acc}) ->
    {FromJid, ToJid, El} = mongoose_acc:packet(Acc),
    ejabberd_router:route(FromJid, ToJid, Acc, El),
    Acc;
maybe_route({stop, Acc}) ->
    Acc.

%% @doc This function is executed when c2s receives a stanza from the TCP connection.
-spec element_to_origin_accum(c2s_data(), exml:element()) -> mongoose_acc:t().
element_to_origin_accum(StateData = #state{sid = SID, jid = Jid}, El) ->
    BaseParams = #{host_type => StateData#state.host_type,
                   lserver => StateData#state.lserver,
                   location => ?LOCATION,
                   element => El,
                   from_jid => Jid},
    Params = case exml_query:attr(El, <<"to">>) of
                 undefined -> BaseParams#{ to_jid => jid:to_bare(Jid) };
                 _ToBin -> BaseParams
             end,
    Acc = mongoose_acc:new(Params),
    mongoose_acc:set_permanent(c2s, [{module, ?MODULE}, {origin_sid, SID}, {origin_jid, Jid}], Acc).

-spec stream_start_error(c2s_data(), exml:element()) -> fsm_res().
stream_start_error(StateData, Error) ->
    send_header(StateData, ?MYNAME, <<>>, StateData#state.lang),
    c2s_stream_error(StateData, Error).

-spec send_header(StateData :: c2s_data(),
                  Server :: jid:lserver(),
                  Version :: binary(),
                  Lang :: ejabberd:lang()) -> any().
send_header(StateData, Server, Version, Lang) ->
    Header = mongoose_c2s_stanzas:stream_header(Server, Version, Lang, StateData#state.streamid),
    send_text(StateData, Header).

send_trailer(StateData) ->
    send_text(StateData, ?STREAM_TRAILER).

-spec c2s_stream_error(c2s_data(), exml:element()) -> fsm_res().
c2s_stream_error(StateData, Error) ->
    ?LOG_DEBUG(#{what => c2s_stream_error, xml_error => Error, c2s_state => StateData}),
    send_element_from_server_jid(StateData, Error),
    send_text(StateData, ?STREAM_TRAILER),
    {stop, {shutdown, stream_error}, StateData}.

-spec send_element_from_server_jid(c2s_data(), exml:element()) -> any().
send_element_from_server_jid(StateData, El) ->
    Acc = mongoose_acc:new(
            #{host_type => StateData#state.host_type,
              lserver => StateData#state.lserver,
              location => ?LOCATION,
              from_jid => jid:make_noprep(<<>>, StateData#state.lserver, <<>>),
              to_jid => StateData#state.jid,
              element => El}),
    send_element(StateData, El, Acc).

-spec bounce_messages(c2s_data()) -> ok.
bounce_messages(StateData) ->
    receive
        {route, Acc} ->
            reroute(StateData, Acc),
            bounce_messages(StateData);
        {route, _From, _To, Acc} ->
            reroute(StateData, Acc),
            bounce_messages(StateData);
        _ ->
            bounce_messages(StateData)
    after 0 -> ok
    end.

reroute(#state{sid = Sid}, Acc) ->
    {From, To, _El} = mongoose_acc:packet(Acc),
    Acc2 = patch_acc_for_reroute(Acc, Sid),
    ejabberd_router:route(From, To, Acc2).

patch_acc_for_reroute(Acc, Sid) ->
    case mongoose_acc:stanza_name(Acc) of
        <<"message">> ->
            Acc;
        _ -> %% IQs and presences are allowed to come to the same Sid only
            case mongoose_acc:get(c2s, receiver_sid, undefined, Acc) of
                undefined ->
                    mongoose_acc:set_permanent(c2s, receiver_sid, Sid, Acc);
                _ ->
                    Acc
            end
    end.

-spec close_parser(c2s_data()) -> ok.
close_parser(#state{parser = undefined}) -> ok;
close_parser(#state{parser = Parser}) -> exml_stream:free_parser(Parser).

-spec close_session(c2s_data(), c2s_state(), mongoose_acc:t(), term()) -> mongoose_acc:t().
close_session(StateData, session_established, Acc, Reason) ->
    Status = close_session_status(Reason),
    PresenceUnavailable = mongoose_c2s_stanzas:presence_unavailable(Status),
    Acc1 = mongoose_acc:update_stanza(#{from_jid => StateData#state.jid,
                                        to_jid => jid:to_bare(StateData#state.jid),
                                        element => PresenceUnavailable}, Acc),
    ejabberd_sm:close_session_unset_presence(
      Acc1, StateData#state.sid, StateData#state.jid, Status, sm_unset_reason(Reason));
close_session(_, _, Acc, _) ->
    Acc.

close_session_status({shutdown, retries}) ->
    <<"Too many attempts">>;
close_session_status({shutdown, replaced}) ->
    <<"Replaced by new connection">>;
close_session_status(normal) ->
    <<>>;
close_session_status(_) ->
    <<"Unknown condition">>.

sm_unset_reason({shutdown, retries}) ->
    retries;
sm_unset_reason({shutdown, replaced}) ->
    replaced;
sm_unset_reason(normal) ->
    normal;
sm_unset_reason(_) ->
    error.

%% @doc This is the termination point - from here stanza is sent to the user
-spec send_element(c2s_data(), exml:element(), mongoose_acc:t()) -> maybe_ok().
send_element(StateData = #state{host_type = <<>>}, El, _) ->
    send_xml(StateData, El);
send_element(StateData = #state{host_type = HostType}, El, Acc) ->
    mongoose_hooks:xmpp_send_element(HostType, Acc, El),
    send_xml(StateData, El).

-spec send_xml(c2s_data(), exml_stream:element() | [exml_stream:element()]) -> maybe_ok().
send_xml(StateData, Xml) ->
    send_text(StateData, exml:to_iolist(Xml)).

state_timeout() ->
    Timeout = mongoose_config:get_opt(c2s_state_timeout),
    {state_timeout, Timeout, state_timeout_termination}.

filter_mechanism(<<"EXTERNAL">>) -> false;
filter_mechanism(<<"SCRAM-SHA-1-PLUS">>) -> false;
filter_mechanism(<<"SCRAM-SHA-", _N:3/binary, "-PLUS">>) -> false;
filter_mechanism(_) -> true.

-spec new_stream_id() -> binary().
new_stream_id() ->
    mongoose_bin:gen_from_crypto().

-spec generate_random_resource() -> jid:lresource().
generate_random_resource() ->
    <<(mongoose_bin:gen_from_timestamp())/binary, "-", (mongoose_bin:gen_from_crypto())/binary>>.

-spec hook_arg(c2s_data()) -> mongoose_c2s_hooks:hook_params().
hook_arg(StateData) ->
    hook_arg(StateData, session_established).

-spec hook_arg(c2s_data(), c2s_state()) -> mongoose_c2s_hooks:hook_params().
hook_arg(StateData, C2SState) ->
    #{c2s_data => StateData, c2s_state => C2SState}.

%%%----------------------------------------------------------------------
%%% state helpers
%%%----------------------------------------------------------------------

-spec get_host_type(c2s_data()) -> mongooseim:host_type().
get_host_type(#state{host_type = HostType}) ->
    HostType.

-spec get_lserver(c2s_data()) -> jid:lserver().
get_lserver(#state{lserver = LServer}) ->
    LServer.

-spec get_sid(c2s_data()) -> ejabberd_sm:sid().
get_sid(#state{sid = Sid}) ->
    Sid.

-spec get_ip(c2s_data()) -> term().
get_ip(#state{ip = Ip}) ->
    Ip.

-spec get_socket(c2s_data()) -> term().
get_socket(#state{socket = Socket}) ->
    Socket.

-spec get_jid(c2s_data()) -> jid:jid() | undefined.
get_jid(#state{jid = Jid}) ->
    Jid.

-spec get_lang(c2s_data()) -> ejabberd:lang().
get_lang(#state{lang = Lang}) ->
    Lang.

-spec get_stream_id(c2s_data()) -> binary().
get_stream_id(#state{streamid = StreamId}) ->
    StreamId.

-spec get_handler(c2s_data(), atom()) -> term() | {error, not_found}.
get_handler(#state{handlers = Handlers}, HandlerName) ->
    maps:get(HandlerName, Handlers, {error, not_found}).

-spec merge_handlers(c2s_data(), map()) -> c2s_data().
merge_handlers(StateData = #state{handlers = StateHandlers}, MoreHandlers) ->
    StateData#state{handlers = maps:merge(StateHandlers, MoreHandlers)}.

-spec remove_handler(c2s_data(), atom()) -> c2s_data().
remove_handler(StateData = #state{handlers = Handlers}, HandlerName) ->
    StateData#state{handlers = maps:remove(HandlerName, Handlers)}.

-spec merge_states(c2s_data(), c2s_data()) -> c2s_data().
merge_states(S0 = #state{},
             S1 = #state{}) ->
    S1#state{
      host_type = S0#state.host_type,
      lserver = S0#state.lserver,
      jid = S0#state.jid,
      handlers = S0#state.handlers
     }.

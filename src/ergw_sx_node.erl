%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_node).

-behavior(gen_statem).
-behavior(ergw_context).

-compile({parse_transform, cut}).

%% API
-export([select_sx_node/2, select_sx_node/3]).
-export([start_link/3, send/4, call/3, call_async/3,
	 get_vrfs/2, handle_request/3, response/3]).
-ifdef(TEST).
-export([stop/1, seconds_to_sntp_time/1]).
-endif.

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, handle_event/4,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/inet.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-record(data, {retries = 0  :: non_neg_integer(),
	       recovery_ts       :: undefined | non_neg_integer(),
	       pfcp_ctx          :: #pfcp_ctx{},
	       upf_data_endp     :: #gtp_endp{},
	       cp,
	       dp,
	       vrfs}).

-define(AssocReqTimeout, 200).
-define(AssocReqRetries, 5).
-define(AssocTimeout, 500).
-define(AssocRetries, 5).

%%====================================================================
%% API
%%====================================================================

select_sx_node(Candidates, Context) ->
    case connect_sx_node(Candidates) of
	{ok, Pid} ->
	    monitor(process, Pid),
	    call_3(Pid, attach, Context);
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Context))
    end.

select_sx_node(APN, Services, NodeSelect) ->
    case ergw_node_selection:candidates(APN, Services, NodeSelect) of
	Nodes when is_list(Nodes), length(Nodes) /= 0 ->
	    connect_sx_node(Nodes);
	Other ->
	    lager:error("No Sx node for APN '~w', got ~p", [APN, Other]),
	    {error, not_found}
    end.

start_link(Node, IP4, IP6) ->
    gen_statem:start_link(?MODULE, [Node, IP4, IP6], []).

-ifdef(TEST).
stop(Pid) when is_pid(Pid) ->
    gen_statem:call(Pid, stop).
-endif.

send(#pfcp_ctx{node = Handler}, Intf, VRF, Data)
  when is_pid(Handler), is_atom(Intf), is_binary(Data) ->
    gen_statem:cast(Handler, {send, Intf, VRF, Data}).

%% call/3
call(#pfcp_ctx{node = Node, seid = #seid{dp = SEID}}, #pfcp{} = Request, OpaqueRef) ->
    call_3(Node, Request#pfcp{seid = SEID}, OpaqueRef);
call(#pfcp_ctx{node = Node}, Request, OpaqueRef) ->
    call_3(Node, Request, OpaqueRef).

call_async(#pfcp_ctx{node = Node, seid = #seid{dp = SEID}},
	   #pfcp{} = Request, {_,_,_} = Cb) ->
    gen_statem:cast(Node, {Request#pfcp{seid = SEID}, Cb}).

get_vrfs(PCtx, Context) ->
    call(PCtx, get_vrfs, Context).

response(Pid, CbData, Response) ->
    gen_statem:cast(Pid, {response, CbData, Response}).

handle_request(ReqKey, IP, #pfcp{type = heartbeat_request} = Request) ->
    case ergw_sx_node_reg:lookup(IP) of
	{ok, Pid} when is_pid(Pid) ->
	    lager:debug("cast HB request to ~p", [Pid]),
	    gen_statem:cast(Pid, {request, ReqKey, Request});
	_Other ->
	    lager:error("lookup for ~p failed with ~p", [IP, _Other]),
	    heartbeat_response(ReqKey, Request)
    end,
    ok;
handle_request(ReqKey, _IP, #pfcp{type = session_report_request} = Report) ->
    spawn(fun() -> handle_request_fun(ReqKey, Report) end),
    ok.

handle_request_fun(ReqKey, #pfcp{type = session_report_request} = Report) ->
    {Ctx, IEs} =
	case ergw_context:sx_report(Report) of
	    {ok, Ctx0} ->
		{Ctx0, #{pfcp_cause => #pfcp_cause{cause = 'Request accepted'}}};
	    {ok, Ctx0, Cause}
	      when is_atom(Cause) ->
		{Ctx0, #{pfcp_cause => #pfcp_cause{cause = Cause}}};
	    {ok, Ctx0, IEs0}
	      when is_map(IEs0) ->
		{Ctx0, IEs0};
	    {error, not_found} ->
		{0, #{pfcp_cause => #pfcp_cause{cause = 'Session context not found'}}}
	end,

    Response = make_response(session_report_response, Ctx, Report, IEs),
    ergw_sx_socket:send_response(ReqKey, Response, true),
    ok.

%%%===================================================================
%%% call/cast wrapper for gtp_port
%%%===================================================================

call_3(Pid, Request, OpaqueRef)
  when is_pid(Pid) ->
    lager:debug("DP Server Call ~p: ~p", [Pid, lager:pr(Request, ?MODULE)]),
    case gen_statem:call(Pid, Request) of
	{error, dead} ->
	    throw(?CTX_ERR(?FATAL, system_failure, OpaqueRef));
	Other ->
	    Other
    end.

%%====================================================================
%% ergw_context API
%%====================================================================

sx_report(Server, Report) ->
    gen_statem:call(Server, {sx, Report}).

port_message(Request, Msg) ->
    lager:error("unhandled port message (~p, ~p)", [Request, Msg]),
    erlang:error(badarg, [Request, Msg]).

port_message(Server, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    gen_server:cast(Server, {handle_pdu, Request, Msg});
port_message(_Server, Request, Msg, _Resent) ->
    lager:error("unhandled port message (~p, ~p)", [Request, Msg]),
    erlang:error(badarg, [Request, Msg]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([Node, IP4, IP6]) ->
    IP = if length(IP4) /= 0 -> hd(IP4);
	    length(IP6) /= 0 -> hd(IP6)
	 end,

    ergw_sx_node_reg:register(Node, self()),
    ergw_sx_node_reg:register(IP, self()),

    {ok, CP, GtpPort} = ergw_sx_socket:id(),
    #gtp_port{name = CntlPortName} = GtpPort,
    {ok, TEI} = gtp_context_reg:alloc_tei(GtpPort),
    SEID = ergw_sx_socket:seid(),
    PCtx = #pfcp_ctx{
	      name = Node,
	      node = self(),
	      seid = #seid{cp = SEID},
	      cp_port = GtpPort,
	      cp_tei = TEI
	     },

    RegKeys =
	[{CntlPortName, {teid, 'gtp-u', TEI}},
	 {seid, SEID}],
    gtp_context_reg:register(RegKeys, ?MODULE, self()),

    Data = #data{pfcp_ctx = PCtx,
		 cp = CP,
		 dp = #node{node = Node, ip = IP},
		 vrfs = init_vrfs(Node)
		},
    {ok, dead, Data}.

handle_event(enter, OldState, dead, Data)
  when OldState =:= connected;
       OldState =:= dead ->
    {next_state, dead, Data#data{retries = 0, recovery_ts = undefined}, [{state_timeout, 0, setup}]};
handle_event(enter, _, dead, #data{retries = Retries} = Data) ->
    Timeout = (2 bsl Retries) * ?AssocTimeout,
    lager:debug("Timeout: ~w/~w", [Retries, Timeout]),
    {next_state, dead, Data, [{state_timeout, Timeout, setup}]};
handle_event(enter, _OldState, State, Data) ->
    {next_state, State, Data};

handle_event({call, From}, stop, _, Data) ->
    {stop_and_reply, normal, [{reply, From, ok}], Data};

handle_event(_, setup, dead, #data{dp = #node{ip = IP}} = Data) ->
    Req0 = #pfcp{version = v1, type = association_setup_request, ie = []},
    Req = augment_mandatory_ie(Req0, Data),
    ergw_sx_socket:call(IP, ?AssocReqTimeout, ?AssocReqRetries, Req,
			response_cb(association_setup_request)),
    {next_state, connecting, Data};

handle_event({call, From}, _Evt, dead, _Data) ->
    lager:warning("Call from ~p, ~p failed with {error, dead}", [From, _Evt]),
    {keep_state_and_data, [{reply, From, {error, dead}}]};

handle_event(cast, {response, association_setup_request, timeout},
	     connecting, #data{retries = Retries, dp = #node{ip = IP}} = Data) ->
    lager:debug("~p:~s Timeout @ Retry: ~w", [self(), inet:ntoa(IP), Retries]),
    if Retries >= ?AssocRetries ->
	    {stop, normal};
       true ->
	    {next_state, dead, Data#data{retries = Retries + 1}}
    end;

handle_event(cast, {response, _, #pfcp{version = v1, type = association_setup_response, ie = IEs}},
	     connecting, Data0) ->
    case IEs of
	#{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} ->
	    Data = handle_nodeup(IEs, Data0),
	    {next_state, connected, Data, [next_heartbeat(Data)]};
	Other ->
	    lager:warning("Other: ~p", [lager:pr(Other, ?MODULE)]),
	    {next_state, dead, Data0}
    end;

handle_event(cast, {send, 'Access', _VRF, Data}, connected,
	     #data{pfcp_ctx = #pfcp_ctx{cp_port = Port},
		   dp = #node{ip = IP},
		   upf_data_endp = #gtp_endp{teid = TEI}}) ->

    Msg = #gtp{version = v1, type = g_pdu, tei = TEI, ie = Data},
    Bin = gtp_packet:encode(Msg),
    ergw_gtp_u_socket:send(Port, IP, ?GTP1u_PORT, Bin),

    keep_state_and_data;

%%
%% heartbeat logic
%%
handle_event(state_timeout, heartbeat, connected, Data) ->
    lager:warning("sending heartbeat"),
    send_heartbeat(Data),
    keep_state_and_data;

handle_event(cast, {heartbeat, timeout}, connected, Data) ->
    {next_state, dead, handle_nodedown(Data)};

handle_event(cast, {request, ReqKey,
		    #pfcp{type = heartbeat_request,
			  ie = #{recovery_time_stamp :=
				     #recovery_time_stamp{time = RecoveryTS}}} = Request},
	     _, #data{recovery_ts = StoredRecoveryTS} = Data0)
  when is_integer(StoredRecoveryTS) andalso RecoveryTS > StoredRecoveryTS ->
    heartbeat_response(ReqKey, Request),
    Data = Data0#data{recovery_ts = RecoveryTS},
    {next_state, dead, handle_nodedown(Data)};
handle_event(cast, {request, _,
		    #pfcp{type = heartbeat_request,
			  ie = #{recovery_time_stamp :=
				     #recovery_time_stamp{time = RecoveryTS}}}},
	     _, #data{recovery_ts = StoredRecoveryTS})
  when is_integer(StoredRecoveryTS) andalso RecoveryTS < StoredRecoveryTS ->
    keep_state_and_data;
handle_event(cast, {request, ReqKey,
		    #pfcp{type = heartbeat_request,
			  ie = #{recovery_time_stamp :=
				     #recovery_time_stamp{time = RecoveryTS}}} = Request},
	     State, #data{recovery_ts = StoredRecoveryTS} = Data)
  when not is_integer(StoredRecoveryTS) ->
    heartbeat_response(ReqKey, Request),
    {next_state, State, Data#data{recovery_ts = RecoveryTS}};
handle_event(cast, {request, ReqKey, #pfcp{type = heartbeat_request} = Request}, _, _) ->
    heartbeat_response(ReqKey, Request),
    keep_state_and_data;

handle_event(cast, {response, _, #pfcp{version = v1, type = heartbeat_response,
				       ie = #{recovery_time_stamp :=
						  #recovery_time_stamp{time = RecoveryTS}} = IEs}},
		    connected, #data{recovery_ts = RecoveryTS} = Data) ->
    lager:info("PFCP OK Response: ~p", [pfcp_packet:lager_pr(IEs)]),
    {next_state, connected, Data, [next_heartbeat(Data)]};
handle_event(cast, {response, _, #pfcp{version = v1, type = heartbeat_response, ie = _IEs}},
	     connected, Data) ->
    lager:warning("PFCP Fail Response: ~p", [pfcp_packet:lager_pr(_IEs)]),
    {next_state, dead, handle_nodedown(Data)};

handle_event(cast, {response, from_cp_rule,
		    #pfcp{version = v1, type = session_establishment_response,
			  ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
				 f_seid := #f_seid{seid = DP}}}} = R,
	     connected, #data{pfcp_ctx = #pfcp_ctx{seid = SEID} = PCtx} = Data) ->
    lager:warning("Response: ~p", [R]),
    {keep_state, Data#data{pfcp_ctx = PCtx#pfcp_ctx{seid = SEID#seid{dp = DP}}}};

handle_event({call, From}, attach, _, #data{pfcp_ctx = PNodeCtx}) ->
    PCtx = #pfcp_ctx{
	      name = PNodeCtx#pfcp_ctx.name,
	      node = PNodeCtx#pfcp_ctx.node,
	      seid = #seid{cp = ergw_sx_socket:seid()},

	      cp_port = PNodeCtx#pfcp_ctx.cp_port,
	      cp_tei = PNodeCtx#pfcp_ctx.cp_tei
	     },
    {keep_state_and_data, [{reply, From, PCtx}]};

handle_event({call, From}, get_vrfs, connected,
	     #data{vrfs = VRFs}) ->
    {keep_state_and_data, [{reply, From, {ok, VRFs}}]};

handle_event(cast, {response, {call, _} = Evt,
		    #pfcp{
		       ie = #{pfcp_cause :=
				  #pfcp_cause{cause = 'No established Sx Association'}}} =
			Reply}, _, Data) ->
    Actions = pfcp_reply_actions(Evt, Reply),
    {next_state, dead, handle_nodedown(Data), Actions};

handle_event(cast, {response, {call, _} = Evt, Reply}, _, _Data) ->
    Actions = pfcp_reply_actions(Evt, Reply),
    {keep_state_and_data, Actions};

handle_event(cast, {response, heartbeat, timeout} = R, _, Data) ->
    lager:warning("PFCP Timeout: ~p", [R]),
    {next_state, dead, handle_nodedown(Data)};

handle_event(cast, {response, _, _} = R, _, _Data) ->
    lager:warning("Response: ~p", [R]),
    keep_state_and_data;

handle_event({call, _} = Evt, #pfcp{} = Request0, connected,
	     #data{dp = #node{ip = IP}} = Data) ->
    Request = augment_mandatory_ie(Request0, Data),
    lager:debug("DP Call ~p", [lager:pr(Request, ?MODULE)]),
    ergw_sx_socket:call(IP, Request, response_cb(Evt)),
    keep_state_and_data;

handle_event({call, _}, Request, _, _Data)
  when is_record(Request, pfcp); Request == get_vrfs ->
    {keep_state_and_data, postpone};

handle_event(cast, {#pfcp{} = Request0, Cb}, connected,
	     #data{dp = #node{ip = IP}} = Data) ->
    Request = augment_mandatory_ie(Request0, Data),
    ergw_sx_socket:call(IP, Request, Cb),
    keep_state_and_data;
handle_event(cast, {#pfcp{}, Cb}, _, _Data) ->
    (catch Cb({error, dead})),
    keep_state_and_data;

handle_event(cast, {handle_pdu, _Request, #gtp{type=g_pdu, ie = PDU}}, _, Data) ->
    try
	handle_ip_pdu(PDU, Data)
    catch
	throw:{error, Error}:ST ->
	    lager:error("handler for GTP-U failed with: ~p @ ~p", [Error, ST]);
	Class:Error:ST ->
	    lager:error("handler for GTP-U failed with: ~p:~p @ ~p", [Class, Error, ST])
    end,
    keep_state_and_data;

handle_event({call, From}, {sx, Report}, _State,
	     #data{pfcp_ctx = #pfcp_ctx{seid = #seid{dp = SEID}}}) ->
    lager:error("Sx Node Session Report unexpected: ~p", [Report]),
    {keep_state_and_data, [{reply, From, {ok, SEID}}]}.

terminate(_Reason, _Data) ->
    ok.

code_change(_OldVsn, Data, _Extra) ->
    {ok, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

node_vrfs(Name, Nodes, Default) ->
    Layout = maps:get(Name, Nodes, #{}),
    maps:get(vrfs, Layout, Default).

node_vrfs(Name) ->
    {ok, Nodes} = setup:get_env(ergw, nodes),
    Default = node_vrfs(default, Nodes, #{}),
    node_vrfs(Name, Nodes, Default).

init_vrfs(Node) ->
    maps:map(
      fun(Id, #{features := Features}) ->
	      #vrf{name = Id, features = Features}
      end, node_vrfs(Node)).

pfcp_reply_actions({call, {Pid, Tag}}, Reply)
  when Pid =:= self() ->
    [{next_event, internal, {Tag, Reply}}];
pfcp_reply_actions({call, From}, Reply) ->
    [{reply, From, Reply}].

make_request(IP, Port, Msg, #data{pfcp_ctx = #pfcp_ctx{cp_port = GtpPort}}) ->
    ergw_gtp_socket:make_request(0, IP, Port, Msg, GtpPort).

%% IPv4, non fragmented, UDP packet
handle_ip_pdu(<<Version:4, IHL:4, _TOS:8, TotLen:16, _Id:16, _:2, 0:1, 0:13,
		_TTL:8, Proto:8, _HdrCSum:16,
		SrcIP:4/bytes, DstIP:4/bytes, _/binary>> = PDU, Data)
  when Version == 4, Proto == 17 ->
    HeaderLen = IHL * 4,
    UDPLen = TotLen - HeaderLen,
    <<_:HeaderLen/bytes, UDP:UDPLen/bytes, _/binary>> = PDU,
    lager:debug("IPv4 UDP: ~p", [UDP]),
    handle_udp_gtp(SrcIP, DstIP, UDP, Data);
%% IPv6, non fragmented, UDP packet
handle_ip_pdu(<<Version:4, _TC:8, _Label:20, PayloadLen:16, NextHeader:8, _TTL:8,
		SrcIP:16/bytes, DstIP:16/bytes, UDP:PayloadLen/bytes, _/binary>>, Data)
  when Version == 6, NextHeader == 17  ->
    lager:debug("IPv6 UDP: ~p", [UDP]),
    handle_udp_gtp(SrcIP, DstIP, UDP, Data);
handle_ip_pdu(PDU, _Data) ->
    lager:debug("unexpected GTP-U payload: ~p", [PDU]),
    ok.

handle_udp_gtp(SrcIP, DstIP, <<SrcPort:16, DstPort:16, _:16, _:16, PayLoad/binary>>,
	       #data{dp = #node{node = Node}} = Data)
  when DstPort =:= ?GTP1u_PORT ->
    Msg = gtp_packet:decode(PayLoad),
    lager:debug("GTP-U ~s:~w -> ~s:~w: ~p",
		[inet:ntoa(ergw_inet:bin2ip(SrcIP)), SrcPort,
		 inet:ntoa(ergw_inet:bin2ip(DstIP)), DstPort,
		 lager:pr(Msg, ?MODULE)]),
    ReqKey = make_request(SrcIP, SrcPort, Msg, Data),
    GtpPort = #gtp_port{name = Node, type = 'gtp-u'},
    TEID = #fq_teid{ip = ergw_inet:bin2ip(DstIP), teid = Msg#gtp.tei},
    ergw_context:port_message(gtp_context:port_teid_key(GtpPort, TEID), ReqKey, Msg, false),
    ok;
handle_udp_gtp(SrcIP, DstIP, <<SrcPort:16, DstPort:16, _:16, _:16, PayLoad/binary>>, _Data) ->
    lager:debug("unexpected UDP ~s:~w -> ~s:~w: ~p",
		[inet:ntoa(ergw_inet:bin2ip(SrcIP)), SrcPort,
		 inet:ntoa(ergw_inet:bin2ip(DstIP)), DstPort, PayLoad]),
    ok.

connect_sx_node([]) ->
    {error, not_found};
connect_sx_node([{Node, _, _, IP4, IP6}|Next]) ->
    case connect_sx_node(Node, IP4, IP6) of
	{ok, _Pid} = Result ->
	    Result;
	_ ->
	    connect_sx_node(Next)
    end.

connect_sx_node(Node, IP4, IP6) ->
    case ergw_sx_node_reg:lookup(Node) of
	{ok, _} = Result ->
	    Result;
	_ ->
	    ergw_sx_node_sup:new(Node, IP4, IP6)
    end.

response_cb(CbData) ->
    {?MODULE, response, [self(), CbData]}.

seconds_to_sntp_time(Sec) ->
    if Sec >= 2085978496 ->
	    Sec - 2085978496;
       true ->
	    Sec + 2208988800
    end.

next_heartbeat(_Data) ->
    {state_timeout, 5000, heartbeat}.

put_ie(IE, IEs) when is_map(IEs) ->
    maps:put(element(1, IE), IE, IEs);
put_ie(IE, IEs) when is_list(IEs) ->
    [IE | IEs];
put_ie(IE, _IEs) ->
    [IE].

put_node_id(R = #pfcp{ie = IEs}, #data{cp = #node{node = Node}}) ->
    NodeId = #node_id{id = string:split(atom_to_binary(Node, utf8), ".", all)},
    R#pfcp{ie = put_ie(NodeId, IEs)}.

put_recovery_time_stamp(R = #pfcp{ie = IEs}) ->
    TS = #recovery_time_stamp{
	    time = seconds_to_sntp_time(gtp_config:get_start_time())},
    R#pfcp{ie = put_ie(TS, IEs)}.

augment_mandatory_ie(R = #pfcp{type = Type}, _Data)
  when Type == heartbeat_request orelse
       Type == heartbeat_response ->
    put_recovery_time_stamp(R);
augment_mandatory_ie(R = #pfcp{type = Type}, Data)
  when Type == association_update_request orelse
       Type == association_update_response orelse
       Type == association_release_request orelse
       Type == association_release_response orelse
       Type == node_report_request orelse
       Type == node_report_response orelse
       Type == session_set_deletion_request orelse
       Type == session_set_deletion_response orelse
       Type == session_establishment_request orelse
       Type == session_establishment_response ->
    put_node_id(R, Data);
augment_mandatory_ie(R = #pfcp{type = Type}, Data)
  when Type == association_setup_request orelse
       Type == association_setup_response ->
    put_recovery_time_stamp(put_node_id(R, Data));
augment_mandatory_ie(Request, _Data) ->
    Request.

make_response(Type, #pfcp_ctx{seid = #seid{dp = SEID}}, Request, IEs) ->
    make_response(Type, SEID, Request, IEs);
make_response(Type, SEID, #pfcp{version = v1, seq_no = SeqNo}, IEs) ->
    #pfcp{version = v1, type = Type, seid = SEID, seq_no = SeqNo, ie = IEs}.


send_heartbeat(#data{dp = #node{ip = IP}}) ->
    IEs = [#recovery_time_stamp{
	      time = seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = heartbeat_request, ie = IEs},
    ergw_sx_socket:call(IP, 500, 5, Req, response_cb(heartbeat)).

heartbeat_response(ReqKey, #pfcp{type = heartbeat_request} = Request) ->
    Response = put_recovery_time_stamp(
		 make_response(heartbeat_response, undefined, Request, [])),
    ergw_sx_socket:send_response(ReqKey, Response, true).

handle_nodeup(#{recovery_time_stamp := #recovery_time_stamp{time = RecoveryTS}} = IEs,
	      #data{dp = #node{node = Node, ip = IP},
		    vrfs = VRFs} = Data0) ->
    lager:warning("Node ~s (~s) is up", [Node, inet:ntoa(IP)]),
    lager:warning("Node IEs: ~p", [pfcp_packet:lager_pr(IEs)]),

    UPIPResInfo = maps:get(user_plane_ip_resource_information, IEs, []),
    Data = Data0#data{
	     recovery_ts = RecoveryTS,
	     vrfs = init_vrfs(VRFs, UPIPResInfo)
	    },
    install_cp_rules(Data).

init_vrfs(VRFs, UPIPResInfo)
  when is_list(UPIPResInfo) ->
    lists:foldl(fun(I, Acc) ->
			init_vrfs(Acc, I)
		end, VRFs, UPIPResInfo);
init_vrfs(VRFs,
	  #user_plane_ip_resource_information{
	     network_instance = NetworkInstance,
	     teid_range = Range, ipv4 = IP4, ipv6 = IP6}) ->
    Name = vrf:normalize_name(NetworkInstance),
    case VRFs of
	#{Name := VRF0} ->
	    VRF = VRF0#vrf{teid_range = Range, ipv4 = IP4, ipv6 = IP6},
	    VRFs#{Name => VRF};
	_ ->
	    lager:warning("UP Nodes reported unknown Network Instance '~p'", [Name]),
	    VRFs
    end.

handle_nodedown(#data{dp = #node{node = Node}} = Data) ->
    Self = self(),
    {monitored_by, Notify} = process_info(Self, monitored_by),
    lager:info("Node Down Monitor Notify: ~p", [Notify]),
    lists:foreach(fun(Pid) -> Pid ! {'DOWN', undefined, pfcp, Self, undefined} end, Notify),
    Data#data{vrfs = init_vrfs(Node)}.

%%%===================================================================
%%% CP to Access Interface forwarding
%%%===================================================================

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

%% use additional information from the Context to prefre V4 or V6....
choose_up_ip(#node{ip = {_,_,_,_}}, #vrf{ipv4 = IP4})
  when is_binary(IP4) ->
    ergw_inet:bin2ip(IP4);
choose_up_ip(#node{ip = {_,_,_,_,_,_,_,_}}, #vrf{ipv4 = IP6})
  when is_binary(IP6) ->
    ergw_inet:bin2ip(IP6);
choose_up_ip(#node{ip = IP}, _VRF) ->
    IP.

create_data_endp(PCtx, Node, VRFs) ->
    [VRF|_] =
	lists:filter(fun(#vrf{features = Features}) ->
			     lists:member('CP-Function', Features)
		     end, maps:values(VRFs)),
    {ok, DataTEI} = gtp_context_reg:alloc_tei(PCtx),
    #gtp_endp{
       vrf = VRF#vrf.name,
       ip = choose_up_ip(Node, VRF),
       teid = DataTEI}.

gen_pfcp_rules(_Key, #vrf{features = Features} = VRF, DataEndP, Acc) ->
    lists:foldl(gen_per_feature_pfcp_rule(_, VRF, DataEndP, _), Acc, Features).

gen_per_feature_pfcp_rule('Access', #vrf{name = Name} = VRF,
			  DataEndP, PCtx0) ->
    Key = {Name, 'Access'},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, Key, PCtx0),
    {FarId, PCtx} = ergw_pfcp:get_id(far, Key, PCtx1),

    %% GTP-U encapsulated packet from CP
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'CP-function'},
		  ergw_pfcp:network_instance(DataEndP),
		  ergw_pfcp:f_teid(DataEndP)]
	    },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = 100},
	   PDI,
	   ergw_pfcp:outer_header_removal(DataEndP),
	   #far_id{id = FarId}],
    %% forward to Access intefaces
    FAR = [#far_id{id = FarId},
	   #apply_action{forw = 1},
	   #forwarding_parameters{
	      group =
		  [#destination_interface{interface = 'Access'},
		   ergw_pfcp:network_instance(VRF)]
	     }
	  ],

    ergw_pfcp:pfcp_rules_add(
      [{pdr, PdrId, PDR},
       {far, FarId, FAR}], PCtx);
gen_per_feature_pfcp_rule(_, _VRF, _DpGtpIP, Acc) ->
    Acc.

install_cp_rules(#data{pfcp_ctx = PCtx0,
		       cp = CntlNode,
		       dp = #node{ip = DpNodeIP} = DpNode,
		       vrfs = VRFs} = Data) ->
    DataEndP = create_data_endp(PCtx0, DpNode, VRFs),

    PCtx1 = ergw_pfcp:init_ctx(PCtx0),
    PCtx = maps:fold(gen_pfcp_rules(_, _, DataEndP, _), PCtx1, VRFs),
    Rules = ergw_pfcp:update_pfcp_rules(PCtx1, PCtx, #{}),
    IEs = update_m_rec(ergw_pfcp:f_seid(PCtx, CntlNode), Rules),

    Req0 = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    Req = augment_mandatory_ie(Req0, Data),
    ergw_sx_socket:call(DpNodeIP, Req, response_cb(from_cp_rule)),

    Data#data{pfcp_ctx = PCtx, upf_data_endp = DataEndP}.

%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012, Erlang Solutions Ltd.
%%% @doc OpenFlow Protocol version 1.0 implementation.
%%% @end
%%%-----------------------------------------------------------------------------
-module(ofp_v1).

-behaviour(gen_protocol).

%% gen_protocol callbacks
-export([encode/1, decode/1]).

-include("of_protocol.hrl").
-include("ofp_v1.hrl").

%%%-----------------------------------------------------------------------------
%%% gen_protocol callbacks
%%%-----------------------------------------------------------------------------

%% @doc Encode erlang representation to binary.
-spec encode(Message :: ofp_message()) -> {ok, binary()} |
                                          {error, any()}.
encode(Message) ->
    try
        {ok, do_encode(Message)}
    catch
        _:Exception ->
            {error, Exception}
    end.

%% @doc Decode binary to erlang representation.
-spec decode(Binary :: binary()) -> {ok, ofp_message()} |
                                    {error, any()}.
decode(Binary) ->
    try
        {ok, do_decode(Binary)}
    catch
        _:Exception ->
            {error, Exception}
    end.

%%%-----------------------------------------------------------------------------
%%% Encode functions
%%%-----------------------------------------------------------------------------

%% @doc Actual encoding of the message.
do_encode(#ofp_message{experimental = Experimental,
                       version = Version,
                       xid = Xid,
                       body = Body}) ->
    ExperimentalInt = ofp_utils:int_to_bool(Experimental),
    BodyBin = encode_body(Body),
    TypeInt = type_int(Body),
    Length = ?OFP_HEADER_SIZE + size(BodyBin),
    <<ExperimentalInt:1, Version:7, TypeInt:8,
      Length:16, Xid:32, BodyBin/bytes>>.

%%% Structures -----------------------------------------------------------------

%% @doc Encode other structures
encode_struct(#ofp_port{port_no = PortNo, hw_addr = HWAddr, name = Name,
                        config = Config, state = State, curr = Curr,
                        advertised = Advertised, supported = Supported,
                        peer = Peer}) ->
    PortNoInt = ofp_v1_map:encode_port_no(PortNo),
    NameBin = ofp_utils:encode_string(Name, ?OFP_MAX_PORT_NAME_LEN),
    ConfigBin = flags_to_binary(port_config, Config, 4),
    StateBin = flags_to_binary(port_state, State, 4),
    CurrBin = flags_to_binary(port_feature, Curr, 4),
    AdvertisedBin = flags_to_binary(port_feature, Advertised, 4),
    SupportedBin = flags_to_binary(port_feature, Supported, 4),
    PeerBin = flags_to_binary(port_feature, Peer, 4),
    <<PortNoInt:16, HWAddr:?OFP_ETH_ALEN/bytes,
      NameBin:?OFP_MAX_PORT_NAME_LEN/bytes,
      ConfigBin:4/bytes, StateBin:4/bytes, CurrBin:4/bytes,
      AdvertisedBin:4/bytes, SupportedBin:4/bytes, PeerBin:4/bytes>>;

encode_struct(#ofp_packet_queue{queue_id = Queue, properties = Props}) ->
    PropsBin = encode_list(Props),
    Length = ?PACKET_QUEUE_SIZE + size(PropsBin),
    <<Queue:32, Length:16, 0:16, PropsBin/bytes>>;
encode_struct(#ofp_queue_prop_min_rate{rate = Rate}) ->
    PropertyInt = ofp_v1_map:queue_property(min_rate),
    <<PropertyInt:16, ?QUEUE_PROP_MIN_RATE_SIZE:16, 0:32, Rate:16, 0:48>>;

encode_struct(#ofp_match{oxm_fields = Fields}) ->
    FieldList = encode_fields(Fields),
    InPort = encode_field_value(FieldList, in_port, 16),
    EthSrc = encode_field_value(FieldList, eth_src, 48),
    EthDst = encode_field_value(FieldList, eth_dst, 48),
    VlanVid = encode_field_value(FieldList, vlan_vid, 16),
    VlanPcp = encode_field_value(FieldList, vlan_pcp, 8),
    EthType = encode_field_value(FieldList, eth_type, 16),
    IPDscp = encode_field_value(FieldList, ip_dscp, 8),
    IPProto = encode_field_value(FieldList, ip_proto, 8),
    IPv4Src = encode_field_value(FieldList, ipv4_src, 32),
    IPv4Dst = encode_field_value(FieldList, ipv4_dst, 32),
    case IPProto of
        <<6>> ->
            TPSrc = encode_field_value(FieldList, tcp_src, 16),
            TPDst = encode_field_value(FieldList, tcp_dst, 16);
        <<17>> ->
            TPSrc = encode_field_value(FieldList, udp_src, 16),
            TPDst = encode_field_value(FieldList, udp_dst, 16);
        _ ->
            TPSrc = <<0:16>>,
            TPDst = <<0:16>>
    end,
    SrcMask = case lists:keyfind(ipv4_src, #ofp_field.field, Fields) of
                  #ofp_field{has_mask = true, mask = SMask} ->
                      count_zeros4(SMask);
                  _ ->
                      0
              end,
    DstMask = case lists:keyfind(ipv4_dst, #ofp_field.field, Fields) of
                  #ofp_field{has_mask = true, mask = DMask} ->
                      count_zeros4(DMask);
                  _ ->
                      0
              end,
    {Wildcards, _} = lists:unzip(FieldList),
    <<WildcardsInt:32>> = flags_to_binary(flow_wildcard,
                                          Wildcards -- [ipv4_src, ipv4_dst], 4),
    WildcardsBin = <<(WildcardsInt bor (SrcMask bsl 8)
                          bor (DstMask bsl 14)):32>>,
    <<WildcardsBin:4/bytes, InPort:2/bytes, EthSrc:6/bytes, EthDst:6/bytes,
      VlanVid:2/bytes, VlanPcp:1/bytes, 0:8, EthType:2/bytes, IPDscp:1/bytes,
      IPProto:1/bytes, 0:16, IPv4Src:4/bytes, IPv4Dst:4/bytes, TPSrc:2/bytes,
      TPDst:2/bytes>>.

%% FIXME: Add a separate case when encoding port_no
encode_field_value(FieldList, Type, Size) ->
    case lists:keyfind(Type, 1, FieldList) of
        false ->
            <<0:Size>>;
        {_, Value} ->
            <<Value:Size/bits>>
    end.

encode_fields(Fields) ->
    encode_fields(Fields, []).

encode_fields([], FieldList) ->
    FieldList;
encode_fields([#ofp_field{field = Type, value = Value} | Rest], FieldList) ->
    encode_fields(Rest, [{Type, Value} | FieldList]).

%%% Messages -----------------------------------------------------------------

encode_body(#ofp_desc_stats_reply{flags = Flags, mfr_desc = MFR,
                                  hw_desc = HW, sw_desc = SW,
                                  serial_num = Serial, dp_desc = DP}) ->
    TypeInt = ofp_v3_map:stats_type(desc),
    FlagsBin = flags_to_binary(stats_reply_flag, Flags, 2),
    MFRPad = (?DESC_STR_LEN - size(MFR)) * 8,
    HWPad = (?DESC_STR_LEN - size(HW)) * 8,
    SWPad = (?DESC_STR_LEN - size(SW)) * 8,
    SerialPad = (?SERIAL_NUM_LEN - size(Serial)) * 8,
    DPPad = (?DESC_STR_LEN - size(DP)) * 8,
    <<TypeInt:16, FlagsBin/bytes,
      MFR/bytes, 0:MFRPad, HW/bytes, 0:HWPad,
      SW/bytes, 0:SWPad, Serial/bytes, 0:SerialPad,
      DP/bytes, 0:DPPad>>;
encode_body(_) ->
    <<>>.

%%%-----------------------------------------------------------------------------
%%% Decode functions
%%%-----------------------------------------------------------------------------

%% @doc Actual decoding of the message.
-spec do_decode(Binary :: binary()) -> ofp_message().
do_decode(Binary) ->
    <<ExperimentalInt:1, Version:7, TypeInt:8, _:16,
      XID:32, BodyBin/bytes >> = Binary,
    Experimental = (ExperimentalInt =:= 1),
    Type = ofp_v1_map:msg_type(TypeInt),
    Body = decode_body(Type, BodyBin),
    #ofp_message{experimental = Experimental, version = Version,
                 xid = XID, body = Body}.

%%% Structures -----------------------------------------------------------------

%% @doc Decode port structure.
decode_port(Binary) ->
    <<PortNoInt:32, 0:32, HWAddr:6/bytes, 0:16, NameBin:16/bytes,
      ConfigBin:4/bytes, StateBin:4/bytes, CurrBin:4/bytes,
      AdvertisedBin:4/bytes, SupportedBin:4/bytes, PeerBin:4/bytes,
      CurrSpeed:32, MaxSpeed:32>> = Binary,
    PortNo = ofp_v1_map:decode_port_no(PortNoInt),
    Name = ofp_utils:strip_string(NameBin),
    Config = binary_to_flags(port_config, ConfigBin),
    State = binary_to_flags(port_state, StateBin),
    Curr = binary_to_flags(port_feature, CurrBin),
    Advertised = binary_to_flags(port_feature, AdvertisedBin),
    Supported = binary_to_flags(port_feature, SupportedBin),
    Peer = binary_to_flags(port_feature, PeerBin),
    #ofp_port{port_no = PortNo, hw_addr = HWAddr, name = Name,
              config = Config, state = State, curr = Curr,
              advertised = Advertised, supported = Supported,
              peer = Peer, curr_speed = CurrSpeed, max_speed = MaxSpeed}.

%% @doc Decode packet queues
decode_packet_queues(Binary) ->
    decode_packet_queues(Binary, []).

decode_packet_queues(<<>>, Queues) ->
    lists:reverse(Queues);
decode_packet_queues(Binary, Queues) ->
    <<QueueId:32, Length:16, 0:16, Data/bytes>> = Binary,
    PropsLength = Length - ?PACKET_QUEUE_SIZE,
    <<PropsBin:PropsLength/bytes, Rest/bytes>> = Data,
    Props = decode_queue_properties(PropsBin),
    Queue = #ofp_packet_queue{queue_id = QueueId, properties = Props},
    decode_packet_queues(Rest, [Queue | Queues]).

%% @doc Decode queue properties
decode_queue_properties(Binary) ->
    decode_queue_properties(Binary, []).

decode_queue_properties(<<>>, Properties) ->
    lists:reverse(Properties);
decode_queue_properties(Binary, Properties) ->
    <<TypeInt:16, _Length:16, 0:32, Data/bytes>> = Binary,
    Type = ofp_v2_map:queue_property(TypeInt),
    case Type of
        min_rate ->
            <<Rate:16, 0:48, Rest/bytes>> = Data,
            Property = #ofp_queue_prop_min_rate{rate = Rate}
    end,
    decode_queue_properties(Rest, [Property | Properties]).

decode_match(Binary) ->
    <<WildcardsInt:32, InPort:2/bytes, EthSrc:6/bytes, EthDst:6/bytes,
      VlanVid:2/bytes, VlanPcp:1/bytes, 0:8, EthType:2/bytes, IPDscp:1/bytes,
      IPProto:1/bytes, 0:16, IPv4Src:4/bytes, IPv4Dst:4/bytes,
      TPSrc:2/bytes, TPDst:2/bytes>> = Binary,
    Wildcards = binary_to_flags(flow_wildcard,
                                <<(WildcardsInt band 16#fff0003f):32>>),
    case lists:member(ip_proto, Wildcards) of
        false ->
            Wildcards2 = Wildcards;
        true ->
            <<TPDstBit:1, TPSrcBit:1, _:6>> = <<WildcardsInt:8>>,
            case TPSrcBit of
                0 ->
                    WildcardsTmp = Wildcards;
                1 ->
                    AddTmp = case IPProto of
                                 <<6>> -> [tcp_src];
                                 <<17>> -> [udp_src];
                                 _ -> []
                             end,
                    WildcardsTmp = Wildcards ++ AddTmp
            end,
            case TPDstBit of
                0 ->
                    Wildcards2 = WildcardsTmp;
                1 ->
                    Add2 = case IPProto of
                               <<6>> -> [tcp_dst];
                               <<17>> -> [udp_dst];
                               _ -> []
                           end,
                    Wildcards2 = WildcardsTmp ++ Add2
            end
    end,
    Fields = [begin
                  F = #ofp_field{field = Type},
                  case Type of
                      in_port ->
                          F#ofp_field{value = InPort};
                      eth_src ->
                          F#ofp_field{value = EthSrc};
                      eth_dst ->
                          F#ofp_field{value = EthDst};
                      vlan_vid ->
                          F#ofp_field{value = VlanVid};
                      vlan_pcp ->
                          F#ofp_field{value = VlanPcp};
                      eth_type ->
                          F#ofp_field{value = EthType};
                      ip_dscp ->
                          F#ofp_field{value = IPDscp};
                      ip_proto ->
                          F#ofp_field{value = IPProto};
                      ipv4_src ->
                          <<_:18, SrcMask:6, _:8>> = <<WildcardsInt:32>>,
                          F#ofp_field{value = IPv4Src,
                                      has_mask = true,
                                      mask = convert_to_mask(SrcMask)};
                      ipv4_dst ->
                          <<_:12, DstMask:6, _:14>> = <<WildcardsInt:32>>,
                          F#ofp_field{value = IPv4Dst,
                                      has_mask = true,
                                      mask = convert_to_mask(DstMask)};
                      tcp_src ->
                          F#ofp_field{value = TPSrc};
                      tcp_dst ->
                          F#ofp_field{value = TPDst};
                      udp_src ->
                          F#ofp_field{value = TPSrc};
                      udp_dst ->
                          F#ofp_field{value = TPDst}
                  end
              end || Type <- Wildcards2 ++ [ipv4_src, ipv4_dst]],
    #ofp_match{type = standard, oxm_fields = Fields}.

%%% Messages -----------------------------------------------------------------

decode_body(stats_request, Binary) ->
    <<TypeInt:16, FlagsBin:2/bytes,
      Data/bytes>> = Binary,
    Type = ofp_v1_map:stats_type(TypeInt),
    Flags = binary_to_flags(stats_request_flag, FlagsBin),
    case Type of
        desc ->
            #ofp_desc_stats_request{flags = Flags};
        _ ->
            undefined
    end;
decode_body(_, _) ->
    undefined.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

-spec encode_list(list()) -> binary().
encode_list(List) ->
    encode_list(List, <<>>).

-spec encode_list(list(), binary()) -> binary().
encode_list([], Binaries) ->
    Binaries;
encode_list([Struct | Rest], Binaries) ->
    StructBin = encode_struct(Struct),
    encode_list(Rest, <<Binaries/bytes, StructBin/bytes>>).

-spec flags_to_binary(atom(), [atom()], integer()) -> binary().
flags_to_binary(Type, Flags, Size) ->
    flags_to_binary(Type, Flags, <<0:(Size*8)>>, Size*8).

-spec flags_to_binary(atom(), [atom()], binary(), integer()) -> binary().
flags_to_binary(_, [], Binary, _) ->
    Binary;
flags_to_binary(Type, [Flag | Rest], Binary, BitSize) ->
    <<Binary2:BitSize>> = Binary,
    %% case Flag of
    %%     experimenter ->
    %%         Bit = ofp_v1_map:get_experimenter_bit(Type);
    %%     _ ->
            Bit = ofp_v1_map:Type(Flag),
    %% end,
    NewBinary = (Binary2 bor (1 bsl Bit)),
    flags_to_binary(Type, Rest, <<NewBinary:BitSize>>, BitSize).

-spec binary_to_flags(atom(), binary()) -> [atom()].
binary_to_flags(Type, Binary) ->
    BitSize = size(Binary) * 8,
    <<Integer:BitSize>> = Binary,
    binary_to_flags(Type, Integer, BitSize-1, []).

-spec binary_to_flags(atom(), integer(), integer(), [atom()]) -> [atom()].
binary_to_flags(Type, Integer, Bit, Flags) when Bit >= 0 ->
    case 0 /= (Integer band (1 bsl Bit)) of
        true ->
            Flag = ofp_v1_map:Type(Bit),
            binary_to_flags(Type, Integer, Bit - 1, [Flag | Flags]);
        false ->
            binary_to_flags(Type, Integer, Bit - 1, Flags)
    end;
binary_to_flags(_, _, _, Flags) ->
    lists:reverse(Flags).

-spec convert_to_mask(integer()) -> binary().
convert_to_mask(N) when N < 32 ->
    <<(16#ffffffff - ((1 bsl N) -1)):32>>;
convert_to_mask(_) ->
    <<(16#0):32>>.

-spec count_zeros4(binary()) -> integer().
count_zeros4(<<X,0,0,0>>) -> 24 + count_zeros1(X);
count_zeros4(<<_,X,0,0>>) -> 16 + count_zeros1(X);
count_zeros4(<<_,_,X,0>>) -> 8 + count_zeros1(X);
count_zeros4(<<_,_,_,X>>) -> count_zeros1(X).

-spec count_zeros1(binary()) -> integer().
count_zeros1(X) when X band 2#11111111 == 0 -> 8;
count_zeros1(X) when X band 2#01111111 == 0 -> 7;
count_zeros1(X) when X band 2#00111111 == 0 -> 6;
count_zeros1(X) when X band 2#00011111 == 0 -> 5;
count_zeros1(X) when X band 2#00001111 == 0 -> 4;
count_zeros1(X) when X band 2#00000111 == 0 -> 3;
count_zeros1(X) when X band 2#00000011 == 0 -> 2;
count_zeros1(X) when X band 2#00000001 == 0 -> 1;
count_zeros1(_) -> 0.

-spec type_int(ofp_message_body()) -> integer().
type_int(#ofp_hello{}) ->
    ofp_v1_map:msg_type(hello);
type_int(#ofp_error{}) ->
    ofp_v1_map:msg_type(error);
type_int(#ofp_error_experimenter{}) ->
    ofp_v1_map:msg_type(error);
type_int(#ofp_echo_request{}) ->
    ofp_v1_map:msg_type(echo_request);
type_int(#ofp_echo_reply{}) ->
    ofp_v1_map:msg_type(echo_reply);
type_int(#ofp_experimenter{}) ->
    ofp_v1_map:msg_type(experimenter);
type_int(#ofp_features_request{}) ->
    ofp_v1_map:msg_type(features_request);
type_int(#ofp_features_reply{}) ->
    ofp_v1_map:msg_type(features_reply);
type_int(#ofp_get_config_request{}) ->
    ofp_v1_map:msg_type(get_config_request);
type_int(#ofp_get_config_reply{}) ->
    ofp_v1_map:msg_type(get_config_reply);
type_int(#ofp_set_config{}) ->
    ofp_v1_map:msg_type(set_config);
type_int(#ofp_packet_in{}) ->
    ofp_v1_map:msg_type(packet_in);
type_int(#ofp_flow_removed{}) ->
    ofp_v1_map:msg_type(flow_removed);
type_int(#ofp_port_status{}) ->
    ofp_v1_map:msg_type(port_status);
type_int(#ofp_queue_get_config_request{}) ->
    ofp_v1_map:msg_type(queue_get_config_request);
type_int(#ofp_queue_get_config_reply{}) ->
    ofp_v1_map:msg_type(queue_get_config_reply);
type_int(#ofp_packet_out{}) ->
    ofp_v1_map:msg_type(packet_out);
type_int(#ofp_flow_mod{}) ->
    ofp_v1_map:msg_type(flow_mod);
type_int(#ofp_port_mod{}) ->
    ofp_v1_map:msg_type(port_mod);
type_int(#ofp_desc_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_desc_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_flow_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_flow_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_aggregate_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_aggregate_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_table_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_table_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_port_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_port_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_queue_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_queue_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_group_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_group_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_group_desc_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_group_desc_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_group_features_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_group_features_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_experimenter_stats_request{}) ->
    ofp_v1_map:msg_type(stats_request);
type_int(#ofp_experimenter_stats_reply{}) ->
    ofp_v1_map:msg_type(stats_reply);
type_int(#ofp_barrier_request{}) ->
    ofp_v1_map:msg_type(barrier_request);
type_int(#ofp_barrier_reply{}) ->
    ofp_v1_map:msg_type(barrier_reply).

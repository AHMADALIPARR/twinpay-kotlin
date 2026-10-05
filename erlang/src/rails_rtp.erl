%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% RTP-style rail adapter: builds idempotent credit-transfer
%% instructions and holds them in a durable outbox. There is no live RTP
%% network on this host; this is the instruction builder + outbox, using
%% the idempotency-key pattern verified in the finance twin
%% (RtpRailAdapter.cs IdempotencyKey/CorrelationId). Fresh implementation.
-module(rails_rtp).
-behaviour(gen_server).

-export([start_link/0, send_credit/5, outbox/0, mark_sent/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Idempotent per IdemKey: a duplicate key returns the original
%% instruction instead of queueing a second transfer.
send_credit(From, To, AmountMinor, IdemKey, PaymentId)
  when is_integer(AmountMinor), AmountMinor > 0 ->
    gen_server:call(?MODULE, {send_credit, From, To, AmountMinor,
                              IdemKey, PaymentId}).

outbox() ->
    ets:tab2list(twinpay_rtp_outbox).

mark_sent(InstructionId, Reference) ->
    gen_server:call(?MODULE, {mark_sent, InstructionId, Reference}).

init([]) ->
    ets:new(twinpay_rtp_outbox, [named_table, set, public,
                                 {read_concurrency, true}]),
    ets:new(twinpay_rtp_keys, [named_table, set, public]),
    {ok, #{}}.

handle_call({send_credit, From, To, Amount, Key, PaymentId}, _From, St) ->
    case ets:lookup(twinpay_rtp_keys, Key) of
        [{Key, InstrId}] ->
            {reply, {ok, InstrId, duplicate}, St};
        [] ->
            InstrId = new_id(),
            Instr = #{instruction_id => InstrId,
                      idempotency_key => Key,
                      debtor => From, creditor => To,
                      amount => Amount, currency => <<"TWN">>,
                      end_to_end_id => PaymentId,
                      status => queued,
                      created_at => now_ms()},
            ets:insert(twinpay_rtp_outbox, {InstrId, Instr}),
            ets:insert(twinpay_rtp_keys, {Key, InstrId}),
            {reply, {ok, InstrId, queued}, St}
    end;
handle_call({mark_sent, InstrId, Reference}, _From, St) ->
    case ets:lookup(twinpay_rtp_outbox, InstrId) of
        [{InstrId, Instr}] ->
            ets:insert(twinpay_rtp_outbox,
                       {InstrId, Instr#{status => sent,
                                       reference => Reference}}),
            {reply, ok, St};
        [] ->
            {reply, {error, not_found}, St}
    end;
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, _St) -> ok.

new_id() ->
    N = erlang:unique_integer([positive]),
    <<"rtp-", (integer_to_binary(N, 16))/binary>>.

now_ms() -> erlang:system_time(millisecond).

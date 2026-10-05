%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Idempotency keys. A key is claimed before any side effect; a duplicate
%% claim returns the original payment instead of re-executing.
%% Pattern verified in the finance twin: RtpRailAdapter.cs IdempotencyKey,
%% COBILT-ACH-TREASURY IDEMPOTENCY-CHECK. Fresh implementation.
-module(idempotency).
-behaviour(gen_server).

-export([start_link/0, claim/1, fulfill/3, lookup/1, reclaim/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% -> {ok, fresh} | {ok, {duplicate, PaymentId, Status}}
claim(Key) when is_binary(Key) ->
    gen_server:call(?MODULE, {claim, Key}).

fulfill(Key, PaymentId, Status) ->
    gen_server:call(?MODULE, {fulfill, Key, PaymentId, Status}).

%% Release a key whose payment failed, so a retry with the same key
%% starts fresh instead of replaying the stale failure.
reclaim(Key) ->
    gen_server:call(?MODULE, {reclaim, Key}).

lookup(Key) ->
    case ets:lookup(twinpay_idem, Key) of
        [{Key, PaymentId, Status}] -> {ok, {PaymentId, Status}};
        [] -> {error, not_found}
    end.

init([]) ->
    ets:new(twinpay_idem, [named_table, set, public,
                           {read_concurrency, true}]),
    {ok, #{}}.

handle_call({claim, Key}, _From, St) ->
    case ets:lookup(twinpay_idem, Key) of
        [] ->
            ets:insert(twinpay_idem, {Key, undefined, claimed}),
            {reply, {ok, fresh}, St};
        [{Key, PaymentId, Status}] ->
            {reply, {ok, {duplicate, PaymentId, Status}}, St}
    end;
handle_call({fulfill, Key, PaymentId, Status}, _From, St) ->
    ets:insert(twinpay_idem, {Key, PaymentId, Status}),
    {reply, ok, St};
handle_call({reclaim, Key}, _From, St) ->
    ets:delete(twinpay_idem, Key),
    {reply, ok, St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, _St) -> ok.

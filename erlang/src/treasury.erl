%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Token treasury: the app gifts (mints) business tokens to agents.
%% Minting is issuance, never a transfer: it is an explicitly authorized,
%% WORM-anchored supply event. Burning destroys tokens symmetrically.
%% Only actors in the authorized_issuers list may mint or burn.
-module(treasury).
-behaviour(gen_server).

-export([start_link/0, gift/4, burn/4, redeem_burn/3, supply/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gift(AgentId, AmountMinor, Reason, Issuer)
gift(AgentId, Amount, Reason, Issuer)
  when is_integer(Amount), Amount > 0 ->
    gen_server:call(?MODULE, {gift, AgentId, Amount, Reason, Issuer}).

burn(AgentId, Amount, Reason, Issuer)
  when is_integer(Amount), Amount > 0 ->
    gen_server:call(?MODULE, {burn, AgentId, Amount, Reason, Issuer}).

%% Owner-initiated burn of the agent's own tokens (e.g. fiat off-ramp
%% redemption). No issuer authorization needed: the ledger enforces that
%% the agent holds the balance.
redeem_burn(AgentId, Amount, Reason)
  when is_integer(Amount), Amount > 0 ->
    gen_server:call(?MODULE, {redeem_burn, AgentId, Amount, Reason}).

supply() ->
    ets:update_counter(twinpay_supply, supply, 0).

init([]) ->
    ets:new(twinpay_supply, [named_table, set, public]),
    ets:insert(twinpay_supply, {supply, 0}),
    {ok, #{}}.

handle_call({gift, AgentId, Amount, Reason, Issuer}, _From, St) ->
    case authorized(Issuer) of
        false -> {reply, {error, unauthorized}, St};
        true ->
            PostId = new_id(<<"gift-">>),
            case ledger:post_issuance(PostId, AgentId, Amount) of
                {ok, already_posted} ->
                    {reply, {error, duplicate}, St};
                {ok, Seq} ->
                    ets:update_counter(twinpay_supply, supply, Amount),
                    WRes = worm:commit_entry(PostId, <<"treasury">>, AgentId,
                                            Amount, $I, Seq),
                    payments:record(#{id => PostId, kind => gift,
                                      from => <<"treasury">>, to => AgentId,
                                      amount => Amount, memo => Reason,
                                      status => settled, worm => WRes}),
                    {reply, {ok, PostId, WRes}, St}
            end
    end;
handle_call({burn, AgentId, Amount, Reason, Issuer}, _From, St) ->
    case authorized(Issuer) of
        false -> {reply, {error, unauthorized}, St};
        true ->
            {reply, do_burn(AgentId, Amount, Reason), St}
    end;
handle_call({redeem_burn, AgentId, Amount, Reason}, _From, St) ->
    {reply, do_burn(AgentId, Amount, Reason), St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, _St) -> ok.

do_burn(AgentId, Amount, Reason) ->
    PostId = new_id(<<"burn-">>),
    case ledger:post_burn(PostId, AgentId, Amount) of
        {ok, already_posted} ->
            {error, duplicate};
        {ok, Seq} ->
            ets:update_counter(twinpay_supply, supply, -Amount),
            WRes = worm:commit_entry(PostId, AgentId, <<"treasury">>,
                                    Amount, $B, Seq),
            payments:record(#{id => PostId, kind => burn,
                              from => AgentId, to => <<"treasury">>,
                              amount => Amount, memo => Reason,
                              status => settled, worm => WRes}),
            {ok, PostId, WRes};
        {error, _} = E -> E
    end.

authorized(Issuer) ->
    Issuers = case application:get_env(twinpay, treasury_issuers) of
                  {ok, L} -> L;
                  undefined -> [<<"treasury">>]
              end,
    lists:member(Issuer, Issuers).

new_id(Prefix) ->
    N = erlang:unique_integer([positive]),
    <<Prefix/binary, (integer_to_binary(N))/binary>>.

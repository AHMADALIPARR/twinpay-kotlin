%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% twinpay public API. Agents (and the HTTP layer) talk to the system
%% through these functions. Amounts are integer minor units of TWIN.
-module(twinpay_api).

-export([register_agent/1, register_agent/2,
         gift/3, gift/4,
         send/5, send/6,
         reverse/2, reverse/3,
         redeem/4,
         balance/1, feed/1, feed/2,
         supply/0, payment/1, conservation_check/0, worm_verify/0]).

%% --- agents ----------------------------------------------------------

register_agent(Handle) -> agent_registry:register(Handle).
register_agent(Handle, Meta) -> agent_registry:register(Handle, Meta).

%% --- treasury: the app gifts business tokens to agents ---------------

gift(Handle, Amount, Reason) ->
    gift(Handle, Amount, Reason, <<"treasury">>).

gift(Handle, Amount, Reason, Issuer)
  when is_integer(Amount), Amount > 0, is_binary(Reason) ->
    case agent_registry:lookup(Handle) of
        {ok, AgentId} -> treasury:gift(AgentId, Amount, Reason, Issuer);
        {error, _} = E -> E
    end;
gift(_, _, _, _) -> {error, bad_amount}.

%% --- transfers -------------------------------------------------------
%% send(FromHandle, ToHandle, AmountMinor, Memo, IdempotencyKey)
%% send/6 takes options: #{rail => internal | rtp}

send(FromH, ToH, Amount, Memo, Key) ->
    send(FromH, ToH, Amount, Memo, Key, #{}).

send(FromH, ToH, Amount, Memo, Key, Opts)
  when is_integer(Amount), Amount > 0, is_binary(Memo), is_binary(Key),
       byte_size(Key) > 0 ->
    case {agent_registry:lookup(FromH), agent_registry:lookup(ToH)} of
        {{ok, FromId}, {ok, ToId}} ->
            case idempotency:claim(Key) of
                {ok, fresh} ->
                    start_payment(Key, FromId, ToId, Amount, Memo, Opts);
                {ok, {duplicate, PaymentId, settled}} ->
                    case payments:lookup(PaymentId) of
                        {ok, Rec} -> {ok, already_processed, result(Rec)};
                        {error, not_found} -> {error, inconsistent}
                    end;
                {ok, {duplicate, _, failed}} ->
                    %% A failed attempt may be retried with the same key.
                    ok = idempotency:reclaim(Key),
                    start_payment(Key, FromId, ToId, Amount, Memo, Opts);
                {ok, {duplicate, _, claimed}} ->
                    {error, in_progress}
            end;
        _ -> {error, unknown_agent}
    end;
send(_, _, _, _, _, _) -> {error, bad_request}.

start_payment(Key, FromId, ToId, Amount, Memo, Opts) ->
    Id = new_id(),
    Rail = maps:get(rail, Opts, internal),
    Args = #{id => Id, idem_key => Key, from => FromId, to => ToId,
             amount => Amount, memo => Memo, rail => Rail},
    payments:record(#{id => Id, kind => transfer, from => FromId, to => ToId,
                      amount => Amount, memo => Memo, rail => Rail,
                      status => processing, created_at => now_ms()}),
    case payment_sup:start_payment(Args) of
        {ok, Pid} ->
            try payment_fsm:execute(Pid, 30000) of
                Res -> Res
            catch
                exit:_ ->
                    %% FSM died before fulfilling the key: release it so a
                    %% retry with the same key is not stuck on in_progress.
                    ok = idempotency:reclaim(Key),
                    {error, crashed}
            end;
        {error, _} = E ->
            ok = idempotency:reclaim(Key),
            E
    end.

%% --- reversals -------------------------------------------------------

reverse(PaymentId, Reason) -> reverse(PaymentId, Reason, <<"api">>).

reverse(PaymentId, Reason, Actor) when is_binary(Reason) ->
    reversal:reverse(PaymentId, Reason, Actor).

%% --- redemption: tokens -> fiat off-ramp ------------------------------
%% Burns the agent's tokens and builds a NACHA ACH credit file for the
%% linked bank account. Rate is the business policy
%% redemption_cents_per_token (default 100 = 1 TWIN -> $1.00).

redeem(Handle, TokenMinor, Routing, BankAccount)
  when is_integer(TokenMinor), TokenMinor > 0 ->
    %% The fiat boundary fails closed: in enforce mode a linked Plaid
    %% bank account is required before tokens can leave as ACH.
    case plaid_fiat_gate() of
        ok ->
            Rate = redemption_rate(),
            Cents = TokenMinor * Rate div token_scale(),
            case agent_registry:lookup(Handle) of
                {error, _} = E -> E;
                {ok, AgentId} ->
                    case treasury:redeem_burn(AgentId, TokenMinor, <<"redemption">>) of
                        {ok, BurnId, _WRes} ->
                            Entry = #{routing => Routing, account => BankAccount,
                                      amount_cents => Cents, name => Handle,
                                      trace => BurnId},
                            case rails_ach:build_file([Entry], redemption_opts()) of
                                {ok, File} -> {ok, BurnId, Cents, File};
                                {error, _} = E2 -> E2
                            end;
                        {error, _} = E -> E
                    end
            end;
        {error, _} = E -> E
    end;
redeem(_, _, _, _) -> {error, bad_request}.

%% In enforce mode, redemption requires a Plaid-linked bank account.
%% In permissive/mock mode the check is skipped.
plaid_fiat_gate() ->
    case plaid_client:mode() of
        enforce -> plaid_client:business_check(twinpay);
        _ -> ok
    end.

%% --- queries ----------------------------------------------------------

balance(Handle) ->
    case agent_registry:lookup(Handle) of
        {ok, AgentId} -> {ok, ledger:balance(AgentId)};
        {error, _} = E -> E
    end.

feed(Handle) -> feed(Handle, 20).

feed(Handle, Limit) ->
    case agent_registry:lookup(Handle) of
        {ok, AgentId} -> {ok, payments:list_for(AgentId, Limit)};
        {error, _} = E -> E
    end.

supply() -> treasury:supply().

payment(Id) -> payments:lookup(Id).

conservation_check() -> ledger:conservation_check().

worm_verify() -> worm:verify().

%% --- internals --------------------------------------------------------

new_id() ->
    N = erlang:unique_integer([positive]),
    <<"pay-", (integer_to_binary(N, 16))/binary>>.

result(Rec) ->
    #{id => maps:get(id, Rec),
      status => maps:get(status, Rec),
      worm => maps:get(worm, Rec, undefined)}.

token_scale() ->
    case application:get_env(twinpay, token_scale) of
        {ok, S} -> S;
        undefined -> 100
    end.

redemption_rate() ->
    case application:get_env(twinpay, redemption_cents_per_token) of
        {ok, R} -> R;
        undefined -> 100
    end.

redemption_opts() ->
    #{company_name => <<"TWINPAY">>,
      company_id => <<"TWINPAY01">>}.

now_ms() -> erlang:system_time(millisecond).

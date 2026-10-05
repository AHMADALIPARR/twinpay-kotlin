%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% One supervised payment. Lifecycle:
%%   verifying -> posting -> done | failed
%% Balance and existence checks run before any side effect; the ledger
%% post is idempotent per payment id, so a crash + supervisor restart
%% can never double-post. Verification ordering: fail before posting.
-module(payment_fsm).
-behaviour(gen_statem).

-export([start_link/1, execute/2]).
-export([init/1, callback_mode/0, verifying/3, posting/3, done/3, failed/3]).

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

execute(Pid, Timeout) ->
    gen_statem:call(Pid, execute, Timeout).

callback_mode() -> state_functions.

init(Args) ->
    {ok, verifying, Args}.

verifying({call, From}, execute,
          #{from := FromId, to := ToId, amount := Amount} = Data) ->
    %% Token transfers verify agent existence + token balance here.
    %% Plaid (fiat identity/banking) guards the fiat boundary only:
    %% business onboarding and token redemption, not token commerce.
    case pre_checks(FromId, ToId, Amount) of
        ok ->
            {next_state, posting, Data#{caller => From},
             [{next_event, internal, run}]};
        {error, _} = E ->
            finish_failed(Data, From, E)
    end;
verifying(_Event, _Content, Data) ->
    {keep_state, Data}.

posting(internal, run,
        #{id := Id, from := FromId, to := ToId, amount := Amount,
          memo := Memo, rail := Rail, caller := Caller,
          idem_key := Key} = Data) ->
    case ledger:post_transfer(Id, FromId, ToId, Amount, Memo) of
        {ok, already_posted} ->
            %% Restart after a crash that posted but died before
            %% recording: recover instead of double-posting.
            recover_posted(Data, Caller);
        {ok, _} ->
            Seq = ledger:seq(),
            WRes = worm:commit_entry(Id, FromId, ToId, Amount, $T, Seq),
            Rec = #{id => Id, kind => transfer, from => FromId, to => ToId,
                    amount => Amount, memo => Memo, rail => Rail,
                    status => settled, worm => WRes,
                    created_at => now_ms()},
            ok = payments:record(Rec),
            ok = idempotency:fulfill(Key, Id, settled),
            %% Rail dispatch is best-effort notification: the ledger
            %% posting above is the settlement. A rail failure is logged
            %% and never un-settles the payment.
            _ = maybe_rail(Rail, Data),
            {stop_and_reply, normal, [{reply, Caller, {ok, result(Rec)}}]};
        {error, _} = E ->
            finish_failed(Data, Caller, E)
    end;
posting(_Event, _Content, Data) ->
    {keep_state, Data}.

done({call, From}, _Content, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, done}}]};
done(_Event, _Content, Data) ->
    {keep_state, Data}.

failed({call, From}, _Content, _Data) ->
    {keep_state_and_data, [{reply, From, {error, failed}}]};
failed(_Event, _Content, Data) ->
    {keep_state, Data}.

%% Internal

pre_checks(FromId, ToId, Amount) ->
    case agent_registry:exists(FromId) andalso agent_registry:exists(ToId) of
        false -> {error, unknown_agent};
        true when Amount =< 0 -> {error, bad_amount};
        true ->
            case ledger:balance(FromId) >= Amount of
                true -> ok;
                false -> {error, insufficient_funds}
            end
    end.

maybe_rail(rtp, #{id := Id, from := FromId, to := ToId, amount := Amount,
                  idem_key := Key}) ->
    case rails_rtp:send_credit(FromId, ToId, Amount, Key, Id) of
        {ok, _, _} -> ok;
        {error, Reason} ->
            error_logger:warning_msg("twinpay: RTP rail failed for ~p: ~p~n",
                                     [Id, Reason]),
            {rail_failed, Reason}
    end;
maybe_rail(internal, _) -> ok;
maybe_rail(_, _) -> ok.

recover_posted(#{id := Id, caller := Caller, idem_key := Key} = Data, Caller) ->
    case payments:lookup(Id) of
        {ok, Rec} ->
            ok = idempotency:fulfill(Key, Id, settled),
            {stop_and_reply, normal, [{reply, Caller, {ok, result(Rec)}}]};
        {error, not_found} ->
            %% Legs exist but the record was lost: rebuild a minimal
            %% settled record from the legs so the journal stays complete.
            Rec = #{id => Id, kind => transfer,
                    from => maps:get(from, Data), to => maps:get(to, Data),
                    amount => maps:get(amount, Data),
                    memo => maps:get(memo, Data, <<>>),
                    status => settled, recovered => true,
                    created_at => now_ms()},
            ok = payments:record(Rec),
            ok = idempotency:fulfill(Key, Id, settled),
            {stop_and_reply, normal, [{reply, Caller, {ok, result(Rec)}}]}
    end.

finish_failed(#{id := Id, idem_key := Key} = Data, Caller, Error) ->
    Rec = #{id => Id, kind => transfer,
            from => maps:get(from, Data), to => maps:get(to, Data),
            amount => maps:get(amount, Data, 0),
            memo => maps:get(memo, Data, <<>>),
            status => failed, reason => Error,
            created_at => now_ms()},
    ok = payments:record(Rec),
    ok = idempotency:fulfill(Key, undefined, failed),
    {stop_and_reply, normal, [{reply, Caller, Error}]}.

result(Rec) ->
    #{id => maps:get(id, Rec),
      status => maps:get(status, Rec),
      worm => maps:get(worm, Rec, undefined)}.

now_ms() -> erlang:system_time(millisecond).

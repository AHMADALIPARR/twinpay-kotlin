%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Reversals are offsetting entries, never mutations. Reversing a
%% settled transfer posts a new balanced transfer in the opposite
%% direction and flags the original; a second attempt fails with
%% already_reversed. Only settled, non-reversed transfers can reverse.
%% Pattern verified in the finance twin: LEDREVSRV.rpgle ALREADYREV guard
%% and balanced offsetting entry. Fresh implementation.
-module(reversal).

-export([reverse/3]).

reverse(PaymentId, Reason, Actor) ->
    case payments:lookup(PaymentId) of
        {error, not_found} -> {error, not_found};
        {ok, #{status := reversed}} -> {error, already_reversed};
        {ok, #{status := Status}} when Status =/= settled ->
            {error, not_settled};
        {ok, #{kind := Kind}} when Kind =/= transfer ->
            {error, not_reversible};
        {ok, Rec} ->
            do_reverse(PaymentId, Rec, Reason, Actor)
    end.

do_reverse(PaymentId, #{from := From, to := To, amount := Amount}, Reason, Actor) ->
    NewId = new_id(),
    Memo = <<"reversal of ", PaymentId/binary, ": ", Reason/binary>>,
    case ledger:post_transfer(NewId, To, From, Amount, Memo) of
        {error, _} = E -> E;
        {ok, _} ->
            Seq = ledger:seq(),
            WRes = worm:commit_entry(NewId, To, From, Amount, $R, Seq),
            ok = payments:mark_reversed(PaymentId, NewId),
            payments:record(#{id => NewId, kind => reversal,
                              from => To, to => From, amount => Amount,
                              memo => Memo, status => settled,
                              reversal_of => PaymentId,
                              actor => Actor, worm => WRes,
                              created_at => now_ms()}),
            {ok, NewId, WRes}
    end.

new_id() ->
    N = erlang:unique_integer([positive]),
    <<"rvsl-", (integer_to_binary(N))/binary>>.

now_ms() -> erlang:system_time(millisecond).

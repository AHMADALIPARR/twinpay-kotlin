%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Payment records: the queryable journal of every transfer, gift,
%% burn, and reversal. ETS set keyed by payment id; values are maps.
-module(payments).

-export([record/1, lookup/1, mark_reversed/2, list_for/2]).

record(#{id := Id} = Rec) ->
    ets:insert(twinpay_payments, {Id, Rec}),
    ok.

lookup(Id) ->
    case ets:lookup(twinpay_payments, Id) of
        [{Id, Rec}] -> {ok, Rec};
        [] -> {error, not_found}
    end.

mark_reversed(Id, ReversalId) ->
    case lookup(Id) of
        {ok, Rec} ->
            record(Rec#{status => reversed, reversal_of => undefined,
                        reversed_by => ReversalId}),
            ok;
        {error, _} = E -> E
    end.

%% Most recent Limit payments involving Account (as sender or receiver).
list_for(Account, Limit) ->
    All = ets:foldl(fun({_, Rec}, Acc) ->
        case maps:get(from, Rec, undefined) =:= Account orelse
             maps:get(to, Rec, undefined) =:= Account of
            true -> [Rec | Acc];
            false -> Acc
        end
    end, [], twinpay_payments),
    Sorted = lists:sort(fun(A, B) ->
        maps:get(created_at, A, 0) >= maps:get(created_at, B, 0)
    end, All),
    lists:sublist(Sorted, Limit).

%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Double-entry token ledger. Amounts are integer minor units of TWIN;
%% there are no floats anywhere in the money path. Every transfer posts
%% two balanced legs (debit sender, credit receiver) so legs always sum
%% to zero. Issuance and burn are distinct leg kinds, never transfers.
%% Posting is serialized through this gen_server and is idempotent per
%% payment id, which makes FSM restarts safe.
%% Pattern verified in the finance twin: LEDGER_POST.cbl debit/credit
%% posting. Fresh implementation.
-module(ledger).
-behaviour(gen_server).

-export([start_link/0, post_transfer/5, post_issuance/3, post_burn/3,
         balance/1, legs/1, conservation_check/0, seq/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Leg kinds
-define(TRANSFER, transfer).
-define(ISSUE, issue).
-define(BURN, burn).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Idempotent: reposting the same PaymentId returns already_posted.
post_transfer(PaymentId, From, To, Amount, Memo)
  when is_integer(Amount), Amount > 0 ->
    gen_server:call(?MODULE, {post_transfer, PaymentId, From, To, Amount, Memo}).

post_issuance(PostId, To, Amount) when is_integer(Amount), Amount > 0 ->
    gen_server:call(?MODULE, {post_issuance, PostId, To, Amount}).

post_burn(PostId, From, Amount) when is_integer(Amount), Amount > 0 ->
    gen_server:call(?MODULE, {post_burn, PostId, From, Amount}).

balance(Account) ->
    ets:foldl(fun({_, _, Acct, Amt, _}, Sum) when Acct =:= Account -> Sum + Amt;
                 (_, Sum) -> Sum
              end, 0, twinpay_postings).

legs(PaymentId) ->
    [Leg || {_, Leg} <- ets:lookup(twinpay_legs, PaymentId)].

seq() ->
    ets:update_counter(twinpay_seq, seq, 0).

%% Every transfer/reversal leg must net to zero across the ledger.
conservation_check() ->
    Sum = ets:foldl(fun({_, _, _, Amt, Kind}, Acc)
                          when Kind =:= ?TRANSFER; Kind =:= reversal -> Acc + Amt;
                       (_, Acc) -> Acc
                    end, 0, twinpay_postings),
    case Sum of
        0 -> ok;
        _ -> {error, {imbalance, Sum}}
    end.

init([]) ->
    ets:new(twinpay_postings, [named_table, ordered_set, public,
                               {read_concurrency, true}]),
    ets:new(twinpay_legs, [named_table, bag, public,
                           {read_concurrency, true}]),
    ets:new(twinpay_seq, [named_table, set, public]),
    ets:new(twinpay_payments, [named_table, set, public,
                               {read_concurrency, true}]),
    ets:insert(twinpay_seq, {seq, 0}),
    {ok, #{}}.

handle_call({post_transfer, Pid, From, To, Amount, Memo}, _From, St) ->
    case ets:lookup(twinpay_legs, Pid) of
        [_|_] ->
            {reply, {ok, already_posted}, St};
        [] ->
            case balance(From) >= Amount of
                false ->
                    {reply, {error, insufficient_funds}, St};
                true ->
                    S1 = next_seq(), S2 = next_seq(),
                    insert_leg(S1, Pid, From, -Amount, ?TRANSFER, Memo),
                    insert_leg(S2, Pid, To, Amount, ?TRANSFER, Memo),
                    {reply, {ok, {S1, S2}}, St}
            end
    end;
handle_call({post_issuance, Pid, To, Amount}, _From, St) ->
    case ets:lookup(twinpay_legs, Pid) of
        [_|_] -> {reply, {ok, already_posted}, St};
        [] ->
            S = next_seq(),
            insert_leg(S, Pid, To, Amount, ?ISSUE, <<"gift">>),
            {reply, {ok, S}, St}
    end;
handle_call({post_burn, Pid, From, Amount}, _From, St) ->
    case ets:lookup(twinpay_legs, Pid) of
        [_|_] -> {reply, {ok, already_posted}, St};
        [] ->
            case balance(From) >= Amount of
                false -> {reply, {error, insufficient_funds}, St};
                true ->
                    S = next_seq(),
                    insert_leg(S, Pid, From, -Amount, ?BURN, <<"burn">>),
                    {reply, {ok, S}, St}
            end
    end;
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, _St) -> ok.

next_seq() -> ets:update_counter(twinpay_seq, seq, 1).

insert_leg(Seq, Pid, Acct, Amt, Kind, Memo) ->
    ets:insert(twinpay_postings, {Seq, Pid, Acct, Amt, Kind}),
    ets:insert(twinpay_legs, {Pid, {Seq, Pid, Acct, Amt, Kind, Memo}}).

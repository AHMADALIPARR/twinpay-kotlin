%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% twinpay test suite. Self-contained runner (no eunit on this host).
%% Runs the full app in mock Plaid mode against a throwaway WORM file.
%% run/0 executes every test and stops the VM with status 0/1.
-module(twinpay_tests).

-export([run/0]).

run() ->
    Worm = setup(),
    Tests = [{gift_and_supply, fun gift_and_supply/0},
             {gift_unauthorized, fun gift_unauthorized/0},
             {send_happy_path, fun send_happy_path/0},
             {idempotent_double_send, fun idempotent_double_send/0},
             {insufficient_funds, fun insufficient_funds/0},
             {conservation, fun conservation/0},
             {reversal_once, fun reversal_once/0},
             {worm_chain_verifies, fun worm_chain_verifies/0},
             {ach_file_shape, fun ach_file_shape/0},
             {rtp_idempotent, fun rtp_idempotent/0},
             {json_roundtrip, fun json_roundtrip/0}],
    {Passed, Failed} = lists:foldl(
        fun({Name, F}, {P, Fa}) ->
            try F() of
                ok ->
                    io:format("PASS ~p~n", [Name]),
                    {P + 1, Fa}
            catch
                throw:{check_failed, E, A, Line} ->
                    io:format("FAIL ~p (line ~p): expected ~p, got ~p~n",
                              [Name, Line, E, A]),
                    {P, Fa + 1};
                C:R:St ->
                    io:format("FAIL ~p: ~p:~p~n  ~p~n", [Name, C, R, St]),
                    {P, Fa + 1}
            end
        end, {0, 0}, Tests),
    cleanup(Worm),
    io:format("~n~p passed, ~p failed~n", [Passed, Failed]),
    case Failed of
        0 -> init:stop(0);
        _ -> init:stop(1)
    end.

check(Expected, Actual, Line) ->
    case Expected =:= Actual of
        true -> ok;
        false -> throw({check_failed, Expected, Actual, Line})
    end.

-define(check(E, A), check((E), (A), ?LINE)).

setup() ->
    application:load(twinpay),
    application:set_env(twinpay, plaid_mode, mock),
    Worm = "/tmp/twinpay-test-worm.dat",
    _ = file:delete(Worm),
    application:set_env(twinpay, worm_file, Worm),
    application:set_env(twinpay, http_port, 18080),
    {ok, _} = application:ensure_all_started(twinpay),
    Worm.

cleanup(Worm) ->
    application:stop(twinpay),
    _ = file:delete(Worm),
    ok.

%% Tests. Each returns ok or throws.

gift_and_supply() ->
    {ok, _} = twinpay_api:register_agent(<<"@alice1">>),
    {ok, Pid, _} = twinpay_api:gift(<<"@alice1">>, 10000, <<"onboarding">>),
    ?check(true, is_binary(Pid)),
    ?check({ok, 10000}, twinpay_api:balance(<<"@alice1">>)),
    ?check(true, twinpay_api:supply() >= 10000),
    ok.

gift_unauthorized() ->
    {ok, _} = twinpay_api:register_agent(<<"@mallory1">>),
    ?check({error, unauthorized},
           twinpay_api:gift(<<"@mallory1">>, 100, <<"x">>, <<"mallory">>)),
    ok.

send_happy_path() ->
    {ok, _} = twinpay_api:register_agent(<<"@alice2">>),
    {ok, _} = twinpay_api:register_agent(<<"@bob2">>),
    {ok, _, _} = twinpay_api:gift(<<"@alice2">>, 10000, <<"fund">>),
    {ok, #{id := Id, status := settled}} =
        twinpay_api:send(<<"@alice2">>, <<"@bob2">>, 2500,
                         <<"coffee">>, <<"key-happy-1">>),
    ?check({ok, 7500}, twinpay_api:balance(<<"@alice2">>)),
    ?check({ok, 2500}, twinpay_api:balance(<<"@bob2">>)),
    ?check(2, length(ledger:legs(Id))),
    {ok, Rec} = twinpay_api:payment(Id),
    ?check(settled, maps:get(status, Rec)),
    ok.

idempotent_double_send() ->
    {ok, _} = twinpay_api:register_agent(<<"@alice3">>),
    {ok, _} = twinpay_api:register_agent(<<"@bob3">>),
    {ok, _, _} = twinpay_api:gift(<<"@alice3">>, 10000, <<"fund">>),
    {ok, #{id := Id1}} =
        twinpay_api:send(<<"@alice3">>, <<"@bob3">>, 1000,
                         <<"lunch">>, <<"key-idem-1">>),
    {ok, already_processed, Rec} =
        twinpay_api:send(<<"@alice3">>, <<"@bob3">>, 1000,
                         <<"lunch">>, <<"key-idem-1">>),
    ?check(Id1, maps:get(id, Rec)),
    %% Exactly one debit happened: bob got 1000 once, not twice.
    ?check({ok, 1000}, twinpay_api:balance(<<"@bob3">>)),
    ?check({ok, 9000}, twinpay_api:balance(<<"@alice3">>)),
    ok.

insufficient_funds() ->
    {ok, _} = twinpay_api:register_agent(<<"@alice4">>),
    {ok, _} = twinpay_api:register_agent(<<"@bob4">>),
    {ok, _, _} = twinpay_api:gift(<<"@alice4">>, 500, <<"fund">>),
    ?check({error, insufficient_funds},
           twinpay_api:send(<<"@alice4">>, <<"@bob4">>, 99999,
                            <<"too much">>, <<"key-poor-1">>)),
    ?check({ok, 500}, twinpay_api:balance(<<"@alice4">>)),
    ?check({ok, 0}, twinpay_api:balance(<<"@bob4">>)),
    ok.

conservation() ->
    %% Every transfer/reversal leg nets to zero across the ledger.
    ?check(ok, twinpay_api:conservation_check()),
    ok.

reversal_once() ->
    {ok, _} = twinpay_api:register_agent(<<"@alice5">>),
    {ok, _} = twinpay_api:register_agent(<<"@bob5">>),
    {ok, _, _} = twinpay_api:gift(<<"@alice5">>, 8000, <<"fund">>),
    {ok, #{id := Id}} =
        twinpay_api:send(<<"@alice5">>, <<"@bob5">>, 3000,
                         <<"refund me">>, <<"key-rev-1">>),
    {ok, RevId, _} = twinpay_api:reverse(Id, <<"mistake">>),
    ?check(true, is_binary(RevId)),
    %% Balances restored exactly.
    ?check({ok, 8000}, twinpay_api:balance(<<"@alice5">>)),
    ?check({ok, 0}, twinpay_api:balance(<<"@bob5">>)),
    %% Second reversal is refused, not double-applied.
    ?check({error, already_reversed}, twinpay_api:reverse(Id, <<"again">>)),
    ?check({ok, 8000}, twinpay_api:balance(<<"@alice5">>)),
    %% The reversal itself posted two offsetting legs.
    ?check(2, length(ledger:legs(RevId))),
    ?check(ok, twinpay_api:conservation_check()),
    ok.

worm_chain_verifies() ->
    {ok, Count} = twinpay_api:worm_verify(),
    ?check(true, Count > 0),
    ok.

ach_file_shape() ->
    %% 021000021 is a check-digit-valid ABA routing number.
    Entry = #{routing => <<"021000021">>, account => <<"123456789">>,
              amount_cents => 15000, name => <<"@alice6">>,
              trace => <<"x">>},
    {ok, File} = rails_ach:build_file([Entry], #{company_name => <<"TWINPAY">>,
                                                 company_id => <<"TWINPAY01">>}),
    Lines = [L || L <- binary:split(File, <<"\n">>, [global]), L =/= <<>>],
    ?check(true, lists:all(fun(L) -> byte_size(L) =:= 94 end, Lines)),
    ?check(0, length(Lines) rem 10),
    ?check($1, binary:at(hd(Lines), 0)),
    ?check(true, rails_ach:aba_check(<<"021000021">>)),
    ?check(false, rails_ach:aba_check(<<"021000022">>)),
    {error, _} = rails_ach:build_file([Entry#{routing := <<"021000022">>}], #{}),
    ok.

rtp_idempotent() ->
    {ok, I1, queued} = rails_rtp:send_credit(<<"a">>, <<"b">>, 100,
                                             <<"rtp-key-1">>, <<"pay-1">>),
    {ok, I1, duplicate} = rails_rtp:send_credit(<<"a">>, <<"b">>, 100,
                                                <<"rtp-key-1">>, <<"pay-1">>),
    ?check(true, is_binary(I1)),
    ok.

json_roundtrip() ->
    M = #{<<"a">> => 1, <<"b">> => <<"x\"y">>, <<"c">> => [1, true, null],
          <<"d">> => #{<<"e">> => 1.5}},
    {ok, M2} = twinpay_json:decode(twinpay_json:encode(M)),
    ?check(M, M2),
    ok.

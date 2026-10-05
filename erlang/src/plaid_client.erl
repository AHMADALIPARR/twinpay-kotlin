%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Plaid read-only client. Plaid cannot move money; this module is the
%% verification and intelligence layer: confirm linked accounts exist and
%% check balances before the token rails do anything fiat-adjacent
%% (business onboarding, token redemption off-ramp).
%%
%% Modes (application env twinpay/plaid_mode):
%%   enforce    - Plaid must be connected; failures fail closed
%%   permissive - Plaid failures are logged and skipped
%%   mock       - canned responses for tests
-module(plaid_client).

-export([mode/0, status/0, accounts/0, business_check/1, available_balance/2,
         connect_url/0]).

-define(CONNECT_URL, "https://agent.meta.ai/connectors/connect/plaid").

mode() ->
    case application:get_env(twinpay, plaid_mode) of
        {ok, M} when M =:= enforce; M =:= permissive; M =:= mock -> M;
        _ -> enforce
    end.

%% -> connected | not_connected | {error, term()}
status() ->
    case mode() of
        mock -> connected;
        _ ->
            case run("status") of
                {ok, #{<<"connected">> := true}} -> connected;
                {ok, #{<<"connected">> := false}} -> not_connected;
                {ok, _} -> not_connected;
                {error, _} = E -> E
            end
    end.

%% -> {ok, [AccountMap]} | {error, term()}
accounts() ->
    case mode() of
        mock ->
            {ok, [#{<<"name">> => <<"Mock Checking">>,
                    <<"mask">> => <<"0000">>,
                    <<"balances">> => #{<<"available">> => 1000000,
                                        <<"current">> => 1000000}}]};
        _ ->
            case run("accounts") of
                {ok, #{<<"body">> := #{<<"accounts">> := Accts}}} -> {ok, Accts};
                {ok, Other} -> {error, {unexpected_shape, Other}};
                {error, _} = E -> E
            end
    end.

%% Business onboarding check: at least one linked account must exist.
%% Returns {ok, #{n_accounts := N}} | {error, plaid_not_connected} | {error, no_accounts}
business_check(_BusinessRef) ->
    case mode() of
        mock -> {ok, #{n_accounts => 1, mocked => true}};
        permissive ->
            case accounts() of
                {ok, Accts} -> {ok, #{n_accounts => length(Accts), skipped => false}};
                {error, _} -> {ok, #{n_accounts => 0, skipped => true}}
            end;
        enforce ->
            case status() of
                connected ->
                    case accounts() of
                        {ok, []} -> {error, no_accounts};
                        {ok, Accts} -> {ok, #{n_accounts => length(Accts)}};
                        {error, _} = E -> E
                    end;
                not_connected -> {error, plaid_not_connected};
                {error, _} = E -> E
            end
    end.

%% Available balance (minor units) for the first linked account, for
%% sizing a fiat off-ramp redemption. Plaid figures may lag the bank.
available_balance(_BusinessRef, _Currency) ->
    case accounts() of
        {ok, [#{<<"balances">> := #{<<"available">> := A}} | _]} when is_number(A) ->
            {ok, round(A * 100)};
        {ok, _} -> {error, no_balance};
        {error, _} = E -> E
    end.

connect_url() -> ?CONNECT_URL.

run(Args) ->
    Cmd = plaid_cmd() ++ " " ++ Args ++ " 2>/dev/null",
    case cmd(Cmd, app_timeout()) of
        {ok, Out} -> twinpay_json:decode(Out);
        {error, _} = E -> E
    end.

plaid_cmd() ->
    case application:get_env(twinpay, plaid_cmd) of
        {ok, C} -> C;
        undefined -> "plaid"
    end.

app_timeout() ->
    case application:get_env(twinpay, plaid_timeout_ms) of
        {ok, T} -> T;
        undefined -> 10000
    end.

%% Run a shell command with a hard timeout so a hung CLI can never hang
%% a payment FSM.
cmd(Cmd, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Out = try os:cmd(Cmd) catch _:R -> {crashed, R} end,
        Parent ! {Ref, Out}
    end),
    receive
        {Ref, Out} -> {ok, Out}
    after Timeout ->
        exit(Pid, kill),
        {error, timeout}
    end.

%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% twinpay application entry point.
-module(twinpay_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    {ok, Sup} = twinpay_sup:start_link(),
    start_http(),
    {ok, Sup}.

stop(_State) ->
    ok.

start_http() ->
    Port = app_env(http_port, 8080),
    Bind = app_env(http_bind, {127,0,0,1}),
    case twinpay_http:start(Bind, Port) of
        {ok, _Pid} -> ok;
        {error, Reason} ->
            error_logger:warning_msg("twinpay: HTTP API not started: ~p~n", [Reason]),
            ok
    end.

app_env(Key, Default) ->
    case application:get_env(twinpay, Key) of
        {ok, V} -> V;
        undefined -> Default
    end.

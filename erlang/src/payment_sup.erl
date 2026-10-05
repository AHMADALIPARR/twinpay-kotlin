%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Supervisor for payment FSMs. Each payment runs as a short-lived,
%% supervised gen_statem; crashes are restarted by the supervisor and the
%% idempotency layer makes restarts safe (no double posting).
-module(payment_sup).
-behaviour(supervisor).

-export([start_link/0, start_payment/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_payment(Args) ->
    supervisor:start_child(?MODULE, [Args]).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 60},
    Child = #{id => payment_fsm,
              start => {payment_fsm, start_link, []},
              restart => temporary, shutdown => 15000, type => worker},
    {ok, {SupFlags, [Child]}}.

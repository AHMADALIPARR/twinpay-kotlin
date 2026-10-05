%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Top-level supervisor. Permanent workers own the ETS tables they serve.
-module(twinpay_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 5, period => 60},
    Children = [
        #{id => twinpay_registry,
          start => {agent_registry, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => twinpay_idempotency,
          start => {idempotency, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => twinpay_ledger,
          start => {ledger, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => twinpay_treasury,
          start => {treasury, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => twinpay_worm,
          start => {worm, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => twinpay_rtp,
          start => {rails_rtp, start_link, []},
          restart => permanent, shutdown => 5000, type => worker},
        #{id => payment_sup,
          start => {payment_sup, start_link, []},
          restart => permanent, shutdown => infinity, type => supervisor}
    ],
    {ok, {SupFlags, Children}}.

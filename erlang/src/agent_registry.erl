%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Agent registry: Venmo-like handles (@alice) mapped to agent ids.
-module(agent_registry).
-behaviour(gen_server).
-compile({no_auto_import, [register/2]}).

-export([start_link/0, register/1, register/2, lookup/1, exists/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(Handle) -> register(Handle, #{}).

register(Handle, Meta) when is_binary(Handle) ->
    gen_server:call(?MODULE, {register, normalize(Handle), Meta}).

lookup(Handle) ->
    case ets:lookup(twinpay_agents, normalize(Handle)) of
        [{_, AgentId, _}] -> {ok, AgentId};
        [] -> {error, unknown_agent}
    end.

exists(AgentId) ->
    ets:foldl(fun({_, Id, _}, Acc) -> Acc orelse Id =:= AgentId end,
              false, twinpay_agents).

normalize(H) ->
    H1 = string:trim(H),
    case H1 of
        <<$@, _/binary>> -> H1;
        _ -> <<$@, H1/binary>>
    end.

init([]) ->
    ets:new(twinpay_agents, [named_table, set, public,
                             {read_concurrency, true}]),
    {ok, #{}}.

handle_call({register, Handle, Meta}, _From, St) ->
    case valid_handle(Handle) of
        false ->
            {reply, {error, invalid_handle}, St};
        true ->
            case ets:lookup(twinpay_agents, Handle) of
                [{_, AgentId, _}] ->
                    {reply, {ok, AgentId}, St};
                [] ->
                    AgentId = new_id(),
                    ets:insert(twinpay_agents,
                               {Handle, AgentId,
                                Meta#{handle => Handle,
                                      created_at => now_ms()}}),
                    {reply, {ok, AgentId}, St}
            end
    end;
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, _St) -> ok.

valid_handle(<<$@, Rest/binary>>) ->
    byte_size(Rest) >= 2 andalso byte_size(Rest) =< 32 andalso
        re:run(Rest, "^[A-Za-z0-9_]+$", [{capture, none}]) =:= match;
valid_handle(_) -> false.

new_id() ->
    N = erlang:unique_integer([positive]),
    <<"ag-", (integer_to_binary(N, 16))/binary>>.

now_ms() -> erlang:system_time(millisecond).

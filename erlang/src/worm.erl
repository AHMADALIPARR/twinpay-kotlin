%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% WORM audit anchor. Owns the port to the vendored finance-twin WORM
%% commit program (c_src/worm_port, built from the verbatim vendored
%% worm_block.h / worm_commit.c). Every ledger posting and reversal is
%% appended to the hash chain; the chain is verifiable end to end.
%%
%% 128-byte entry payload layout (twinpay convention, text fields):
%%   0..35   payment/tx id, space padded      (36)
%%   36..49  timestamp yyyymmddhhmmss          (14)
%%   50..59  sequence, zero-padded decimal     (10)
%%   60..75  source account                    (16)
%%   76..91  destination account               (16)
%%   92..107 amount minor units, signed        (16)
%%   108..110 currency "TWN"                    (3)
%%   111     kind: $T transfer | $I issue | $B burn | $R reversal
%%   112..127 reserved, zeros                   (16)
-module(worm).
-behaviour(gen_server).

-export([start_link/0, commit/1, commit_entry/6, verify/0, count/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_PAYLOAD, 4096).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Raw payload commit (<= 4096 bytes). Returns {ok, Index, Hash64}.
commit(Payload) when is_binary(Payload), byte_size(Payload) =< ?MAX_PAYLOAD ->
    gen_server:call(?MODULE, {commit, Payload}, 30000).

%% Build a 128-byte ledger entry and commit it.
%% Kind is $T | $I | $B | $R.
commit_entry(TxId, Src, Dst, AmountMinor, Kind, Seq) ->
    commit(entry_payload(TxId, Src, Dst, AmountMinor, Kind, Seq)).

verify() ->
    gen_server:call(?MODULE, verify, 60000).

count() ->
    gen_server:call(?MODULE, count, 15000).

entry_payload(TxId, Src, Dst, AmountMinor, Kind, Seq) ->
    Ts = timestamp(),
    <<(pad_bin(TxId, 36))/binary,
      Ts/binary,
      (pad_num(Seq, 10))/binary,
      (pad_bin(Src, 16))/binary,
      (pad_bin(Dst, 16))/binary,
      (pad_signed(AmountMinor, 16))/binary,
      <<"TWN">>/binary,
      Kind:8,
      0:128>>.

timestamp() ->
    {{Y,M,D},{H,Mi,S}} = calendar:universal_time(),
    list_to_binary(io_lib:format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B",
                                 [Y,M,D,H,Mi,S])).

pad_bin(B, N) when is_binary(B) ->
    Sz = byte_size(B),
    if Sz >= N -> binary:part(B, 0, N);
       true -> <<B/binary, (binary:copy(<<" ">>, N - Sz))/binary>>
    end;
pad_bin(L, N) when is_list(L) -> pad_bin(list_to_binary(L), N);
pad_bin(A, N) when is_atom(A) -> pad_bin(atom_to_binary(A, utf8), N).

pad_num(I, N) when is_integer(I) ->
    S = integer_to_binary(I),
    Sz = byte_size(S),
    if Sz >= N -> binary:part(S, Sz - N, N);
       true -> <<(binary:copy(<<"0">>, N - Sz))/binary, S/binary>>
    end.

pad_signed(I, N) when is_integer(I), I >= 0 -> pad_num(I, N);
pad_signed(I, N) when is_integer(I) ->
    S = integer_to_binary(I),
    Sz = byte_size(S),
    if Sz >= N -> binary:part(S, Sz - N, N);
       true -> <<$-, (binary:copy(<<"0">>, N - Sz - 1))/binary,
                 (binary:part(S, 1, Sz - 1))/binary>>
    end.

%% gen_server

init([]) ->
    PortProg = port_program(),
    DataFile = data_file(),
    Port = open_port({spawn_executable, PortProg},
                     [{args, [DataFile]}, {packet, 4}, binary, exit_status,
                      {env, []}]),
    {ok, #{port => Port}}.

handle_call({commit, Payload}, _From, #{port := Port} = St) ->
    port_command(Port, <<$C, Payload/binary>>),
    Reply = await_reply(Port, 25000),
    {reply, Reply, St};
handle_call(verify, _From, #{port := Port} = St) ->
    port_command(Port, <<$V>>),
    {reply, await_reply(Port, 55000), St};
handle_call(count, _From, #{port := Port} = St) ->
    port_command(Port, <<$N>>),
    {reply, await_reply(Port, 10000), St};
handle_call(_Req, _From, St) ->
    {reply, {error, unknown}, St}.

handle_cast(_Msg, St) -> {noreply, St}.

handle_info({Port, {exit_status, Code}}, #{port := Port} = St) ->
    error_logger:error_msg("twinpay worm port exited: ~p~n", [Code]),
    {stop, {port_exit, Code}, St};
handle_info(_Info, St) -> {noreply, St}.

terminate(_Reason, _St) -> ok.

await_reply(Port, Timeout) ->
    receive
        {Port, {data, <<$O, Index:64/big, Hash:64/binary>>}} ->
            {ok, Index, Hash};
        {Port, {data, <<$O, Count:64/big>>}} ->
            {ok, Count};
        {Port, {data, <<$E, Code:32/signed-big>>}} ->
            {error, Code};
        {Port, {data, <<$E, Bad:64/big>>}} ->
            {error, {chain_broken, Bad}}
    after Timeout ->
        {error, timeout}
    end.

port_program() ->
    case code:priv_dir(twinpay) of
        {error, _} -> filename:absname("priv/worm_port");
        Dir -> filename:join(Dir, "worm_port")
    end.

data_file() ->
    case application:get_env(twinpay, worm_file) of
        {ok, P} -> P;
        undefined ->
            case code:priv_dir(twinpay) of
                {error, _} -> filename:absname("priv/worm.dat");
                Dir -> filename:join(Dir, "worm.dat")
            end
    end.

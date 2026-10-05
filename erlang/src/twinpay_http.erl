%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% HTTP/JSON API for agents. Minimal gen_tcp server (no external deps):
%% JSON in, JSON out. Amounts are integer minor units of TWIN.
%%
%%   POST /v1/agents                        {handle} -> {agent_id}
%%   POST /v1/gifts                          {handle, amount, reason} + x-treasury-key
%%   POST /v1/transfers                      {from, to, amount, memo, idempotency_key[, rail]}
%%   GET  /v1/transfers/:id
%%   POST /v1/transfers/:id/reversal         {reason}
%%   POST /v1/redemptions                    {handle, token_amount, routing, bank_account}
%%   GET  /v1/agents/:handle/balance
%%   GET  /v1/agents/:handle/feed?limit=N
%%   GET  /v1/supply
%%   GET  /v1/conservation
%%   GET  /v1/health
-module(twinpay_http).
-behaviour(gen_server).

-export([start/2, start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start(Bind, Port) ->
    gen_server:start({local, ?MODULE}, ?MODULE, [Bind, Port], []).

start_link(Bind, Port) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Bind, Port], []).

init([Bind, Port]) ->
    case gen_tcp:listen(Port, [binary, {packet, raw}, {reuseaddr, true},
                               {active, false}, {ip, Bind}]) of
        {ok, LS} ->
            spawn_link(fun() -> accept_loop(LS) end),
            {ok, #{listen => LS, port => Port}};
        {error, _} = E ->
            {stop, E}
    end.

handle_call(_Req, _From, St) -> {reply, {error, unknown}, St}.
handle_cast(_Msg, St) -> {noreply, St}.
handle_info(_Info, St) -> {noreply, St}.
terminate(_Reason, #{listen := LS}) -> gen_tcp:close(LS);
terminate(_Reason, _) -> ok.

accept_loop(LS) ->
    case gen_tcp:accept(LS) of
        {ok, Sock} ->
            spawn(fun() -> handle(Sock) end),
            accept_loop(LS);
        {error, closed} -> ok;
        {error, _} -> accept_loop(LS)
    end.

handle(Sock) ->
    try
        case read_request(Sock) of
            {ok, Method, Path, Qs, Headers, Body} ->
                {Status, Resp} = route(Method, Path, Qs, Headers, Body),
                send_resp(Sock, Status, Resp);
            {error, _} ->
                send_resp(Sock, 400, #{error => <<"bad_request">>})
        end
    catch
        _:R -> send_resp(Sock, 500, #{error => atom_to_binary(R, utf8)})
    after
        gen_tcp:close(Sock)
    end.

read_request(Sock) ->
    case recv_until(Sock, <<"\r\n\r\n">>, <<>>, 5000) of
        {ok, Head, Rest} ->
            [ReqLine | HLines] = binary:split(Head, <<"\r\n">>, [global]),
            [Method, Target | _] = binary:split(ReqLine, <<" ">>, [global]),
            {Path, Qs} = split_target(Target),
            Headers = parse_headers(HLines),
            Len = content_length(Headers),
            Body = take_body(Sock, Rest, Len),
            {ok, Method, Path, Qs, Headers, Body};
        {error, _} = E -> E
    end.

recv_until(Sock, Delim, Acc, Timeout) ->
    case binary:match(Acc, Delim) of
        {Pos, L} ->
            {ok, binary:part(Acc, 0, Pos),
                 binary:part(Acc, Pos + L, byte_size(Acc) - Pos - L)};
        nomatch ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Data} -> recv_until(Sock, Delim, <<Acc/binary, Data/binary>>, Timeout);
                {error, _} = E -> E
            end
    end.

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [P] -> {P, <<>>};
        [P, Q] -> {P, Q}
    end.

parse_headers(Lines) ->
    lists:foldl(fun(Line, Acc) ->
        case binary:split(Line, <<":">>) of
            [K, V] -> [{string:lowercase(string:trim(K)),
                        string:trim(V)} | Acc];
            _ -> Acc
        end
    end, [], Lines).

content_length(Headers) ->
    case proplists:get_value(<<"content-length">>, Headers, <<"0">>) of
        B -> try binary_to_integer(B) catch _:_ -> 0 end
    end.

take_body(_Sock, Rest, 0) -> Rest;
take_body(Sock, Rest, Len) ->
    Have = byte_size(Rest),
    if Have >= Len -> binary:part(Rest, 0, Len);
       true ->
            case gen_tcp:recv(Sock, Len - Have, 5000) of
                {ok, More} -> <<Rest/binary, More/binary>>;
                {error, _} -> Rest
            end
    end.

%% Routing

route(<<"GET">>, <<"/v1/health">>, _, _, _) ->
    WBlocks = case worm:count() of {ok, C} -> C; _ -> -1 end,
    {200, #{status => <<"ok">>, supply => twinpay_api:supply(),
            worm_blocks => WBlocks}};
route(<<"GET">>, <<"/v1/supply">>, _, _, _) ->
    {200, #{supply => twinpay_api:supply(),
            symbol => token_symbol()}};
route(<<"GET">>, <<"/v1/conservation">>, _, _, _) ->
    {200, #{ledger => fmt(twinpay_api:conservation_check()),
            worm => fmt(twinpay_api:worm_verify())}};
route(<<"POST">>, <<"/v1/agents">>, _, _, Body) ->
    with_json(Body, fun(#{<<"handle">> := H}) ->
        case twinpay_api:register_agent(H) of
            {ok, Id} -> {201, #{agent_id => Id, handle => norm(H)}};
            {error, R} -> {400, #{error => atom_to_binary(R, utf8)}}
        end
    end);
route(<<"POST">>, <<"/v1/gifts">>, _, Headers, Body) ->
    case treasury_key_ok(Headers) of
        false -> {403, #{error => <<"forbidden">>}};
        true ->
            with_json(Body, fun(M) ->
                #{<<"handle">> := H, <<"amount">> := A} = M,
                Reason = maps:get(<<"reason">>, M, <<"gift">>),
                case twinpay_api:gift(H, int(A), bin(Reason)) of
                    {ok, Pid, WRes} ->
                        {201, #{payment_id => Pid, worm => fmt_worm(WRes)}};
                    {error, R} -> {400, #{error => atom_to_binary(R, utf8)}}
                end
            end)
    end;
route(<<"POST">>, <<"/v1/transfers">>, _, _, Body) ->
    with_json(Body, fun(M) ->
        #{<<"from">> := F, <<"to">> := T, <<"amount">> := A,
          <<"idempotency_key">> := K} = M,
        Memo = maps:get(<<"memo">>, M, <<>>),
        Rail = rail_opt(maps:get(<<"rail">>, M, <<"internal">>)),
        case twinpay_api:send(F, T, int(A), bin(Memo), K, #{rail => Rail}) of
            {ok, #{id := Id, status := St, worm := W}} ->
                {202, #{payment_id => Id, status => atom_to_binary(St, utf8),
                        worm => fmt_worm(W)}};
            {ok, already_processed, Rec} ->
                {200, #{payment_id => maps:get(id, Rec),
                        status => <<"already_processed">>}};
            {error, R} when is_atom(R) ->
                {422, #{error => atom_to_binary(R, utf8)}};
            {error, R} ->
                {422, #{error => fmt_err(R)}}
        end
    end);
route(<<"GET">>, <<"/v1/transfers/", Id/binary>>, _, _, _) ->
    case twinpay_api:payment(Id) of
        {ok, Rec} -> {200, fmt_payment(Rec)};
        {error, not_found} -> {404, #{error => <<"not_found">>}}
    end;
route(<<"POST">>, <<"/v1/transfers/", Rest/binary>>, _, _, Body) ->
    case binary:split(Rest, <<"/">>) of
        [Id, <<"reversal">>] ->
            with_json(Body, fun(M) ->
                Reason = maps:get(<<"reason">>, M, <<"reversal">>),
                case twinpay_api:reverse(Id, bin(Reason)) of
                    {ok, NewId, WRes} ->
                        {201, #{reversal_id => NewId, worm => fmt_worm(WRes)}};
                    {error, R} when is_atom(R) ->
                        {422, #{error => atom_to_binary(R, utf8)}};
                    {error, R} -> {422, #{error => fmt_err(R)}}
                end
            end);
        _ -> {404, #{error => <<"not_found">>}}
    end;
route(<<"POST">>, <<"/v1/redemptions">>, _, _, Body) ->
    with_json(Body, fun(M) ->
        #{<<"handle">> := H, <<"token_amount">> := A,
          <<"routing">> := R, <<"bank_account">> := B} = M,
        case twinpay_api:redeem(H, int(A), R, B) of
            {ok, BurnId, Cents, File} ->
                {201, #{burn_id => BurnId, cents => Cents,
                        nacha_lines => length(binary:split(File, <<"\n">>, [global])) - 1}};
            {error, Rsn} when is_atom(Rsn) ->
                {422, #{error => atom_to_binary(Rsn, utf8)}};
            {error, Rsn} -> {422, #{error => fmt_err(Rsn)}}
        end
    end);
route(<<"GET">>, <<"/v1/agents/", Rest/binary>>, Qs, _, _) ->
    case binary:split(Rest, <<"/">>) of
        [Handle, <<"balance">>] ->
            case twinpay_api:balance(Handle) of
                {ok, B} -> {200, #{handle => norm(Handle), balance => B,
                                  symbol => token_symbol()}};
                {error, R} -> {404, #{error => atom_to_binary(R, utf8)}}
            end;
        [Handle, <<"feed">>] ->
            Limit = qs_int(Qs, <<"limit">>, 20),
            case twinpay_api:feed(Handle, Limit) of
                {ok, Items} -> {200, #{items => [fmt_payment(I) || I <- Items]}};
                {error, R} -> {404, #{error => atom_to_binary(R, utf8)}}
            end;
        _ -> {404, #{error => <<"not_found">>}}
    end;
route(_, _, _, _, _) ->
    {404, #{error => <<"not_found">>}}.

%% Helpers

with_json(<<>>, _) -> {400, #{error => <<"empty_body">>}};
with_json(Body, Fun) ->
    case twinpay_json:decode(Body) of
        {ok, M} when is_map(M) ->
            try Fun(M)
            catch error:{badkey, _} -> {400, #{error => <<"missing_field">>}};
                  _:_ -> {400, #{error => <<"bad_request">>}}
            end;
        {ok, _} -> {400, #{error => <<"json_object_required">>}};
        {error, _} -> {400, #{error => <<"bad_json">>}}
    end.

treasury_key_ok(Headers) ->
    Expected = case application:get_env(twinpay, treasury_key) of
                   {ok, K} -> K;
                   undefined -> <<"change-me">>
               end,
    proplists:get_value(<<"x-treasury-key">>, Headers, <<>>) =:= Expected.

rail_opt(<<"rtp">>) -> rtp;
rail_opt(_) -> internal.

int(I) when is_integer(I) -> I;
int(_) -> throw(bad_amount).

bin(B) when is_binary(B) -> B;
bin(L) when is_list(L) -> list_to_binary(L);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

norm(H) when is_binary(H) ->
    case H of <<$@, _/binary>> -> H; _ -> <<$@, H/binary>> end.

token_symbol() ->
    case application:get_env(twinpay, token_symbol) of
        {ok, S} -> S;
        undefined -> <<"TWIN">>
    end.

fmt(ok) -> <<"ok">>;
fmt({ok, N}) when is_integer(N) -> N;
fmt({ok, M}) when is_map(M) -> <<"ok">>;
fmt({error, R}) -> #{error => fmt_err(R)}.

fmt_err(A) when is_atom(A) -> atom_to_binary(A, utf8);
fmt_err({chain_broken, I}) -> <<"chain_broken_at_", (integer_to_binary(I))/binary>>;
fmt_err(T) -> list_to_binary(io_lib:format("~p", [T])).

fmt_worm({ok, Index, Hash}) ->
    #{index => Index, hash => hex(Hash)};
fmt_worm(Other) -> fmt(Other).

hex(B) when is_binary(B) ->
    <<<<(hex1((X bsr 4) band 15)), (hex1(X band 15))>> || <<X>> <= B>>;
hex(_) -> null.

hex1(N) when N < 10 -> $0 + N;
hex1(N) -> $a + N - 10.

fmt_payment(Rec) ->
    #{id => maps:get(id, Rec),
      kind => atom_to_binary(maps:get(kind, Rec, transfer), utf8),
      from => maps:get(from, Rec, null),
      to => maps:get(to, Rec, null),
      amount => maps:get(amount, Rec, 0),
      memo => maps:get(memo, Rec, <<>>),
      status => atom_to_binary(maps:get(status, Rec, unknown), utf8),
      worm => fmt_worm(maps:get(worm, Rec, undefined))}.

qs_int(Qs, Key, Default) ->
    case parse_qs(Qs) of
        #{Key := V} -> try binary_to_integer(V) catch _:_ -> Default end;
        _ -> Default
    end.

parse_qs(<<>>) -> #{};
parse_qs(Qs) ->
    maps:from_list(
      [case binary:split(P, <<"=">>) of
           [K, V] -> {K, V};
           [K] -> {K, <<>>}
       end || P <- binary:split(Qs, <<"&">>, [global]), P =/= <<>>]).

send_resp(Sock, Status, Map) ->
    Body = twinpay_json:encode(Map),
    Head = [status_line(Status),
            "Content-Type: application/json\r\n",
            "Content-Length: ", integer_to_binary(byte_size(Body)), "\r\n",
            "Connection: close\r\n\r\n"],
    gen_tcp:send(Sock, [Head, Body]).

status_line(200) -> "HTTP/1.1 200 OK\r\n";
status_line(201) -> "HTTP/1.1 201 Created\r\n";
status_line(202) -> "HTTP/1.1 202 Accepted\r\n";
status_line(400) -> "HTTP/1.1 400 Bad Request\r\n";
status_line(403) -> "HTTP/1.1 403 Forbidden\r\n";
status_line(404) -> "HTTP/1.1 404 Not Found\r\n";
status_line(422) -> "HTTP/1.1 422 Unprocessable Entity\r\n";
status_line(_) -> "HTTP/1.1 500 Internal Server Error\r\n".

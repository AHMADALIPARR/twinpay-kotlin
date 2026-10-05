%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% Minimal JSON parser and encoder (no external deps).
%% decode/1 -> {ok, Term} | {error, Reason}. Objects become maps with
%% binary keys, arrays become lists, true/false/null become atoms.
-module(twinpay_json).

-export([decode/1, encode/1]).

decode(Bin) when is_binary(Bin) ->
    try
        {Term, Rest} = parse_value(skip_ws(Bin)),
        case skip_ws(Rest) of
            <<>> -> {ok, Term};
            _ -> {error, trailing_data}
        end
    catch
        throw:{json_error, R} -> {error, R};
        error:_ -> {error, bad_json}
    end;
decode(L) when is_list(L) -> decode(list_to_binary(L)).

encode(Map) when is_map(Map) ->
    Pairs = maps:to_list(Map),
    <<${, (encode_pairs(Pairs))/binary, $}>>;
encode(L) when is_list(L) ->
    case is_string_list(L) of
        true -> encode_string(list_to_binary(L));
        false -> <<$[, (encode_list(L))/binary, $]>>
    end;
encode(B) when is_binary(B) -> encode_string(B);
encode(A) when is_atom(A) ->
    case A of
        true -> <<"true">>;
        false -> <<"false">>;
        null -> <<"null">>;
        _ -> encode_string(atom_to_binary(A, utf8))
    end;
encode(I) when is_integer(I) -> integer_to_binary(I);
encode(F) when is_float(F) -> float_to_binary(F, [short]).

is_string_list([]) -> false;
is_string_list(L) -> lists:all(fun(C) -> is_integer(C) andalso C >= 0 andalso C =< 16#10FFFF end, L) andalso
                     not lists:any(fun(X) -> is_list(X) orelse is_map(X) orelse is_binary(X) end, L).

encode_pairs([]) -> <<>>;
encode_pairs([{K,V}|Rest]) ->
    Pair = <<(encode_key(K))/binary, $:, (encode(V))/binary>>,
    case Rest of
        [] -> Pair;
        _ -> <<Pair/binary, $,, (encode_pairs(Rest))/binary>>
    end.

encode_key(K) when is_binary(K) -> encode_string(K);
encode_key(K) when is_atom(K) -> encode_string(atom_to_binary(K, utf8));
encode_key(K) when is_list(K) -> encode_string(list_to_binary(K)).

encode_list([]) -> <<>>;
encode_list([H|T]) ->
    E = encode(H),
    case T of
        [] -> E;
        _ -> <<E/binary, $,, (encode_list(T))/binary>>
    end.

encode_string(B) ->
    <<$", (escape(B))/binary, $">>.

escape(B) -> escape(B, <<>>).
escape(<<>>, Acc) -> Acc;
escape(<<$", Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $">>);
escape(<<$\\, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $\\>>);
escape(<<$\n, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $n>>);
escape(<<$\r, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $r>>);
escape(<<$\t, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, $\\, $t>>);
escape(<<C, Rest/binary>>, Acc) when C < 16#20 ->
    Hex = io_lib:format("~4.16.0B", [C]),
    escape(Rest, <<Acc/binary, $\\, $u, (list_to_binary(Hex))/binary>>);
escape(<<C, Rest/binary>>, Acc) -> escape(Rest, <<Acc/binary, C>>).

%% Parser

skip_ws(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    skip_ws(Rest);
skip_ws(B) -> B.

parse_value(<<${, Rest/binary>>) -> parse_object(skip_ws(Rest), #{});
parse_value(<<$[, Rest/binary>>) -> parse_array(skip_ws(Rest), []);
parse_value(<<$", Rest/binary>>) -> parse_string(Rest, <<>>);
parse_value(<<$t, $r, $u, $e, Rest/binary>>) -> {true, Rest};
parse_value(<<$f, $a, $l, $s, $e, Rest/binary>>) -> {false, Rest};
parse_value(<<$n, $u, $l, $l, Rest/binary>>) -> {null, Rest};
parse_value(<<C, _/binary>> = B) when C =:= $- orelse (C >= $0 andalso C =< $9) ->
    parse_number(B);
parse_value(_) -> throw({json_error, bad_value}).

parse_object(<<$}, Rest/binary>>, Acc) -> {Acc, Rest};
parse_object(Bin, Acc) ->
    {Key, R1} = case skip_ws(Bin) of
                    <<$", R/binary>> -> parse_string(R, <<>>);
                    _ -> throw({json_error, bad_key})
                end,
    R2 = case skip_ws(R1) of
             <<$:, RColon/binary>> -> RColon;
             _ -> throw({json_error, no_colon})
         end,
    {Val, R3} = parse_value(skip_ws(R2)),
    Acc1 = Acc#{Key => Val},
    case skip_ws(R3) of
        <<$,, R4/binary>> -> parse_object(skip_ws(R4), Acc1);
        <<$}, R4/binary>> -> {Acc1, R4};
        _ -> throw({json_error, bad_object})
    end.

parse_array(<<$], Rest/binary>>, Acc) -> {lists:reverse(Acc), Rest};
parse_array(Bin, Acc) ->
    {Val, R1} = parse_value(Bin),
    case skip_ws(R1) of
        <<$,, R2/binary>> -> parse_array(skip_ws(R2), [Val | Acc]);
        <<$], R2/binary>> -> {lists:reverse([Val | Acc]), R2};
        _ -> throw({json_error, bad_array})
    end.

parse_string(<<$", Rest/binary>>, Acc) -> {Acc, Rest};
parse_string(<<$\\, $", Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $">>);
parse_string(<<$\\, $\\, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $\\>>);
parse_string(<<$\\, $/, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $/>>);
parse_string(<<$\\, $b, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $\b>>);
parse_string(<<$\\, $f, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $\f>>);
parse_string(<<$\\, $n, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $\n>>);
parse_string(<<$\\, $r, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $\r>>);
parse_string(<<$\\, $t, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, $\t>>);
parse_string(<<$\\, $u, H1, H2, H3, H4, Rest/binary>>, Acc) ->
    Code = hex4(H1, H2, H3, H4),
    parse_string(Rest, <<Acc/binary, Code/utf8>>);
parse_string(<<C, Rest/binary>>, Acc) -> parse_string(Rest, <<Acc/binary, C>>);
parse_string(<<>>, _) -> throw({json_error, unterminated_string}).

hex4(A, B, C, D) ->
    hex1(A)*4096 + hex1(B)*256 + hex1(C)*16 + hex1(D).

hex1(C) when C >= $0, C =< $9 -> C - $0;
hex1(C) when C >= $a, C =< $f -> C - $a + 10;
hex1(C) when C >= $A, C =< $F -> C - $A + 10;
hex1(_) -> throw({json_error, bad_unicode}).

parse_number(Bin) ->
    {NumBin, Rest} = take_number(Bin, <<>>),
    case binary:match(NumBin, [<<$.>>, <<$e>>, <<$E>>]) of
        nomatch ->
            {binary_to_integer(NumBin), Rest};
        _ ->
            {binary_to_float(NumBin), Rest}
    end.

take_number(<<C, Rest/binary>>, Acc) when C =:= $-; C =:= $+; C =:= $.;
                                          (C >= $0 andalso C =< $9);
                                          C =:= $e; C =:= $E ->
    take_number(Rest, <<Acc/binary, C>>);
take_number(Bin, Acc) when byte_size(Acc) > 0 -> {Acc, Bin};
take_number(_, _) -> throw({json_error, bad_number}).

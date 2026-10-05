%% SPDX-License-Identifier: MIT
%% Copyright (C) 2026 Ahmad Parr

%% ACH off-ramp rail: builds NACHA-format files for token redemptions
%% (CCD credits). This is the file-origination side; actual submission to
%% an ODFI/bank is outside this host. All records are 94 chars, blocked
%% in tens. Amounts are integer cents.
-module(rails_ach).

-export([build_file/2, aba_check/1, routing_check_digit/1]).

%% Entries: [#{routing := <<"9 digits">>, account := binary(),
%%             amount_cents := integer(), name := binary(), trace := binary()}]
%% Opts: #{company_name := binary(), company_id := binary(),
%%         dest_routing => binary(), origin_routing => binary()}
build_file(Entries, Opts) when is_list(Entries), Entries =/= [] ->
    case validate_entries(Entries) of
        ok ->
            {ok, assemble(Entries, Opts)};
        {error, _} = E -> E
    end;
build_file(_, _) -> {error, no_entries}.

validate_entries(Entries) ->
    Bad = [E || E <- Entries, not valid_entry(E)],
    case Bad of
        [] -> ok;
        _ -> {error, {invalid_entries, length(Bad)}}
    end.

valid_entry(#{routing := R, account := A, amount_cents := C}) ->
    byte_size(R) =:= 9 andalso aba_check(R) andalso
        byte_size(A) > 0 andalso byte_size(A) =< 17 andalso
        is_integer(C) andalso C > 0 andalso C < 10000000000;
valid_entry(_) -> false.

%% ABA routing check digit: (3*(d1+d4+d7) + 7*(d2+d5+d8) + (d3+d6+d9)) mod 10 == 0
aba_check(<<D1,D2,D3,D4,D5,D6,D7,D8,D9>>) ->
    Ds = [D1-48,D2-48,D3-48,D4-48,D5-48,D6-48,D7-48,D8-48,D9-48],
    lists:all(fun(D) -> D >= 0 andalso D =< 9 end, Ds) andalso
        begin
            [A,B,C,E,F,G,H,I,J] = Ds,
            (3*(A+E+H) + 7*(B+F+I) + (C+G+J)) rem 10 =:= 0
        end;
aba_check(_) -> false.

routing_check_digit(R) -> aba_check(R).

%% Assembly

assemble(Entries, Opts) ->
    Now = calendar:universal_time(),
    FileHdr = file_header(Opts, Now),
    {Batches, Ctrl} = batches(Entries, Opts, Now),
    FileCtl = file_control(Ctrl),
    Lines = [FileHdr | Batches] ++ [FileCtl],
    block(Lines).

file_header(Opts, {{Y,M,D},{H,Mi,_}}) ->
    Dest = maps:get(dest_routing, Opts, <<"000000000">>),
    Orig = maps:get(origin_routing, Opts, <<"000000000">>),
    DestName = maps:get(dest_name, Opts, <<"RECEIVING BANK">>),
    OrigName = maps:get(company_name, Opts, <<"TWINPAY">>),
    F = [$1, "01",
         blank9(Dest), blank9(Orig),
         yymmdd(Y,M,D), hhmm(H,Mi),
         $A, "094", "10", $1,
         pad_r(DestName, 23), pad_r(OrigName, 23),
         lists:duplicate(8, $\s)],
    flatten94(F).

batches(Entries, Opts, Now) ->
    %% Single batch for this builder.
    BatchNo = 1,
    Company = maps:get(company_name, Opts, <<"TWINPAY">>),
    CompanyId = maps:get(company_id, Opts, <<"TWINPAY01">>),
    Odfi = maps:get(origin_routing, Opts, <<"000000000">>),
    BH = batch_header(Company, CompanyId, Odfi, BatchNo, Now),
    {Details, Hash, CreditTotal, N} = details(Entries, Odfi, 1),
    BC = batch_control(CompanyId, Odfi, BatchNo, N, Hash, CreditTotal),
    Ctrl = #{batches => 1, entries => N, hash => Hash,
             debits => 0, credits => CreditTotal},
    {[BH | Details] ++ [BC], Ctrl}.

batch_header(Company, CompanyId, Odfi, BatchNo, {{Y,M,D},_}) ->
    %% 5 | svc(3) | company(16) | disc(20) | coid(10) | CCD | desc(10) |
    %% desc-date(6) | eff-date(6) | settle(3) | status(1) | odfi(8) | batch(7) = 94
    F = [$5, "225",
         pad_r(Company, 16), lists:duplicate(20, $\s),
         pad_r(CompanyId, 10), "CCD",
         pad_r(<<"REDEMPTION">>, 10),
         lists:duplicate(6, $\s), yymmdd(Y,M,D), lists:duplicate(3, $\s),
         $1, binary:part(Odfi, 0, 8), pad_n(BatchNo, 7)],
    flatten94(F).

details(Entries, Odfi, Seq0) ->
    {Lines, Hash, Cred, N, _} =
        lists:foldl(fun(E, {Ls, H, C, N0, S}) ->
            #{routing := R, account := A, amount_cents := Amt,
              name := Nm} = E,
            Trace = trace_no(Odfi, S),
            Line = entry_detail(R, A, Amt, Nm, Trace),
            {Ls ++ [Line], H + binary_to_integer(binary:part(R, 0, 8)),
             C + Amt, N0 + 1, S + 1}
        end, {[], 0, 0, 0, Seq0}, Entries),
    {Lines, Hash rem 10000000000, Cred, N}.

entry_detail(Routing, Acct, Cents, Name, Trace) ->
    <<R8:8/binary, _Check:1/binary>> = Routing,
    F = [$6, "22",
         R8, check_digit(Routing),
         pad_r(Acct, 17), pad_n(Cents, 10),
         pad_r(<<"TWINPAY">>, 15), pad_r(Name, 22),
         "  ", $0, Trace],
    flatten94(F).

check_digit(<<_:8/binary, C:1/binary>>) -> binary_to_list(C).

trace_no(Odfi, Seq) ->
    <<(binary:part(Odfi, 0, 8))/binary, (pad_n(Seq, 7))/binary>>.

batch_control(CompanyId, Odfi, BatchNo, Count, Hash, Credits) ->
    F = [$8, "225",
         pad_n(Count, 6), pad_n(Hash, 10),
         pad_n(0, 12), pad_n(Credits, 12),
         pad_r(CompanyId, 10), lists:duplicate(19, $\s),
         lists:duplicate(6, $\s),
         binary:part(Odfi, 0, 8), pad_n(BatchNo, 7)],
    flatten94(F).

file_control(#{batches := B, entries := E, hash := H, debits := D, credits := C}) ->
    F = [$9, pad_n(B, 6), pad_n(blocks_needed(B, E), 6),
         pad_n(E, 8), pad_n(H, 10),
         pad_n(D, 12), pad_n(C, 12),
         lists:duplicate(39, $\s)],
    flatten94(F).

blocks_needed(Batches, Entries) ->
    %% lines = 1 file hdr + batches*(2 + entries) + 1 file ctl
    Lines = 1 + Batches * (2 + Entries) + 1,
    (Lines + 9) div 10.

block(Lines) ->
    Padded = Lines ++ lists:duplicate((10 - (length(Lines) rem 10)) rem 10,
                                      lists:duplicate(94, $9)),
    list_to_binary([[L, $\n] || L <- Padded]).

%% Field helpers: every record flattens to exactly 94 chars.

flatten94(Fields) ->
    Bin = iolist_to_binary(Fields),
    case byte_size(Bin) of
        94 -> binary_to_list(Bin);
        N when N < 94 -> binary_to_list(<<Bin/binary, (binary:copy(<<" ">>, 94 - N))/binary>>);
        _ -> binary_to_list(binary:part(Bin, 0, 94))
    end.

pad_r(B, N) when is_binary(B) ->
    Sz = byte_size(B),
    if Sz >= N -> binary:part(B, 0, N);
       true -> [B, lists:duplicate(N - Sz, $\s)] end;
pad_r(L, N) when is_list(L) -> pad_r(list_to_binary(L), N).

pad_n(I, N) when is_integer(I) ->
    S = integer_to_binary(I),
    Sz = byte_size(S),
    if Sz >= N -> binary:part(S, Sz - N, N);
       true -> <<(binary:copy(<<"0">>, N - Sz))/binary, S/binary>>
    end.

blank9(<<R:9/binary>>) -> [$ , R].

yymmdd(Y, M, D) ->
    io_lib:format("~2..0B~2..0B~2..0B", [Y rem 100, M, D]).

hhmm(H, Mi) -> io_lib:format("~2..0B~2..0B", [H, Mi]).

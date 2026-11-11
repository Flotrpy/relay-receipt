%% Thin shim over OTP httpc. See docs/adr/0002-http-ffi.md.
%% All policy (retries, pacing, redaction, parsing) lives in Gleam.
-module(receipt_http_ffi).
-export([request/5]).

-spec request(get | post | head, binary(), [{binary(), binary()}], binary(), pos_integer()) ->
    {ok, {integer(), [{binary(), binary()}], binary(), [{integer(), binary()}],
          integer(), integer(), integer()}}
    | {error, {binary(), binary()}}.
request(Method, Url, Headers, Body, TimeoutMs) ->
    ensure_started(),
    Start = now_us(),
    Deadline = Start + TimeoutMs * 1000,
    Hdrs = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    Request =
        case Method of
            post ->
                ContentType = proplists:get_value("content-type", Hdrs, "application/json"),
                {binary_to_list(Url), proplists:delete("content-type", Hdrs), ContentType, Body};
            _ ->
                {binary_to_list(Url), Hdrs}
        end,
    HttpOptions = [
        {timeout, TimeoutMs},
        {connect_timeout, min(TimeoutMs, 15000)},
        {autoredirect, false},
        {ssl, ssl_options()}
    ],
    Options = [{sync, false}, {stream, self}, {body_format, binary}],
    try httpc:request(Method, Request, HttpOptions, Options) of
        {ok, RequestId} ->
            collect(RequestId, Start, Deadline, [], -1, -1, []);
        {error, Reason} ->
            {error, classify(Reason)}
    catch
        Class:Reason -> {error, {<<"other">>, format({Class, Reason})}}
    end.

collect(RequestId, Start, Deadline, Headers, HeadersUs, FirstByteUs, Chunks) ->
    WaitMs = max(0, (Deadline - now_us()) div 1000),
    receive
        {http, {RequestId, stream_start, ResponseHeaders}} ->
            collect(RequestId, Start, Deadline, convert_headers(ResponseHeaders),
                    now_us() - Start, FirstByteUs, Chunks);
        {http, {RequestId, stream, Data}} ->
            At = now_us() - Start,
            First = case FirstByteUs of -1 -> At; _ -> FirstByteUs end,
            collect(RequestId, Start, Deadline, Headers, HeadersUs, First,
                    [{At, Data} | Chunks]);
        {http, {RequestId, stream_end, _Trailers}} ->
            Ordered = lists:reverse(Chunks),
            Body = iolist_to_binary([Data || {_, Data} <- Ordered]),
            {ok, {200, Headers, Body, Ordered, HeadersUs, FirstByteUs, now_us() - Start}};
        {http, {RequestId, {{_Version, Status, _Phrase}, ResponseHeaders, Body}}} ->
            At = now_us() - Start,
            Whole = case Body of <<>> -> []; _ -> [{At, Body}] end,
            {ok, {Status, convert_headers(ResponseHeaders), Body, Whole, At, At, At}};
        {http, {RequestId, {error, Reason}}} ->
            {error, classify(Reason)}
    after WaitMs ->
        httpc:cancel_request(RequestId),
        flush(RequestId),
        {error, {<<"timeout">>, <<>>}}
    end.

flush(RequestId) ->
    receive
        {http, {RequestId, _}} -> flush(RequestId);
        {http, {RequestId, _, _}} -> flush(RequestId)
    after 0 -> ok
    end.

convert_headers(Headers) ->
    [{list_to_binary(string:lowercase(K)), unicode:characters_to_binary(V, latin1)}
     || {K, V} <- Headers].

classify(timeout) -> {<<"timeout">>, <<>>};
classify({failed_connect, Details} = Reason) ->
    case lists:flatten(io_lib:format("~0p", [Details])) of
        Text ->
            case string:find(Text, "tls_alert") of
                nomatch ->
                    case string:find(Text, "timeout") of
                        nomatch -> {<<"connect">>, format(Reason)};
                        _ -> {<<"timeout">>, <<>>}
                    end;
                _ -> {<<"tls">>, format(Reason)}
            end
    end;
classify(socket_closed_remotely) -> {<<"closed">>, <<"socket closed by peer">>};
classify({closed, _} = Reason) -> {<<"closed">>, format(Reason)};
classify(Reason) -> {<<"other">>, format(Reason)}.

format(Term) ->
    Text = unicode:characters_to_binary(io_lib:format("~0p", [Term])),
    case byte_size(Text) > 300 of
        true -> binary:part(Text, 0, 300);
        false -> Text
    end.

now_us() -> erlang:monotonic_time(microsecond).

ssl_options() ->
    Base = [
        {verify, verify_peer},
        {depth, 10},
        {customize_hostname_check,
         [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ],
    case os:getenv("SSL_CERT_FILE") of
        false -> [{cacerts, public_key:cacerts_get()} | Base];
        "" -> [{cacerts, public_key:cacerts_get()} | Base];
        File -> [{cacertfile, File} | Base]
    end.

ensure_started() ->
    case persistent_term:get(receipt_http_started, false) of
        true ->
            ok;
        false ->
            {ok, _} = application:ensure_all_started(inets),
            {ok, _} = application:ensure_all_started(ssl),
            configure_proxy(),
            persistent_term:put(receipt_http_started, true)
    end.

configure_proxy() ->
    case first_env(["HTTPS_PROXY", "https_proxy"]) of
        false ->
            ok;
        ProxyUrl ->
            case uri_string:parse(ProxyUrl) of
                #{host := Host} = Parsed ->
                    Port = maps:get(port, Parsed, 8080),
                    NoProxy =
                        case first_env(["NO_PROXY", "no_proxy"]) of
                            false -> [];
                            Value -> string:lexemes(Value, ", ")
                        end,
                    httpc:set_options([{https_proxy, {{Host, Port}, NoProxy}}]),
                    ok;
                _ ->
                    ok
            end
    end.

first_env([]) -> false;
first_env([Name | Rest]) ->
    case os:getenv(Name) of
        false -> first_env(Rest);
        "" -> first_env(Rest);
        Value -> Value
    end.

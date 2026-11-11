%% DNS records and TLS certificate summary. See docs/adr/0003-dns-tls-ffi.md.
-module(receipt_net_ffi).
-export([dns/1, tls_certificate/3]).

-include_lib("public_key/include/public_key.hrl").

-spec dns(binary()) -> [{binary(), binary()}].
dns(Host) ->
    Name = binary_to_list(Host),
    Records = lists:flatmap(fun(Type) -> lookup(Name, Type) end, [a, aaaa, cname, ns]),
    case Records of
        [] -> system_lookup(Name);
        _ -> Records
    end.

lookup(Name, Type) ->
    try inet_res:lookup(Name, in, Type, [{timeout, 3000}, {retry, 1}]) of
        Answers -> [{type_name(Type), format_answer(Answer)} || Answer <- Answers]
    catch
        _:_ -> []
    end.

system_lookup(Name) ->
    case inet:getaddrs(Name, inet) of
        {ok, Addresses} -> [{<<"A">>, format_answer(Address)} || Address <- Addresses];
        _ -> []
    end.

type_name(a) -> <<"A">>;
type_name(aaaa) -> <<"AAAA">>;
type_name(cname) -> <<"CNAME">>;
type_name(ns) -> <<"NS">>.

format_answer(Address) when is_tuple(Address) ->
    list_to_binary(inet:ntoa(Address));
format_answer(Name) when is_list(Name) ->
    list_to_binary(Name);
format_answer(Other) ->
    unicode:characters_to_binary(io_lib:format("~0p", [Other])).

-spec tls_certificate(binary(), integer(), integer()) ->
    {ok, {binary(), binary(), binary(), binary()}} | {error, binary()}.
tls_certificate(Host, Port, TimeoutMs) ->
    {ok, _} = application:ensure_all_started(ssl),
    Name = binary_to_list(Host),
    Options = [
        {verify, verify_peer},
        {depth, 10},
        {server_name_indication, Name},
        {customize_hostname_check,
         [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
        | trust_options()
    ],
    try ssl:connect(Name, Port, Options, TimeoutMs) of
        {ok, Socket} ->
            Result =
                case ssl:peercert(Socket) of
                    {ok, Der} -> summarise(Der);
                    {error, Reason} -> {error, format(Reason)}
                end,
            ssl:close(Socket),
            Result;
        {error, Reason} ->
            {error, format(Reason)}
    catch
        Class:Reason -> {error, format({Class, Reason})}
    end.

trust_options() ->
    case os:getenv("SSL_CERT_FILE") of
        false -> [{cacerts, public_key:cacerts_get()}];
        "" -> [{cacerts, public_key:cacerts_get()}];
        File -> [{cacertfile, File}]
    end.

summarise(Der) ->
    try
        #'OTPCertificate'{tbsCertificate = Tbs} = public_key:pkix_decode_cert(Der, otp),
        #'OTPTBSCertificate'{subject = Subject, issuer = Issuer, validity = Validity} = Tbs,
        #'Validity'{notBefore = NotBefore, notAfter = NotAfter} = Validity,
        {ok, {format_name(Subject), format_name(Issuer),
              format_time(NotBefore), format_time(NotAfter)}}
    catch
        _:Reason -> {error, format(Reason)}
    end.

format_name({rdnSequence, Sets}) ->
    Parts = [format_attribute(Attribute) || Set <- Sets, Attribute <- Set],
    unicode:characters_to_binary(lists:join(", ", Parts));
format_name(Other) ->
    format(Other).

format_attribute(#'AttributeTypeAndValue'{type = Type, value = Value}) ->
    [attribute_label(Type), "=", attribute_text(Value)].

attribute_label(?'id-at-commonName') -> "CN";
attribute_label(?'id-at-organizationName') -> "O";
attribute_label(?'id-at-organizationalUnitName') -> "OU";
attribute_label(?'id-at-countryName') -> "C";
attribute_label(?'id-at-localityName') -> "L";
attribute_label(?'id-at-stateOrProvinceName') -> "ST";
attribute_label(Oid) when is_tuple(Oid) ->
    lists:join(".", [integer_to_list(Part) || Part <- tuple_to_list(Oid)]);
attribute_label(_) -> "?".

attribute_text({_Kind, Text}) when is_list(Text); is_binary(Text) -> Text;
attribute_text(Text) when is_list(Text); is_binary(Text) -> Text;
attribute_text(Other) -> io_lib:format("~0p", [Other]).

format_time({_Kind, Text}) when is_list(Text) -> list_to_binary(Text);
format_time(Other) -> format(Other).

format(Term) ->
    Text = unicode:characters_to_binary(io_lib:format("~0p", [Term])),
    case byte_size(Text) > 300 of
        true -> binary:part(Text, 0, 300);
        false -> Text
    end.

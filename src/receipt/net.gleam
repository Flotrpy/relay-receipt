//// DNS and TLS lookups, as text. A typed front for the Erlang shim of
//// `docs/adr/0003-dns-tls-ffi.md`.

import gleam/list
import gleam/string

@external(erlang, "receipt_net_ffi", "dns")
fn ffi_dns(host: String) -> List(#(String, String))

@external(erlang, "receipt_net_ffi", "tls_certificate")
fn ffi_tls_certificate(
  host: String,
  port: Int,
  timeout_ms: Int,
) -> Result(#(String, String, String, String), String)

/// Text reported when a host has no DNS records.
pub const no_records = "no records found"

/// The DNS records of a host, one `TYPE value` per line.
pub fn dns_text(host: String) -> String {
  case ffi_dns(host) {
    [] -> no_records
    records ->
      records
      |> list.map(fn(record) { record.0 <> " " <> record.1 })
      |> string.join("\n")
  }
}

/// A summary of the certificate a host presents, one field per line, or a
/// line starting with `error:`.
pub fn tls_text(host: String, port: Int) -> String {
  case ffi_tls_certificate(host, port, 8000) {
    Ok(#(subject, issuer, not_before, not_after)) ->
      string.join(
        [
          "subject " <> subject,
          "issuer " <> issuer,
          "not_before " <> not_before,
          "not_after " <> not_after,
        ],
        "\n",
      )
    Error(detail) -> "error: " <> detail
  }
}

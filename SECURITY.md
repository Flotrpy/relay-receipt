# Security policy

## Reporting a vulnerability in Receipt

If you find a security problem in Receipt itself (for example a way for a
relay to make Receipt leak an API key, write outside its output path, or
run code), please report it privately through GitHub's "Report a
vulnerability" form on this repository. Do not open a public issue.

Please include the Receipt version, the command you ran (with keys
removed), and, if possible, a trace recorded with `--record`. Traces are
redacted automatically, but review one before sending it.

You can expect an acknowledgement within a week. Fixes are released as
soon as they are ready, and the report is credited unless you ask
otherwise.

## Handling of API keys

- Keys are read only from environment variables. There is no
  command-line option that accepts a key, so keys never appear in process
  listings or shell history through Receipt.
- Keys are held in an opaque value and are revealed only when a request
  header is built.
- Every trace line and every report passes through redaction: the key and
  any fragment of it of 8 or more characters are replaced with a stand-in
  of the same length. There is no option to turn this off.
- Error-response evidence shown in reports (Step 9) is redacted the same
  way.

## Findings about relays

Receipt reports signals, anomalies and inconclusive results about the
endpoints it audits. It does not prove wrongdoing.

- Do not publish a Receipt finding that names a real provider without
  first contacting that provider and giving them reasonable time to
  respond.
- Do not publish raw reports or traces. They can contain private relay
  URLs, model output and text returned in error messages.
- Audit only endpoints you are a customer of, with your own key, at
  request rates their terms allow.

Results in this repository's documentation that come from real services
are anonymised unless the provider has been told and the maintainer has
agreed to name them.

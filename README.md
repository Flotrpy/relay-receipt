# Receipt

Receipt is a local security auditor for AI API relays: the resellers,
gateways and proxies that sell access to large language models.

It sends a fixed set of probes to an endpoint you choose and writes a report
of what it observed. A report contains signals, anomalies and inconclusive
results. It is not a safety certificate.

> Status: design phase. The design documents under [`docs/`](./docs) are
> written before any code, and the thresholds in
> [`docs/THRESHOLDS.md`](./docs/THRESHOLDS.md) are fixed before any real
> endpoint is tested. This README is replaced with full usage documentation
> once the tool is built.

## License

AGPL-3.0-only. See [LICENSE](./LICENSE).

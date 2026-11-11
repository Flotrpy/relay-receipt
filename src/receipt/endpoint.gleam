//// An endpoint under audit, or one it is compared with.

import receipt/api/types.{type ApiFormat}
import receipt/secret.{type Secret}

pub type Endpoint {
  Endpoint(
    /// `target`, `reference`, or a user-given name.
    name: String,
    base_url: String,
    model: String,
    key: Secret,
    format: ApiFormat,
  )
}

/// The same endpoint speaking another API format, as detected by Step 2.
pub fn with_format(endpoint: Endpoint, format: ApiFormat) -> Endpoint {
  Endpoint(..endpoint, format: format)
}

import gleam/string
import receipt/version
import simplifile

pub fn version_matches_gleam_toml_test() {
  let assert Ok(toml) = simplifile.read("gleam.toml")
  assert string.contains(toml, "version = \"" <> version.version <> "\"")
}

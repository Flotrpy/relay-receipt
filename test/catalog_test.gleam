import gleam/list
import gleam/string
import receipt/catalog
import receipt/verdict.{
  AdvisoryClass, CriticalClass, InformationalClass, MajorClass,
}

pub fn catalog_has_seventeen_steps_in_order_test() {
  assert list.map(catalog.all(), fn(info) { info.id })
    == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
}

pub fn keys_are_unique_snake_case_test() {
  let keys = list.map(catalog.all(), fn(info) { info.key })
  assert list.unique(keys) == keys
  list.each(keys, fn(key) {
    assert string.lowercase(key) == key
    assert !string.contains(key, " ")
    assert !string.contains(key, "-")
  })
}

pub fn classes_match_thresholds_document_test() {
  let ids_of = fn(class) {
    catalog.all()
    |> list.filter(fn(info) { info.class == class })
    |> list.map(fn(info) { info.id })
  }
  assert ids_of(CriticalClass) == [8, 9, 10]
  assert ids_of(MajorClass) == [3, 4, 5, 7, 15, 17]
  assert ids_of(AdvisoryClass) == [6]
  assert ids_of(InformationalClass) == [1, 2, 11, 12, 13, 14, 16]
}

pub fn only_upstream_map_is_full_only_test() {
  assert catalog.all()
    |> list.filter(fn(info) { info.full_only })
    |> list.map(fn(info) { info.id })
    == [16]
}

pub fn rated_steps_are_critical_or_major_test() {
  assert catalog.is_rated(8)
  assert catalog.is_rated(17)
  assert !catalog.is_rated(6)
  assert !catalog.is_rated(16)
  assert !catalog.is_rated(99)
}

pub fn new_steps_cite_their_papers_test() {
  let assert Ok(inflation) = catalog.find(15)
  assert list.contains(inflation.references, "arXiv:2609.20370")
  let assert Ok(map) = catalog.find(16)
  assert map.references == ["arXiv:2608.20732"]
  let assert Ok(identity) = catalog.find(17)
  assert list.contains(identity.references, "arXiv:2609.00052")
  assert list.contains(identity.references, "arXiv:2506.06975")
}

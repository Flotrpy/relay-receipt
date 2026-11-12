import gleam/json
import gleam/list
import gleam/string
import receipt/probes/tool_templates.{Template} as templates
import receipt/thresholds

pub fn there_are_exactly_twenty_templates_test() {
  assert list.length(templates.all()) == thresholds.identity_templates
}

pub fn template_ids_are_unique_test() {
  let ids = list.map(templates.all(), fn(t) { t.id })
  assert list.unique(ids) == ids
}

pub fn every_template_offers_four_distinct_names_test() {
  list.each(templates.all(), fn(template) {
    assert list.length(template.names) == 4
    assert list.unique(template.names) == template.names
  })
}

pub fn tool_names_are_unique_across_templates_test() {
  let names = list.flat_map(templates.all(), fn(t) { t.names })
  assert list.unique(names) == names
}

pub fn each_template_mixes_naming_conventions_test() {
  list.each(templates.all(), fn(template) {
    assert list.any(template.names, string.starts_with(_, "mcp__"))
    assert list.any(template.names, fn(name) { string.lowercase(name) != name })
    assert list.any(template.names, fn(name) {
      string.contains(name, "_") && !string.starts_with(name, "mcp__")
    })
  })
}

pub fn requests_do_not_name_any_offered_tool_test() {
  list.each(templates.all(), fn(template) {
    let request = string.lowercase(template.request)
    list.each(template.names, fn(name) {
      assert !string.contains(request, string.lowercase(name))
    })
  })
}

pub fn tools_in_a_template_differ_only_by_name_test() {
  let assert [template, ..] = templates.all()
  let tools = templates.tools(template, template.names)
  let descriptions = list.map(tools, fn(tool) { tool.description })
  let schemas = list.map(tools, fn(tool) { json.to_string(tool.parameters) })
  assert list.unique(descriptions) |> list.length == 1
  assert list.unique(schemas) |> list.length == 1
  assert list.map(tools, fn(tool) { tool.name }) == template.names
}

pub fn tools_follow_the_requested_order_test() {
  let assert [template, ..] = templates.all()
  let reversed = list.reverse(template.names)
  assert list.map(templates.tools(template, reversed), fn(tool) { tool.name })
    == reversed
}

pub fn classification_covers_every_outcome_test() {
  let template = Template("x", "do it", ["a_tool", "b_tool"], "d", ["p"])
  assert templates.classify(template, []) == "_no_call"
  assert templates.classify(template, [#("b_tool", True)]) == "b_tool"
  assert templates.classify(template, [#("b_tool", False)]) == "_malformed"
  assert templates.classify(template, [#("unknown_tool", True)]) == "_other"
  // Only the first call is classified.
  assert templates.classify(template, [#("a_tool", True), #("b_tool", True)])
    == "a_tool"
}

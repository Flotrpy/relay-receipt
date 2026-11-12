//// Step 17: Identity test.
////
//// Tests whether the endpoint and a trusted reference serving the same
//// model respond alike, with two components run in batches: tool-choice
//// distributions (AgentProv, arXiv:2609.00052) and rank uniformity of
//// short completions (arXiv:2506.06975, black-box variant). Evidence
//// accumulates as e-values and the step stops as soon as it reaches 20.
//// Implemented as specified in `docs/steps/17-identity.md`.

import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import receipt/api/types as api
import receipt/config.{Full, General}
import receipt/ctx.{type Ctx}
import receipt/endpoint.{type Endpoint}
import receipt/identity/sequential.{
  type BatchResult, type Progress, type TextSamples, type ToolSamples, Different,
  InsufficientData, Same, TextSamples, ToolSamples,
}
import receipt/jsonx
import receipt/prng.{type Prng}
import receipt/probes/everyday
import receipt/probes/tool_templates.{type Template}
import receipt/report/block.{Paragraph, Table}
import receipt/seq
import receipt/stats/holm
import receipt/stats/mmd
import receipt/step.{type StepResult}
import receipt/thresholds
import receipt/verdict.{Anomaly, Clean}

const id = 17

fn tool_sample(
  ctx: Ctx,
  endpoint: Endpoint,
  template: Template,
  order: List(String),
  label: String,
) -> Option(String) {
  let params =
    api.simple(
      endpoint.model,
      template.request,
      thresholds.identity_tool_max_tokens,
    )
    |> api.with_temperature(thresholds.identity_tool_temperature)
    |> api.with_tools(tool_templates.tools(template, order))
  case ctx.rate_limited_out(ctx, endpoint) {
    True -> None
    False ->
      case ctx.chat(ctx, endpoint, id, label, params) {
        Error(_) -> None
        Ok(completion) ->
          Some(tool_templates.classify(
            template,
            list.map(completion.tool_calls, fn(call) {
              #(
                call.name,
                call.name != ""
                  && {
                  call.arguments == ""
                  || json.parse(call.arguments, jsonx.any()) |> is_ok
                },
              )
            }),
          ))
      }
  }
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Collect component A's samples for one batch. Sample `j` of a template
/// uses the same shuffled tool order on both endpoints.
fn collect_tools(
  ctx: Ctx,
  reference: Endpoint,
  batch: Int,
  prng: Prng,
) -> #(List(ToolSamples), Prng) {
  tool_templates.all()
  |> list.fold(#([], prng), fn(acc, template) {
    let #(done, prng) = acc
    let #(orders, prng) =
      seq.range(1, thresholds.identity_samples_per_batch)
      |> list.fold(#([], prng), fn(inner, _) {
        let #(orders, prng) = inner
        let #(order, prng) = prng.shuffle(template.names, prng)
        #([order, ..orders], prng)
      })
    let sample = fn(endpoint: Endpoint) {
      list.index_map(orders, fn(order, index) {
        tool_sample(
          ctx,
          endpoint,
          template,
          order,
          "tools/b"
            <> int.to_string(batch)
            <> "/"
            <> template.id
            <> "/"
            <> int.to_string(index + 1),
        )
      })
    }
    #(
      [ToolSamples(template.id, sample(reference), sample(ctx.target)), ..done],
      prng,
    )
  })
  |> fn(pair) { #(list.reverse(pair.0), pair.1) }
}

fn text_sample(
  ctx: Ctx,
  endpoint: Endpoint,
  prompt: String,
  label: String,
) -> Option(String) {
  let params =
    api.simple(endpoint.model, prompt, thresholds.identity_text_max_tokens)
    |> api.with_temperature(thresholds.identity_text_temperature)
  case ctx.rate_limited_out(ctx, endpoint) {
    True -> None
    False ->
      case ctx.chat(ctx, endpoint, id, label, params) {
        Ok(completion) -> Some(completion.text)
        Error(_) -> None
      }
  }
}

fn collect_text(
  ctx: Ctx,
  reference: Endpoint,
  batch: Int,
) -> List(TextSamples) {
  everyday.pool()
  |> list.drop({ batch - 1 } * thresholds.identity_prompts_per_batch)
  |> list.take(thresholds.identity_prompts_per_batch)
  |> list.index_map(fn(prompt, index) {
    let label =
      "text/b" <> int.to_string(batch) <> "/" <> int.to_string(index + 1)
    TextSamples(
      target: text_sample(ctx, ctx.target, prompt, label),
      references: seq.range(1, thresholds.identity_reference_samples)
        |> list.map(fn(_) { text_sample(ctx, reference, prompt, label) }),
    )
  })
}

pub type Run {
  Run(
    progress: Progress,
    /// Every tool sample collected, for the per-template table.
    tool_samples: List(ToolSamples),
    max_batches: Int,
  )
}

pub fn run(ctx: Ctx) -> StepResult {
  case ctx.reference {
    None -> step.not_run(id, verdict.NotApplicable, "no_reference")
    Some(reference) -> {
      let max_batches = case ctx.profile {
        General -> thresholds.identity_batches_general
        Full -> thresholds.identity_batches_full
      }
      let finished =
        batches(
          ctx,
          reference,
          1,
          max_batches,
          ctx.prng(ctx, id),
          Run(sequential.start(), [], max_batches),
        )
      build(finished, ctx.prng(ctx, id + 1000))
    }
  }
}

fn batches(
  ctx: Ctx,
  reference: Endpoint,
  batch: Int,
  max_batches: Int,
  prng: Prng,
  so_far: Run,
) -> Run {
  case batch > max_batches || sequential.rejects(so_far.progress) {
    True -> so_far
    False -> {
      ctx.progress(
        "  batch "
        <> int.to_string(batch)
        <> " of at most "
        <> int.to_string(max_batches),
      )
      let #(tools, prng) = collect_tools(ctx, reference, batch, prng)
      let text = collect_text(ctx, reference, batch)
      let #(tool_result, prng) =
        sequential.evaluate_tools(tools, thresholds.identity_permutations, prng)
      let #(text_result, prng) =
        sequential.evaluate_text(text, thresholds.identity_permutations, prng)
      batches(
        ctx,
        reference,
        batch + 1,
        max_batches,
        prng,
        Run(
          sequential.add(so_far.progress, tool_result, text_result),
          list.append(so_far.tool_samples, tools),
          max_batches,
        ),
      )
    }
  }
}

fn show(value: Float) -> String {
  float.to_string(float.to_precision(value, 3))
}

fn batch_cell(batch: BatchResult) -> String {
  case batch.valid, batch.p_value {
    True, Some(p) -> "p = " <> show(p) <> ", e = " <> show(batch.e_value)
    _, _ -> "not valid (e = 1)"
  }
}

/// Pool the samples of each template over all batches.
fn pooled(samples: List(ToolSamples)) -> List(#(String, mmd.Template)) {
  list.map(tool_templates.all(), fn(template) {
    let mine = list.filter(samples, fn(s) { s.template == template.id })
    #(
      template.id,
      mmd.Template(
        option.values(list.flat_map(mine, fn(s) { s.reference })),
        option.values(list.flat_map(mine, fn(s) { s.target })),
      ),
    )
  })
}

pub fn build(finished: Run, prng: Prng) -> StepResult {
  let progress = finished.progress
  let outcome = sequential.conclude(progress)
  let evidence = sequential.evidence(progress)
  let batch_count = list.length(progress.tool_batches)
  let samples_per_template = batch_count * thresholds.identity_samples_per_batch
  let per_template = pooled(finished.tool_samples)
  // Per-template diagnostics: descriptive only, Holm-adjusted.
  let #(raw, _) =
    list.fold(per_template, #([], prng), fn(acc, entry) {
      let #(done, prng) = acc
      let #(p, prng) = mmd.template_p_value(entry.1, 999, prng)
      #([p, ..done], prng)
    })
  let adjusted = holm.adjust(list.reverse(raw))
  let template_rows =
    list.zip(per_template, adjusted)
    |> list.map(fn(pair) {
      let #(#(name, template), p) = pair
      #(name, mmd.template_distance(template), p)
    })
    |> list.sort(fn(a, b) { float.compare(b.1, a.1) })
  let decorate = fn(result: StepResult) {
    result
    |> step.with_data(
      "outcome",
      json.string(sequential.outcome_to_string(outcome)),
    )
    |> step.with_data("e_value", json.float(evidence))
    |> step.with_data(
      "e_tool_choice",
      json.float(sequential.tool_evidence(progress)),
    )
    |> step.with_data(
      "e_rank_uniformity",
      json.float(sequential.text_evidence(progress)),
    )
    |> step.with_data("threshold", json.float(thresholds.identity_reject_at))
    |> step.with_data(
      "batches",
      json.array(
        list.zip(progress.tool_batches, progress.text_batches),
        fn(pair) {
          let one = fn(batch: BatchResult) {
            json.object([
              #("valid", json.bool(batch.valid)),
              #("p_value", json.nullable(batch.p_value, json.float)),
              #("e_value", json.float(batch.e_value)),
            ])
          }
          json.object([
            #("tool_choice", one(pair.0)),
            #("rank_uniformity", one(pair.1)),
          ])
        },
      ),
    )
    |> step.with_data(
      "templates",
      json.array(template_rows, fn(row) {
        json.object([
          #("template", json.string(row.0)),
          #("distance", json.float(float.to_precision(row.1, 4))),
          #("holm_p", json.float(float.to_precision(row.2, 4))),
        ])
      }),
    )
    |> step.with_details(
      list.flatten([
        [
          Table(
            ["Batch", "Tool choice (A)", "Rank uniformity (B)"],
            list.zip(progress.tool_batches, progress.text_batches)
              |> list.index_map(fn(pair, index) {
                [
                  int.to_string(index + 1),
                  batch_cell(pair.0),
                  batch_cell(pair.1),
                ]
              }),
          ),
          Paragraph(
            "Combined evidence E = "
            <> show(evidence)
            <> " (A: "
            <> show(sequential.tool_evidence(progress))
            <> ", B: "
            <> show(sequential.text_evidence(progress))
            <> "); 'different' needs E >= 20.",
          ),
        ],
        case outcome {
          Different -> [
            Paragraph(
              "Templates by distance between the two tool-choice distributions (diagnostic only; p-values are Holm-adjusted):",
            ),
            Table(
              ["Template", "Distance", "Adjusted p"],
              list.take(template_rows, 8)
                |> list.map(fn(row) { [row.0, show(row.1), show(row.2)] }),
            ),
          ]
          _ -> []
        },
      ]),
    )
  }
  case outcome {
    Different ->
      step.ran(
        id,
        Anomaly,
        "different: the endpoint's responses differ from the trusted reference's on these probes (E = "
          <> show(evidence)
          <> " after "
          <> int.to_string(batch_count)
          <> " batch(es)).",
      )
      |> step.with_error_rate(step.ErrorRate(
        "false_positive",
        thresholds.alpha,
        "anytime-valid: the probability of reaching E >= 20 when both serve the same distribution is at most 5%, whenever the test stops",
      ))
      |> step.with_finding(
        step.Signal,
        "A difference does not say why: another model, a quantized build, other sampling settings or a hidden system prompt all change behaviour. Check Step 3 for an added prompt.",
      )
      |> decorate
    Same ->
      step.ran(
        id,
        Clean,
        "same: not distinguished from the trusted reference after "
          <> int.to_string(batch_count)
          <> " batch(es) (E = "
          <> show(evidence)
          <> ").",
      )
      |> step.with_error_rate(step.ErrorRate(
        "miss",
        1.0,
        "not bounded in general; for outright substitution arXiv:2609.00052 reports detection of 94.13% at 10 and 99.84% at 25 samples per template for the tool-choice component (this run: "
          <> int.to_string(samples_per_template)
          <> " per template). These are the paper's figures, not measurements of this run",
      ))
      |> step.with_finding(
        step.Limit,
        "'same' means not distinguished at this budget. It is not a demonstration that the two are identical.",
      )
      |> decorate
    InsufficientData ->
      step.inconclusive(
        id,
        "insufficient_data",
        "insufficient data: too few valid batches to decide (E = "
          <> show(evidence)
          <> ").",
      )
      |> step.with_finding(
        step.Note,
        string.concat([
          "Valid batches: tool choice ",
          int.to_string(
            list.count(progress.tool_batches, fn(batch) { batch.valid }),
          ),
          ", rank uniformity ",
          int.to_string(
            list.count(progress.text_batches, fn(batch) { batch.valid }),
          ),
          ". An endpoint that rejects tool definitions leaves component A without data.",
        ]),
      )
      |> decorate
  }
}

//// Build per-step confusion matrices from Receipt's JSON reports.
////
//// Usage: gleam run -m evilrelay/matrix -- <results-dir> <output.md>
////
//// A report's file name gives its condition: `<matrix>-<condition>.json`.
//// Condition `none` and every `c-*` control are honest. A fault counts
//// as a positive only for the steps designed to catch it; an anomaly
//// raised by another step under a fault is shown in the grid but is not
//// counted as a false positive, because the relay really is dishonest.
//// Inconclusive results are counted on their own and never as clean.

import argv
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

/// The steps each fault is aimed at.
pub fn targets(condition: String) -> List(Int) {
  case condition {
    "inject" -> [3, 4, 5, 6]
    "pad" -> [15]
    "swap" -> [17]
    "rewrite" -> [8]
    _ -> []
  }
}

pub fn is_honest(name: String) -> Bool {
  string.ends_with(name, "-none") || string.starts_with(name, "c-")
}

pub type Report {
  Report(name: String, condition: String, steps: Dict(Int, #(String, String)))
}

fn steps_decoder() -> decode.Decoder(List(#(Int, String, String))) {
  decode.at(
    ["steps"],
    decode.list({
      use id <- decode.field("id", decode.int)
      use status <- decode.field("status", decode.string)
      use verdict <- decode.field("verdict", decode.string)
      decode.success(#(id, status, verdict))
    }),
  )
}

pub fn parse(name: String, text: String) -> Result(Report, Nil) {
  case json.parse(text, steps_decoder()) {
    Error(_) -> Error(Nil)
    Ok(steps) -> {
      let condition = case string.split_once(name, "-") {
        Ok(#(_, rest)) -> rest
        Error(Nil) -> name
      }
      Ok(Report(
        name,
        condition,
        list.fold(steps, dict.new(), fn(found, step) {
          dict.insert(found, step.0, #(step.1, step.2))
        }),
      ))
    }
  }
}

pub type Cells {
  Cells(
    tp: Int,
    fn_: Int,
    fault_inconclusive: Int,
    fp: Int,
    tn: Int,
    honest_inconclusive: Int,
  )
}

/// The confusion cells of one step over a set of reports.
pub fn cells(reports: List(Report), step: Int) -> Cells {
  list.fold(reports, Cells(0, 0, 0, 0, 0, 0), fn(acc, report) {
    case dict.get(report.steps, step) {
      Ok(#("run", verdict)) -> {
        let aimed = list.contains(targets(report.condition), step)
        let honest = is_honest(report.name)
        case aimed, honest, verdict {
          True, _, "anomaly" -> Cells(..acc, tp: acc.tp + 1)
          True, _, "clean" -> Cells(..acc, fn_: acc.fn_ + 1)
          True, _, _ ->
            Cells(..acc, fault_inconclusive: acc.fault_inconclusive + 1)
          False, True, "anomaly" -> Cells(..acc, fp: acc.fp + 1)
          False, True, "clean" -> Cells(..acc, tn: acc.tn + 1)
          False, True, "inconclusive" ->
            Cells(..acc, honest_inconclusive: acc.honest_inconclusive + 1)
          _, _, _ -> acc
        }
      }
      _ -> acc
    }
  })
}

fn row(cells: List(String)) -> String {
  "| " <> string.join(cells, " | ") <> " |"
}

fn short(status_verdict: Result(#(String, String), Nil)) -> String {
  case status_verdict {
    Ok(#("run", "anomaly")) -> "**anomaly**"
    Ok(#("run", verdict)) -> verdict
    Ok(#(_, _)) -> "-"
    Error(Nil) -> "-"
  }
}

/// The Markdown tables: a grid of verdicts, then confusion cells per step.
pub fn render(reports: List(Report)) -> String {
  let steps =
    list.flat_map(reports, fn(report) {
      dict.to_list(report.steps)
      |> list.filter(fn(pair) { pair.1.0 == "run" })
      |> list.map(fn(pair) { pair.0 })
    })
    |> list.unique
    |> list.sort(int.compare)
  let grid =
    [
      row([
        "Condition",
        ..list.map(steps, fn(s) { "Step " <> int.to_string(s) })
      ]),
      row(list.repeat("---", list.length(steps) + 1)),
      ..list.map(reports, fn(report) {
        row([
          report.name,
          ..list.map(steps, fn(step) { short(dict.get(report.steps, step)) })
        ])
      })
    ]
    |> string.join("\n")
  let confusion =
    [
      row([
        "Step", "TP", "FN", "Inconclusive (fault)", "FP", "TN",
        "Inconclusive (honest)",
      ]),
      row(list.repeat("---", 7)),
      ..list.map(steps, fn(step) {
        let c = cells(reports, step)
        row([
          int.to_string(step),
          int.to_string(c.tp),
          int.to_string(c.fn_),
          int.to_string(c.fault_inconclusive),
          int.to_string(c.fp),
          int.to_string(c.tn),
          int.to_string(c.honest_inconclusive),
        ])
      })
    ]
    |> string.join("\n")
  grid <> "\n\n" <> confusion <> "\n"
}

pub fn main() -> Nil {
  case argv.load().arguments {
    [dir, output] -> {
      let reports =
        simplifile.read_directory(dir)
        |> result.unwrap([])
        |> list.filter(string.ends_with(_, ".json"))
        |> list.sort(string.compare)
        |> list.filter_map(fn(file) {
          use text <- result.try(
            simplifile.read(dir <> "/" <> file) |> result.replace_error(Nil),
          )
          parse(string.drop_end(file, 5), text)
        })
      case simplifile.write(output, render(reports)) {
        Ok(Nil) -> io.println("wrote " <> output)
        Error(_) -> io.println_error("cannot write " <> output)
      }
    }
    _ ->
      io.println_error("usage: gleam run -m evilrelay/matrix -- <dir> <out.md>")
  }
}

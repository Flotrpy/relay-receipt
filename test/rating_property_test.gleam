import gleam/list
import qcheck
import receipt/rating
import receipt/step.{type StepResult}
import receipt/verdict.{
  type Risk, Anomaly, Clean, HighRisk, Inconclusive, Informational, Low,
  MediumRisk,
}

fn rank(risk: Risk) -> Int {
  case risk {
    Low -> 0
    MediumRisk -> 1
    HighRisk -> 2
  }
}

fn result_generator() -> qcheck.Generator(StepResult) {
  qcheck.map2(
    qcheck.bounded_int(1, 17),
    qcheck.bounded_int(0, 3),
    fn(id, which) {
      case which {
        0 -> step.ran(id, Clean, "x")
        1 -> step.ran(id, Anomaly, "x")
        2 -> step.ran(id, Inconclusive, "x")
        _ -> step.ran(id, Informational, "x")
      }
    },
  )
}

fn run_generator() -> qcheck.Generator(List(StepResult)) {
  qcheck.generic_list(result_generator(), qcheck.bounded_int(0, 12))
}

pub fn adding_an_anomaly_never_lowers_the_rating_test() {
  use #(results, id) <- qcheck.given(qcheck.tuple2(
    run_generator(),
    qcheck.bounded_int(1, 17),
  ))
  let before = rating.rate(results).risk
  let after = rating.rate([step.ran(id, Anomaly, "x"), ..results]).risk
  assert rank(after) >= rank(before)
}

pub fn rating_does_not_depend_on_step_order_test() {
  use results <- qcheck.given(run_generator())
  assert rating.rate(results).risk == rating.rate(list.reverse(results)).risk
}

pub fn low_implies_no_rated_step_is_undecided_or_anomalous_test() {
  use results <- qcheck.given(run_generator())
  case rating.rate(results).risk {
    Low ->
      list.each(results, fn(r) {
        let rated = list.contains([3, 4, 5, 7, 8, 9, 10, 15, 17], r.id)
        assert !{
          rated && { r.verdict == Anomaly || r.verdict == Inconclusive }
        }
      })
    _ -> Nil
  }
}

pub fn every_non_low_rating_has_a_reason_test() {
  use results <- qcheck.given(run_generator())
  let rated = rating.rate(results)
  case rated.risk {
    Low -> Nil
    _ -> {
      assert rated.reasons != []
    }
  }
}

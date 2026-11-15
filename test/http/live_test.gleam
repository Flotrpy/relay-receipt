import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import receipt/http/live
import receipt/http/types.{Connect, Get, Post, Request, Timeout}
import support/server

fn get(path: String) {
  Request(Get, server.base_url() <> path, [], "", 5000)
}

pub fn get_returns_status_headers_and_body_test() {
  server.ensure_started()
  let assert Ok(response) = live.send(get("/json"))
  assert response.status == 200
  assert types.body_text(response) == "{\"ok\":true}"
  assert types.header(response.headers, "content-type")
    == Ok("application/json")
}

pub fn non_2xx_status_is_a_response_not_an_error_test() {
  server.ensure_started()
  let assert Ok(response) = live.send(get("/status/429"))
  assert response.status == 429
  assert string.contains(types.body_text(response), "status 429")
  let assert Ok(missing) = live.send(get("/nope"))
  assert missing.status == 404
}

pub fn post_sends_body_and_headers_test() {
  server.ensure_started()
  let request =
    Request(
      Post,
      server.base_url() <> "/echo",
      [
        #("content-type", "application/json"),
        #("authorization", "Bearer test-token"),
        #("x-custom", "abc"),
      ],
      "{\"hello\":\"wörld\"}",
      5000,
    )
  let assert Ok(response) = live.send(request)
  let text = types.body_text(response)
  assert string.contains(text, "authorization=Bearer test-token")
  assert string.contains(text, "x-custom=abc")
  assert string.contains(text, "content-type=application/json")
  assert string.ends_with(text, "{\"hello\":\"wörld\"}")
}

pub fn deliberately_broken_body_is_sent_verbatim_test() {
  server.ensure_started()
  let request =
    Request(
      Post,
      server.base_url() <> "/echo",
      [#("content-type", "text/plain")],
      "{not json",
      5000,
    )
  let assert Ok(response) = live.send(request)
  assert string.ends_with(types.body_text(response), "{not json")
  assert string.contains(types.body_text(response), "content-type=text/plain")
}

pub fn streamed_chunks_keep_order_and_arrival_times_test() {
  server.ensure_started()
  let assert Ok(response) = live.send(get("/stream"))
  assert response.status == 200
  let text = types.body_text(response)
  assert string.contains(text, "data: {\"n\":0}")
  assert string.ends_with(text, "data: [DONE]\n\n")
  assert list.length(response.chunks) >= 3
  let times = list.map(response.chunks, fn(chunk) { chunk.at_us })
  assert times == list.sort(times, int.compare)
  let assert [first, ..] = times
  let assert Ok(last) = list.last(times)
  // Events are 60 ms apart, so the stream spans well over 100 ms.
  assert last - first > 100_000
  assert response.timing.first_byte_us == Some(first)
  let assert Some(done) = response.timing.done_us
  assert done >= last
}

pub fn chunk_bytes_concatenate_to_the_body_test() {
  server.ensure_started()
  let assert Ok(response) = live.send(get("/stream"))
  let joined =
    list.fold(response.chunks, <<>>, fn(acc, chunk) {
      <<acc:bits, chunk.data:bits>>
    })
  assert joined == response.body
}

pub fn deadline_produces_a_timeout_error_test() {
  server.ensure_started()
  let request = Request(Get, server.base_url() <> "/slow", [], "", 300)
  assert live.send(request) == Error(Timeout)
}

pub fn refused_connection_is_a_connect_error_test() {
  let request = Request(Get, "http://127.0.0.1:9/", [], "", 2000)
  let assert Error(Connect(_)) = live.send(request)
}

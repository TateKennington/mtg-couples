import gleam/bool
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element
import lustre/element/html
import mist
import wisp.{type Response}
import wisp/wisp_mist

type ListingErr {
  ParamParseErr(Nil)
  HTTPErr(httpc.HttpError)
}

fn get_listings(card, page, retries) {
  use <- bool.guard(
    retries <= 0,
    Ok(response.new(200) |> response.set_body("[]")),
  )

  let request_url =
    string.concat([
      "https://api.mtgsingles.co.nz/MtgSingle?tcgType=1&store=6&store=7&store=11&store=32&store=3&store=27&store=28&store=13&store=4&store=18&store=2&store=19&store=16&store=1&store=31&store=42&isExactMatch=false&condition=NM%20/%20SP&condition=SP%20/%20LP&Country=1&pageSize=20&query=",
      card,
      "&page=",
      page,
    ])
  let assert Ok(base_req) = request.to(request_url)

  let req =
    request.prepend_header(base_req, "accept", "application/json")
    |> request.set_header("referer", "https://mtgsingles.co.nz/")
    |> request.set_header(
      "user-agent",
      "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
    )

  // Send the HTTP request to the server
  let resp_result = httpc.send(req) |> result.map_error(HTTPErr)
  use resp <- result.try(resp_result)

  case
    resp.body == "API calls quota exceeded! maximum admitted 5 per 5s."
    || resp.body == "error code: 1015"
  {
    False -> Ok(resp)
    True -> {
      process.sleep(2000 + float.truncate(float.random() *. 500.0))
      get_listings(card, page, retries - 1)
    }
  }
}

fn listings(card, page) {
  case get_listings(card, page, 6) {
    Ok(resp) ->
      wisp.html_response(resp.body, 200)
      |> wisp.set_header("content-type", "application/json")
    Error(ParamParseErr(_)) -> wisp.bad_request("Parse Error")
    Error(HTTPErr(e)) -> {
      echo e
      wisp.internal_server_error()
    }
  }
}

fn middleware(req, handle_request) {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  handle_request(req)
  |> wisp.set_header("access-control-allow-origin", "*")
}

fn handle_request(req) {
  use <- wisp.require_method(req, http.Get)
  use req <- middleware(req)

  let assert Ok(priv) = wisp.priv_directory("backend")
  let static_dir = priv <> "/static"
  use <- wisp.serve_static(req, under: "/static", from: static_dir)

  case wisp.path_segments(req) {
    ["listings", card, page] -> listings(card, page)
    _ -> serve_index()
  }
}

fn serve_index() -> Response {
  let html =
    html.html([], [
      html.head([], [
        html.title([], "Grocery List"),
        html.script(
          [attribute.type_("module"), attribute.src("/static/frontend.js")],
          "",
        ),
        html.link([
          attribute.rel("stylesheet"),
          attribute.href("/static/frontend.css"),
        ]),
      ]),
      html.body([], [html.div([attribute.id("app")], [])]),
    ])

  html
  |> element.to_document_string
  |> wisp.html_response(200)
}

pub fn main() {
  wisp.configure_logger()

  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    wisp_mist.handler(handle_request, secret_key_base)
    |> mist.new
    |> mist.port(8080)
    |> mist.start

  process.sleep_forever()
}

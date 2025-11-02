import gleam/bool
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleam/uri
import lustre
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
import lustre/event
import rsvp

type Model {
  DecklistInput(String)
  Loading(
    results: dict.Dict(String, List(Listing)),
    decklist: List(#(String, Int)),
    pending_load: List(String),
  )
  Review(
    results: dict.Dict(String, List(Listing)),
    decklist: List(#(String, Int)),
    constraints: dict.Dict(String, set.Set(Int)),
  )
}

fn init(_flags) -> #(Model, effect.Effect(Msg)) {
  #(DecklistInput(""), effect.none())
}

pub type Listing {
  Listing(
    title: String,
    price: Float,
    condition: String,
    store: String,
    url: String,
    image_url: String,
    features: List(String),
  )
}

fn get_listings(card, page) {
  let decoder = {
    use title <- decode.field("title", decode.string)
    let price_decoder =
      decode.map(decode.string, fn(price) {
        string.drop_start(price, 1)
        |> float.parse
        |> result.unwrap(0.0)
      })
    use price <- decode.field("price", price_decoder)
    use condition <- decode.field("condition", decode.string)
    let store_decoder =
      decode.map(decode.string, fn(store) {
        case string.starts_with(store, "NZ/") {
          False -> store
          True -> string.drop_start(store, 3)
        }
      })
    use store <- decode.field("store", store_decoder)

    use url <- decode.field("url", decode.string)
    use image_url <- decode.field("imageUrl", decode.string)
    use features <- decode.field("features", decode.list(decode.string))
    decode.success(Listing(
      title:,
      price:,
      condition:,
      store:,
      url:,
      image_url:,
      features:,
    ))
  }
  let expect =
    rsvp.expect_json(decode.list(decoder), fn(res) {
      let res = result.unwrap(res, [])
      ApiReturnedListings(res:, card:, next_page: page + 1)
    })

  let url =
    string.concat([
      "/listings/",
      // "http://localhost:8080/listings/",
      uri.percent_encode(card),
      "/",
      int.to_string(page),
    ])

  rsvp.get(url, expect)
}

type Msg {
  UserUpdatedDecklist(String)
  UserSubmittedDecklist
  UserUpdatedConstraints(card: String, index: Int)
  ApiReturnedListings(
    // res: Result(List(Listing), lustre_http.HttpError),
    res: List(Listing),
    card: String,
    next_page: Int,
  )
}

fn update_decklist(model, decklist) {
  let model = case model {
    DecklistInput(_) -> DecklistInput(decklist)
    _ -> panic
  }

  #(model, effect.none())
}

fn parse_decklist(decklist) {
  string.split(decklist, "\n")
  |> list.map(fn(line) { #(line, 1) })
}

fn submit_decklist(model) {
  case model {
    DecklistInput(decklist) -> {
      let decklist = parse_decklist(decklist)
      let cards = list.map(decklist, fn(x) { x.0 })
      let #(inflight, pending_load) = list.split(cards, 5)

      let model = Loading(decklist:, pending_load:, results: dict.new())

      let effect = case list.is_empty(inflight) {
        True -> effect.none()
        False ->
          list.map(inflight, fn(card) { get_listings(card, 1) })
          |> effect.batch()
      }
      #(model, effect)
    }
    _ -> panic
  }
}

fn api_returned_listings(model, listings, card, next_page) {
  case model, listings {
    Loading(pending_load: [_, next, ..rest], ..), [] -> #(
      Loading(..model, pending_load: [next, ..rest]),
      get_listings(next, 1),
    )
    Loading(decklist:, results:, ..), [] -> #(
      Review(decklist:, results:, constraints: dict.new()),
      effect.none(),
    )
    Loading(results:, ..), listings -> {
      let plausible_listings =
        list.filter(listings, fn(listing: Listing) {
          string.split(listing.title, "(")
          |> list.first
          |> result.map(fn(title) {
            string.compare(
              string.lowercase(string.trim(title)),
              string.lowercase(card),
            )
            != order.Gt
          })
          |> result.unwrap(False)
          || list.contains(listing.features, "Sealed")
        })

      let listings =
        list.filter(plausible_listings, fn(listing: Listing) {
          string.split(listing.title, "(")
          |> list.first
          |> result.map(fn(title) {
            string.lowercase(string.trim(title)) == string.lowercase(card)
          })
          |> result.unwrap(False)
          && !list.contains(listing.features, "Sealed")
          && listing.condition == "NM / SP"
        })
      case list.is_empty(plausible_listings) {
        False -> #(
          Loading(
            ..model,
            results: dict.upsert(results, card, fn(existing) {
              case existing {
                option.None -> listings
                option.Some(existing) -> list.append(existing, listings)
              }
            }),
          ),
          get_listings(card, next_page),
        )
        True -> api_returned_listings(model, [], "", 0)
      }
    }
    DecklistInput(..), _ | Review(..), _ -> panic
  }
}

fn update_constraints(model, card, index) {
  let model = case model {
    Review(..) ->
      Review(
        ..model,
        constraints: dict.upsert(model.constraints, card, fn(constraint) {
          case constraint {
            option.None -> set.from_list([index])
            option.Some(existing) -> set.insert(existing, index)
          }
        }),
      )
    _ -> panic
  }

  #(model, effect.none())
}

fn update(model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    UserUpdatedDecklist(decklist) -> update_decklist(model, decklist)
    UserSubmittedDecklist -> submit_decklist(model)
    ApiReturnedListings(res: listings, card:, next_page:) ->
      api_returned_listings(model, listings, card, next_page)
    // ApiReturnedListings(res: Error(e), ..) -> {
    //   io.debug(e)
    //   panic
    // }
    UserUpdatedConstraints(card:, index:) ->
      update_constraints(model, card, index)
  }
}

fn decklist_input_view(decklist) {
  html.div(
    [
      attribute.class("min-h-screen"),
      attribute.class("grid"),
      attribute.class("grid-cols-[0.5fr_2fr_0.5fr]"),
      attribute.class("grid-rows-[0.5fr_2fr_0.5fr]"),
    ],
    [
      html.div(
        [
          attribute.class("col-start-2"),
          attribute.class("row-start-2"),
          attribute.class("flex"),
          attribute.class("flex-col"),
          attribute.class("gap-4"),
        ],
        [
          html.div(
            [
              attribute.class("flex"),
              attribute.class("grow"),
              attribute.class("gap-4"),
            ],
            [
              html.textarea(
                [
                  attribute.class("w-1/2"),
                  attribute.class("bg-purple-50"),
                  attribute.class("rounded-md"),
                  attribute.class("border-2"),
                  attribute.class("border-purple-600"),
                  attribute.class("resize-none"),
                  attribute.class("p-1"),
                  event.on_input(UserUpdatedDecklist),
                ],
                decklist,
              ),
              html.div(
                [
                  attribute.class("w-1/2"),
                  attribute.class("rounded-md"),
                  attribute.class("border-2"),
                  attribute.class("border-purple-600"),
                ],
                [html.text("TBD")],
              ),
            ],
          ),
          html.button(
            [
              attribute.class("bg-purple-400"),
              attribute.class("rounded-md"),
              attribute.class("border-none"),
              attribute.class("p-2"),
              event.on_click(UserSubmittedDecklist),
            ],
            [element.text("Submit")],
          ),
        ],
      ),
    ],
  )
}

fn listing_view(listing: Listing, events) {
  let img_classes = case list.contains(listing.features, "Foil") {
    False -> []
    True -> [attribute.class("animate-foil")]
  }
  html.div(
    [
      attribute.class("flex"),
      attribute.class("flex-col"),
      attribute.class("items-center"),
      ..events
    ],
    [
      html.p([attribute.class("w-fit")], [element.text(listing.store)]),
      html.a([attribute.href(listing.url), attribute.target("blank")], [
        html.img([
          attribute.src(listing.image_url),
          attribute.class("w-[200px]"),
          attribute.class("h-[280px]"),
          attribute.class("object-cover"),
          attribute.class("object-center"),
          attribute.class("rounded-lg"),
          attribute.class("max-w-none"),
          attribute.loading("lazy"),
          ..img_classes
        ]),
      ]),
      html.div(
        [
          attribute.class("flex"),
          attribute.class("w-full"),
          attribute.class("justify-around"),
        ],
        [
          html.p([], [element.text(listing.condition)]),
          html.p([], [
            element.text("$"),
            element.text(float.to_string(listing.price)),
          ]),
        ],
      ),
    ],
  )
}

fn listings_view(listings, get_events) {
  html.div(
    [
      attribute.style("display", "flex"),
      attribute.style("flex-direction", "row"),
      attribute.style("gap", "20px"),
      attribute.class("max-w-full"),
      attribute.class("flex-wrap"),
    ],
    list.index_map(listings, fn(listing, index) {
      listing_view(listing, get_events(index))
    }),
  )
}

fn loading_view(results: dict.Dict(String, List(Listing))) {
  let children =
    dict.fold(results, [], fn(acc, card, listings) {
      list.append(acc, [
        html.h3([], [element.text(card)]),
        listings_view(listings, fn(_index) { [] }),
      ])
    })
  html.div([], children)
}

pub fn find_optimal(
  decklist: List(#(String, a)),
  results: dict.Dict(String, List(Listing)),
  constraints,
) {
  let decklist = list.map(decklist, fn(card) { card.0 })

  let #(decklist, results, store_listings) =
    list.fold(decklist, #([], dict.new(), dict.new()), fn(acc, card) {
      let constraint = dict.get(constraints, card)
      let listings = dict.get(results, card) |> result.unwrap([])
      let listings = case constraint {
        Error(_) -> listings
        Ok(constraint) ->
          list.index_fold(listings, [], fn(acc, listing, index) {
            case set.contains(constraint, index) {
              False -> acc
              True -> [listing, ..acc]
            }
          })
      }
      let store_listings =
        list.fold(listings, acc.2, fn(acc, listing) {
          dict.upsert(
            acc,
            listing.store,
            fn(existing: option.Option(dict.Dict(String, Listing))) -> dict.Dict(
              String,
              Listing,
            ) {
              case existing {
                option.None -> dict.from_list([#(card, listing)])
                option.Some(existing) ->
                  dict.upsert(
                    existing,
                    card,
                    fn(existing: option.Option(Listing)) {
                      case existing {
                        option.None -> listing
                        option.Some(existing) ->
                          case existing.price <. listing.price {
                            True -> existing
                            False -> listing
                          }
                      }
                    },
                  )
              }
            },
          )
        })
      case list.is_empty(listings) {
        False -> #(
          [card, ..acc.0],
          dict.insert(acc.1, card, listings),
          store_listings,
        )
        True -> acc
      }
    })

  let must_include =
    list.filter_map(decklist, fn(card) {
      let listings = dict.get(results, card) |> result.unwrap([])
      case list.is_empty(list.drop(listings, 1)) {
        False -> Error(Nil)
        True ->
          list.first(listings) |> result.map(fn(listing) { listing.store })
      }
    })
    |> set.from_list
    |> set.to_list

  let all_stores =
    list.flat_map(decklist, fn(card) {
      let listings = dict.get(results, card) |> result.unwrap([])
      list.map(listings, fn(listing) { listing.store })
    })
    |> set.from_list
    |> set.to_list

  let stores =
    list.filter(all_stores, fn(store) {
      let assert Ok(listings) = dict.get(store_listings, store)
      !list.contains(must_include, store)
      && !list.any(all_stores, fn(other_store) {
        let assert Ok(other_listings) = dict.get(store_listings, other_store)

        list.all(dict.to_list(listings), fn(entry) {
          let #(card, listing) = entry
          let other_listing = dict.get(other_listings, card)
          case other_listing {
            Error(_) -> False
            Ok(other_listing) -> other_listing.price <. listing.price
          }
        })
      })
    })

  let assert Ok(max) = int.power(2, int.to_float(list.length(stores)))
  list.range(1, float.truncate(max) - 1)
  |> list.filter(fn(mask) { pop_count(mask) <= 5 })
  |> list.map(fn(mask) {
    let stores =
      list.index_fold(stores, [], fn(acc, store, index) {
        case int.bitwise_and(int.bitwise_shift_left(1, index), mask) > 0 {
          False -> acc
          True -> [store, ..acc]
        }
      })

    let listings =
      list.filter_map(decklist, fn(card) {
        let listings = dict.get(results, card) |> result.unwrap([])
        // let stores = list.append(stores, must_include)
        list.filter(listings, fn(listing) {
          list.contains(stores, listing.store)
        })
        |> list.max(fn(a, b) { float.compare(b.price, a.price) })
      })
    #(
      float.sum(list.map(listings, fn(listing) { listing.price })),
      listings,
      20.0 *. int.to_float(list.length(stores) + list.length(must_include)),
    )
  })
  |> list.max(fn(a, b) {
    case int.compare(list.length(a.1), list.length(b.1)) {
      order.Eq -> float.compare(b.0 +. b.2, a.0 +. a.2)
      ord -> ord
    }
  })
}

fn pop_count(n) {
  use <- bool.guard(n == 0, 0)
  int.bitwise_and(n, 1) + pop_count(int.bitwise_shift_right(n, 1))
}

fn review_view(decklist, results, constraints) {
  let assert Ok(#(optimal_price, optimal_listings, _)) =
    find_optimal(decklist, results, constraints)
  let results_views =
    dict.fold(results, [], fn(acc, card, listings) {
      list.append(acc, [
        html.h3([], [element.text(card)]),
        listings_view(listings, fn(index) {
          [event.on_click(UserUpdatedConstraints(card:, index:))]
        }),
      ])
    })
  html.div([], [
    html.h3([], [
      element.text("Best Order - "),
      element.text(float.to_string(optimal_price)),
    ]),
    listings_view(optimal_listings, fn(_index) { [] }),
    ..results_views
  ])
}

fn view(model) -> element.Element(Msg) {
  case model {
    DecklistInput(decklist) -> decklist_input_view(decklist)
    Loading(results:, ..) -> loading_view(results)
    Review(decklist:, results:, constraints:) ->
      review_view(decklist, results, constraints)
  }
}

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)

  Nil
}

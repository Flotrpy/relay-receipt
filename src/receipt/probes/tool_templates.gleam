//// The tool-choice templates of Step 17, component A.
////
//// Following arXiv:2609.00052 (Section 3.2 and Appendix A), each template
//// offers four tools that do the same thing under names drawn from
//// different naming conventions, with one shared description and one
//// shared parameter schema, and a request worded without naming any
//// product. Which name a model picks reflects habits formed in training.
//// The templates are written for Receipt.

import gleam/json.{type Json}
import gleam/list
import receipt/api/types.{type Tool, Tool}

pub type Template {
  Template(
    id: String,
    /// The user request.
    request: String,
    /// The four equivalent tool names.
    names: List(String),
    /// The description every tool in the template shares.
    description: String,
    /// The names of the string parameters every tool shares.
    parameters: List(String),
  )
}

fn t(
  id: String,
  request: String,
  names: List(String),
  description: String,
  parameters: List(String),
) -> Template {
  Template(id, request, names, description, parameters)
}

pub fn all() -> List(Template) {
  [
    t(
      "email",
      "Send a short note to alice@example.com saying the report is ready.",
      ["send_email", "email_send", "sendMail", "mcp__mail__send_message"],
      "Sends a message to one recipient.",
      ["to", "subject", "body"],
    ),
    t(
      "calendar",
      "Schedule a team sync for Thursday at 2pm.",
      [
        "create_event",
        "schedule_meeting",
        "addCalendarEntry",
        "mcp__calendar__create_event",
      ],
      "Adds an entry to the calendar.",
      ["title", "start_time"],
    ),
    t(
      "weather",
      "What will the weather be like in Lisbon tomorrow?",
      [
        "get_weather",
        "weather_lookup",
        "fetchForecast",
        "mcp__weather__get_forecast",
      ],
      "Returns the forecast for a place.",
      ["location", "date"],
    ),
    t(
      "search",
      "Find recent articles about tidal energy.",
      ["web_search", "search_web", "searchInternet", "mcp__search__query"],
      "Looks up pages matching a query.",
      ["query"],
    ),
    t(
      "read_file",
      "Show me what is in notes.txt.",
      ["read_file", "file_read", "openFile", "mcp__filesystem__read_file"],
      "Returns the contents of a file.",
      ["path"],
    ),
    t(
      "write_file",
      "Save the text 'draft one' into draft.txt.",
      ["write_file", "file_write", "saveFile", "mcp__filesystem__write_file"],
      "Stores text in a file.",
      ["path", "content"],
    ),
    t(
      "translate",
      "Put 'good morning' into Japanese.",
      [
        "translate_text",
        "text_translate",
        "translateString",
        "mcp__language__translate",
      ],
      "Converts text into another language.",
      ["text", "target_language"],
    ),
    t(
      "calculate",
      "Work out 18.5 percent of 2400.",
      [
        "calculator",
        "evaluate_expression",
        "computeMath",
        "mcp__math__evaluate",
      ],
      "Evaluates an arithmetic expression.",
      ["expression"],
    ),
    t(
      "reminder",
      "Remind me to call the dentist at 9 tomorrow.",
      [
        "set_reminder",
        "reminder_create",
        "addReminder",
        "mcp__reminders__create",
      ],
      "Creates a reminder for a time.",
      ["text", "time"],
    ),
    t(
      "note",
      "Jot down that the garage code changed.",
      ["create_note", "note_add", "saveNote", "mcp__notes__create_note"],
      "Stores a short note.",
      ["text"],
    ),
    t(
      "directions",
      "How do I get from the station to the museum on foot?",
      ["get_directions", "route_plan", "findRoute", "mcp__maps__directions"],
      "Returns a route between two places.",
      ["origin", "destination"],
    ),
    t(
      "currency",
      "How much is 250 US dollars in euros?",
      [
        "convert_currency",
        "currency_convert",
        "exchangeMoney",
        "mcp__finance__convert",
      ],
      "Converts an amount between currencies.",
      ["amount", "from", "to"],
    ),
    t(
      "stock",
      "What is the latest price of ticker EXMP?",
      ["get_stock_price", "stock_quote", "fetchQuote", "mcp__market__get_quote"],
      "Returns the latest price for a ticker.",
      ["symbol"],
    ),
    t(
      "timer",
      "Start a countdown of twelve minutes.",
      ["set_timer", "timer_start", "startCountdown", "mcp__clock__set_timer"],
      "Starts a countdown.",
      ["duration"],
    ),
    t(
      "todo",
      "Put 'renew passport' on my list of tasks.",
      ["add_todo", "todo_create", "createTask", "mcp__tasks__add_task"],
      "Adds an item to the task list.",
      ["title"],
    ),
    t(
      "database",
      "How many orders were placed last week?",
      ["run_sql", "query_database", "executeQuery", "mcp__database__query"],
      "Runs a read-only query.",
      ["query"],
    ),
    t(
      "fetch",
      "Get the contents of https://example.com/status.",
      ["http_get", "fetch_url", "requestPage", "mcp__http__fetch"],
      "Retrieves a web address.",
      ["url"],
    ),
    t(
      "image",
      "Make a picture of a lighthouse at dusk.",
      ["generate_image", "image_create", "drawPicture", "mcp__images__generate"],
      "Produces a picture from a description.",
      ["prompt"],
    ),
    t(
      "text_message",
      "Text Bob at 555-0100 that I am running late.",
      ["send_sms", "sms_send", "sendTextMessage", "mcp__messaging__send_sms"],
      "Sends a short message to a phone number.",
      ["number", "body"],
    ),
    t(
      "contact",
      "Look up the phone number for Dana Lee.",
      [
        "find_contact",
        "contact_lookup",
        "searchContacts",
        "mcp__contacts__find",
      ],
      "Finds a person in the address book.",
      ["name"],
    ),
  ]
}

fn schema(parameters: List(String)) -> Json {
  json.object([
    #("type", json.string("object")),
    #(
      "properties",
      json.object(
        list.map(parameters, fn(name) {
          #(name, json.object([#("type", json.string("string"))]))
        }),
      ),
    ),
    #("required", json.array(parameters, json.string)),
  ])
}

/// The tool definitions for a template, in the given name order.
pub fn tools(template: Template, order: List(String)) -> List(Tool) {
  list.map(order, fn(name) {
    Tool(name, template.description, schema(template.parameters))
  })
}

/// Outcome labels that every template's option set includes.
pub const no_call = "_no_call"

pub const malformed = "_malformed"

pub const other = "_other"

/// Classify a model's response to a template: the offered tool it called,
/// or one of the three special outcomes.
pub fn classify(template: Template, called: List(#(String, Bool))) -> String {
  case called {
    [] -> no_call
    [#(name, well_formed), ..] ->
      case well_formed, list.contains(template.names, name) {
        False, _ -> malformed
        True, True -> name
        True, False -> other
      }
  }
}

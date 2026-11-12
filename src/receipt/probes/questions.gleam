//// The multiple-choice question pool of Step 15.
////
//// Short science and everyday-reasoning questions with four options, in
//// the style of the question-answering sets used by arXiv:2609.20370 but
//// written for Receipt. Each prompt ends with a required final-answer
//// line, which is what the length-inducing probe refers to.

import gleam/list
import gleam/string

pub type Question {
  Question(id: String, text: String, options: List(String))
}

fn q(id: String, text: String, a: String, b: String, c: String, d: String) {
  Question(id, text, [a, b, c, d])
}

pub fn pool() -> List(Question) {
  [
    q(
      "q01",
      "Which gas do plants take in from the air to make food?",
      "Oxygen",
      "Carbon dioxide",
      "Nitrogen",
      "Helium",
    ),
    q(
      "q02",
      "What happens to water when it is cooled below 0 degrees Celsius at normal pressure?",
      "It boils",
      "It freezes",
      "It evaporates",
      "It stays liquid",
    ),
    q(
      "q03",
      "Which of these is a source of renewable energy?",
      "Coal",
      "Natural gas",
      "Wind",
      "Petrol",
    ),
    q(
      "q04",
      "Which part of a plant usually absorbs water from the soil?",
      "Leaves",
      "Flowers",
      "Roots",
      "Seeds",
    ),
    q(
      "q05",
      "A metal spoon left in hot soup becomes hot mainly because of what?",
      "Conduction",
      "Evaporation",
      "Reflection",
      "Condensation",
    ),
    q(
      "q06",
      "Which force pulls objects toward the centre of the Earth?",
      "Magnetism",
      "Friction",
      "Gravity",
      "Buoyancy",
    ),
    q(
      "q07",
      "What do bees collect from flowers to make honey?",
      "Pollen only",
      "Nectar",
      "Sap",
      "Dew",
    ),
    q(
      "q08",
      "Which planet is closest to the Sun?",
      "Venus",
      "Earth",
      "Mars",
      "Mercury",
    ),
    q(
      "q09",
      "What is the main reason we see lightning before we hear thunder?",
      "Light travels faster than sound",
      "Sound travels faster than light",
      "Thunder starts later",
      "Clouds block sound",
    ),
    q(
      "q10",
      "Which material is the best electrical insulator?",
      "Copper",
      "Rubber",
      "Aluminium",
      "Salt water",
    ),
    q(
      "q11",
      "Which organ pumps blood through the human body?",
      "Lungs",
      "Liver",
      "Heart",
      "Kidneys",
    ),
    q(
      "q12",
      "If you mix red and yellow paint, which colour do you get?",
      "Green",
      "Orange",
      "Purple",
      "Brown",
    ),
    q(
      "q13",
      "Which of these animals is a mammal?",
      "Shark",
      "Frog",
      "Dolphin",
      "Lizard",
    ),
    q(
      "q14",
      "What causes day and night on Earth?",
      "The Earth orbiting the Sun",
      "The Earth spinning on its axis",
      "The Moon blocking the Sun",
      "Clouds moving",
    ),
    q(
      "q15",
      "Which tool is used to measure temperature?",
      "Barometer",
      "Thermometer",
      "Ruler",
      "Compass",
    ),
    q(
      "q16",
      "A puddle disappears on a sunny day mainly because of what?",
      "Freezing",
      "Evaporation",
      "Melting",
      "Filtration",
    ),
    q(
      "q17",
      "Which simple machine is a seesaw an example of?",
      "Pulley",
      "Wedge",
      "Lever",
      "Screw",
    ),
    q(
      "q18",
      "What do herbivores eat?",
      "Only meat",
      "Only plants",
      "Plants and meat",
      "Only insects",
    ),
    q(
      "q19",
      "Which of these travels fastest?",
      "A car on a motorway",
      "Sound in air",
      "Light",
      "A jet aircraft",
    ),
    q(
      "q20",
      "Why do we wear seat belts in cars?",
      "To keep warm",
      "To stay in place during sudden stops",
      "To help the engine",
      "To see the road better",
    ),
    q(
      "q21",
      "Which state of matter has a fixed shape and a fixed volume?",
      "Gas",
      "Liquid",
      "Solid",
      "Plasma",
    ),
    q(
      "q22",
      "What is the main gas in the air we breathe?",
      "Oxygen",
      "Nitrogen",
      "Carbon dioxide",
      "Hydrogen",
    ),
    q(
      "q23",
      "Which object would a magnet attract?",
      "A wooden pencil",
      "A glass marble",
      "An iron nail",
      "A plastic cup",
    ),
    q(
      "q24",
      "Why does ice float on water?",
      "Ice is denser than water",
      "Ice is less dense than water",
      "Ice is warmer than water",
      "Water pushes ice down",
    ),
    q("q25", "Which sense organ detects sound?", "Eye", "Ear", "Nose", "Tongue"),
    q(
      "q26",
      "What do you need to complete a simple electric circuit with a bulb and a battery?",
      "A closed loop of wire",
      "A magnet",
      "A glass rod",
      "A thermometer",
    ),
    q(
      "q27",
      "Which season comes after winter in the northern hemisphere?",
      "Autumn",
      "Summer",
      "Spring",
      "Winter again",
    ),
    q(
      "q28",
      "A ball rolling on grass slows down mainly because of what?",
      "Gravity",
      "Friction",
      "Magnetism",
      "Sound",
    ),
    q(
      "q29",
      "Which of these is a property of all living things?",
      "They can fly",
      "They grow",
      "They are green",
      "They live in water",
    ),
    q(
      "q30",
      "What is the boiling point of water at sea level?",
      "50 degrees Celsius",
      "90 degrees Celsius",
      "100 degrees Celsius",
      "150 degrees Celsius",
    ),
    q(
      "q31",
      "Which body part do fish use to take in oxygen?",
      "Lungs",
      "Gills",
      "Fins",
      "Scales",
    ),
    q(
      "q32",
      "What is the Moon's light?",
      "Light the Moon makes itself",
      "Sunlight reflected by the Moon",
      "Light from the Earth's cities",
      "Light from other planets",
    ),
  ]
}

const letters = ["A", "B", "C", "D"]

/// The instruction every question ends with.
pub const answer_line =
  "End your reply with a final line of the form \"Answer: <letter>\"."

/// The question as sent to the model.
pub fn render(question: Question) -> String {
  let options =
    list.zip(letters, question.options)
    |> list.map(fn(pair) { pair.0 <> ") " <> pair.1 })
    |> string.join("\n")
  question.text <> "\n" <> options <> "\n\n" <> answer_line
}

/// The two length-inducing probes of Appendix B.1 of arXiv:2609.20370.
pub const probe_a =
  "Before the required final-answer line, present the necessary reasoning steps in a clear order leading to the conclusion."

pub const probe_b =
  "Lay out the required derivation step by step before giving the final-answer line."

/// The question with a probe appended to the same user message.
pub fn render_probed(question: Question, probe: String) -> String {
  render(question) <> " " <> probe
}

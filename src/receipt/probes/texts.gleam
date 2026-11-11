//// The thirty controlled texts of Step 3.
////
//// Following arXiv:2608.29930, the set spans English prose, other
//// scripts, mixed scripts, source code, emoji, punctuation, whitespace,
//// structured formats, URLs and two long repeated-text cases, so that two
//// endpoints that tokenise alike agree on every count up to one fixed
//// offset, and two that do not are unlikely to agree by chance. The texts
//// are written for Receipt; they are not the paper's.

import gleam/string

pub fn all() -> List(String) {
  [
    // English prose
    "The quick brown fox jumps over the lazy dog.",
    "Please summarise the following paragraph in one sentence.",
    "It was the best of times, it was the worst of times, it was the age of wisdom.",
    "Wednesday, 11 November 2026, 14:35 Eastern Standard Time.",
    "Antidisestablishmentarianism and pneumonoultramicroscopicsilicovolcanoconiosis.",
    // Other scripts
    "今天天气很好，我们去公园散步吧。",
    "東京は日本の首都であり、世界最大級の都市圏です。",
    "Привет, как дела? Сегодня очень холодно.",
    "مرحبا بالعالم، كيف حالك اليوم؟",
    "서울은 대한민국의 수도입니다.",
    // Mixed scripts
    "The word 你好 means hello, and ありがとう means thank you.",
    "Prix: 42,50 € — café, naïve, jalapeño, Zürich, Ærøskøbing.",
    // Source code
    "def add(a, b):\n    return a + b\n\nprint(add(2, 3))",
    "for (let i = 0; i < 10; i++) { console.log(i * i); }",
    "SELECT id, name FROM users WHERE created_at > '2026-01-01' ORDER BY id DESC;",
    "fn main() {\n    let v: Vec<u32> = (1..=5).collect();\n    println!(\"{:?}\", v);\n}",
    // Emoji and symbols
    "🙂🚀🌍 Launch day! 🎉🎉",
    "∑ ∫ √ ≈ ≠ ≤ ≥ ∞ → ← ↔ ± × ÷",
    // Punctuation and whitespace
    "!!! ??? ... --- ___ ### $$$ %%% &&& ***",
    "a  b   c    d     e      f",
    "line one\n\n\nline two\t\ttabbed\r\nline three",
    "(((nested [brackets {of <every> kind}])))",
    // Structured formats
    "{\"name\": \"receipt\", \"version\": 1, \"tags\": [\"audit\", \"relay\"], \"ok\": true}",
    "name: receipt\nversion: 1\ntags:\n  - audit\n  - relay\n",
    "<html><body><h1>Title</h1><p class=\"lead\">Text &amp; more</p></body></html>",
    "id,name,score\n1,alpha,0.5\n2,beta,0.75\n3,gamma,1.0",
    // URLs and identifiers
    "https://example.com/path/to/resource?query=value&other=123#fragment",
    "user.name+tag@example.org, 192.0.2.17, 2001:db8::1, a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    // Long repeated text
    string.repeat("alpha beta gamma delta ", 40),
    string.repeat("0123456789", 30),
  ]
}

/// The three minimal messages of the estimate method, as
/// `#(system prompt, user message)`; an empty system prompt means none.
pub fn minimal() -> List(#(String, String)) {
  [
    #("", "Hi"),
    #("You are a concise assistant.", "Hi"),
    #("", "Name one colour."),
  ]
}

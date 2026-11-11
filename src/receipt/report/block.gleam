//// Format-neutral building blocks for the body of a step's report section.
////
//// Steps describe what they observed with these blocks; the Markdown
//// reporter renders them. Keeping steps free of Markdown syntax means
//// escaping is handled in one place.

pub type Block {
  /// A paragraph of prose.
  Paragraph(text: String)
  /// A table. Every row must have as many cells as there are headers.
  Table(headers: List(String), rows: List(List(String)))
  /// Verbatim text, such as a response preview.
  Code(text: String)
  /// A bullet list.
  Bullets(items: List(String))
  /// A Mermaid diagram source.
  Mermaid(source: String)
}

---
name: summarize-document
description: Use when writing the two-sentence summary field, and when deciding what a document is actually about versus what it merely mentions.
---

# Summarizing a document

Two sentences, under 40 words total. The constraint is the point: it forces a
decision about what the document is for.

## What to include

The first sentence states what the document is and what it concerns. The second
states its consequence, conclusion, or request. If the document has no
consequence, use the second sentence for the most substantive specific detail
instead.

## What to leave out

- The document's own framing of itself ("This report describes...")
- Anything captured by another field, such as dates or action items
- Hedging about your own confidence, which belongs in the `confidence` field

## Determining document type

- `report` — presents findings, data, or status
- `correspondence` — addressed from one party to another, including email and memos
- `specification` — defines requirements, standards, or how something must behave
- `other` — anything that does not clearly fit, including unreadable input

When a document could be two types, classify by its primary function. A memo
containing findings is still correspondence if its purpose is to inform a
recipient; it is a report if the findings are the substance and the addressee is
incidental.

---
description: Extract structured fields from a plain-text document
argument-hint: <path-to-document>
---

Analyze the document at `$1` and extract the fields below.

## Delivery contract

Return the JSON object as your final message, as the entire message body, with no
prose before or after it and no code fence. Do not write it to a file.

This instruction is load-bearing. An instruction that only asks for "structured
JSON output" leaves the delivery mechanism unspecified, and the agent will
sometimes write the JSON to a local file and return a prose summary instead. The
wrapper uploads the final message, so that run stores a summary where the result
should be, and the file is discarded when the task exits. Nothing fails, and the
item is recorded as a success. Be explicit about delivery in your own agent logic.

## Fields

```json
{
  "document_id": "string, the file name without its extension",
  "document_type": "one of: report, correspondence, specification, other",
  "summary": "string, two sentences at most",
  "key_entities": [
    {"name": "string", "type": "one of: organization, person, product, location"}
  ],
  "dates_referenced": ["string, ISO 8601 where the document allows it"],
  "action_items": ["string, one per item, empty array if none"],
  "sentiment": "one of: positive, neutral, negative, mixed",
  "confidence": "number between 0 and 1, your confidence in this extraction"
}
```

## Rules

- Extract only what the document states. Do not infer facts that are not present.
- Use `null` for a field the document does not support, and `[]` for an empty list.
- Keep `summary` under 40 words.
- If the document is empty or unreadable, return the object with `document_type`
  set to `other`, `confidence` set to `0`, and a `summary` explaining why.

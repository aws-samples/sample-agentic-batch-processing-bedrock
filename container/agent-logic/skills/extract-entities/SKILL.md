---
name: extract-entities
description: Use when identifying organizations, people, products, or locations named in a document, and when deciding which of them are significant enough to report.
---

# Extracting entities

An entity is significant when the document makes a claim about it, assigns it an
action, or describes a relationship it participates in. A name that appears only
in passing, such as in a letterhead or a distribution list, is not significant.

## Classification

| Type | Includes | Excludes |
|---|---|---|
| `organization` | companies, agencies, teams, departments | product lines sold by a company |
| `person` | named individuals, including by role where the role identifies one person | job titles with no named holder |
| `product` | named products, services, systems, software | generic category nouns |
| `location` | cities, regions, countries, named facilities | mailing addresses in headers |

## Resolving duplicates

Report each entity once, using the fullest form the document gives. When a
document uses both a full name and a short form, prefer the full name and treat
the short form as the same entity. When two entities share a name but the
document distinguishes them, report both and keep the distinguishing words.

## Judgment calls

Prefer fewer, well-supported entities over an exhaustive list. A run that reports
three entities the document clearly discusses is more useful than one reporting
twelve, most of which appear once. If a name's type is genuinely ambiguous from
the document alone, classify it by how the document uses it rather than by what
you know about it from elsewhere.

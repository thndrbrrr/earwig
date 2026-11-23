# Composable targets (design, not built)

Nothing in this document exists yet. Targets are to be built from a few parts that combine freely
in any command: a quantifier ("the second", "the last three", "every"), a unit, a filter ("with",
"starting with", "ending with", "without") and nesting with "in" / "of" to any depth. "The third
through fifth words in the second to last sentence in the third paragraph" and "the first sentence
with moonbase" are then just combinations of parts that already exist. It extends the targets of
phase 2 of [phony-grammar.md](phony-grammar.md) ("Built in phase 2").

## The problem

The user's observation: the grammar already has operators ("with", "containing"), positions
("first", "second", "last") and units. Any of them should work with any other, at any depth, and
for any verb. Today what a target can say depends on which rule it goes through.

What the current grammar reads (checked by parsing with `earwig--parse-rule 'earwig-target` in
batch Emacs):

| Said | Read today |
|------|------------|
| the second paragraph with moonbase | ✗ (only as the words themselves) |
| the second sentence in the second paragraph | ✗ |
| the second sentence in the paragraph with moonbase | ✓ `(nth 2 start sentence (with paragraph moonbase))` |
| the sentence with moonbase in the second paragraph | ✗ read as the sentence with the words "moonbase in the second paragraph" |
| moonbase in the second sentence of the second paragraph | ✗ only one ordinal level deep |
| the first word of the second sentence of this paragraph | ✗ |
| the third to the fifth word | ✗ |
| the next sentence with budget, the last item with milk | ✗ "next" takes only words |
| every sentence with however, every item in this section | ✗ read as searches for the words "sentence with however", "item" |
| the body of the second heading in this section | ✗ |
| the first sentence | `(next 1 sentence)`: "first" means "next" |

Why, in earwig-grammar.el ("Targets"):

1. **Layers, each allowing something different.** Phony can't parse a rule that refers to itself,
   so nesting was built in fixed layers, each listing by hand what it accepts:
   - `earwig-part-units-of` and `earwig-part-ordinal` accept a list of parts that leaves out
     themselves, so they nest one level only.
   - `earwig-target-in` takes any `earwig-part`, which allows two levels.
   - `earwig-part-with` takes no scope at all.
   - `earwig--heading` has a shorter list of its own.
2. **Filters only on a bare unit.** "with / containing" exists only in "the UNIT with WORDS"
   (`earwig-part-with`), not after a quantifier, nor with "every".
3. **"with" finds the nearest only.** `earwig--unit-with` (earwig-edit.el) finds the nearest
   match of the words and takes the unit around it. It never has the list of all the units with
   the words, which "the second paragraph with moonbase" needs.
4. **"first" and "last" change meaning by context.** Without a scope, "the first sentence" is the
   next one and "last" counts back from point. With one, both count from the scope's edges
   (`(within EDGE N UNIT PART)`). Ordinals need a scope.
5. **Ordinals** are a dictionary, `earwig-ordinal`, from "second" to "tenth" ("2nd" to "10th").
   "first" and "last" are another rule.
6. **Ranges are for words only** ("A through B", `earwig-target-through`, `earwig-target-from`).
   Units have counts ("the first three words") but no "the third through fifth word", and there's
   no "from TARGET through TARGET".
7. **"every" takes words only** (`earwig-target-every`), so "every item" looks for the word "item".
8. **Determiners and joining words vary by rule.** `earwig-part-this` takes "this", "the",
   "current"; `earwig-part-with` "the", "this", "that", "a"; the ordinal rule "the", "this".
   `earwig-target-in` and "every" take "in" only, the ordinal rules "in" or "of".
9. **"replace" has its own list** of what it replaces (`earwig-say-replace`, earwig-edit.el:
   words, the next / previous, every) and its own "in PART". "Replace the word this with …"
   isn't covered.

## Design

### The grammar

```
target     := [the start | end of] chain
            | chain through chain                 ; from one target to another
            | A and B, both A and B, each of A … and B   (as today)
chain      := selector ((in | of) selector)*       ; Phony's *, no rule refers to itself
selector   := quantifier? UNIT filter?
            | words: WORDS, the word(s) W, the next / previous W, every W
            | that, the region, the buffer, the parent heading
            | the body of …, everything under …, the subheadings of …
quantifier := this
            | next | previous | last [N]             ; counted from point
            | first | last [N]                       ; counted from the container's edges
            | ORDINAL [to last] | ORDINAL through ORDINAL
            | every | all | each
filter     := with | containing W | starting with W | ending with W | without W
```

Nesting is a **chain**, not recursion: a list of selectors joined by "in" or "of", which Phony
expresses with `*` (as `earwig-target-each` already repeats `earwig--one-target`). Earwig folds the
list into nested specs. That gives any depth without the layers, and every selector can have a
quantifier and a filter at every level. This is the core of the change (suggested, and the basis
of everything agreed below).

Selectors, filters and quantifiers become open rules where that's cheap (suggested), so that a
unit or filter added once works with every verb, at every depth, and in the user's commands through
`earwig-part`. Units already are a dictionary (`earwig-unit`).

### Resolving a target

From the outermost selector (the rightmost words) inwards:

1. The scope is the explicit one from the selector before it, or else the unit's natural
   container (below), found from point.
2. List every UNIT in the scope, in order.
3. Keep those the filter passes.
4. Apply the quantifier to what's left.
5. The ranges found are the scope of the next selector inwards.

Without a quantifier, a singular unit with a filter is the nearest one, as "the sentence with X" is
today. That's `earwig--unit-with`'s behaviour, kept.

What this needs in earwig-edit.el:

- **Listing every unit in a range**, for all units. `earwig--units-in` does it for headings,
  sections, items and links; words, sentences, paragraphs and lines are walked from an edge with
  `earwig--units-near` (`earwig--within-units`).
- **Filters as predicates** on ranges.
- **One kind of spec for a selector.** Today's `this`, `last`, `next`, `with`, `within` and `nth`
  (see the `earwig-target` docstring) become cases of it. `earwig--resolve`, `earwig--spec-text`
  and `earwig--choose` follow.

### Decisions (agreed)

| # | What | Agreed |
|---|------|--------|
| D1 | What an ordinal counts in when no scope is said | Its **natural container**. A word in its sentence; a sentence in its paragraph (a list item or a heading title counts as one); a line in its paragraph; an item or checkbox in its list; a heading or section in its parent's section, the buffer at the top level; a paragraph or link in the heading's own text (its body). Where there are no headings, as outside Org and Markdown, paragraphs and links count in the buffer. "Capitalize the third word" is the third word of this sentence |
| D1′ | An explicit scope | Replaces the natural container, at any depth: "move the second paragraph after the second paragraph of / in the section with moonbase". A **section** scope is the whole section, its own text and its subheadings', in order; "the body of …" is the heading's own text only |
| — | "first" | Counts from the start of the container like the other ordinals, also with a filter: "the first sentence with moonbase". "The first two words" no longer means the next two (breaking) |
| — | A filter and counting | **Filter first, then count**: "the second paragraph with moonbase" is the second of the paragraphs with moonbase |
| D2 | A filter that finds too few in the natural container | **Widen until found**: paragraph → heading's own text → section → buffer, taking the first container with enough. The flash shows where it landed |
| D3 | "last" | **Bare "last [N] UNIT" still counts back from point**: "delete last sentence", "last two words". **Qualified, it counts from the container's end**: with a filter ("the last sentence with moonbase"), an ordinal ("the second to last sentence") or an explicit scope ("the last sentence of this paragraph") |
| D4 | A plural unit without a quantifier | **Every one**: "delete the paragraphs with moonbase" = "every paragraph with moonbase" |
| — | A plural scope | **Applies to each part separately**: "the first sentence of every paragraph" is one sentence per paragraph |
| — | Range wording | **"through"**: "the third through fifth words", "the third through the fifth word" |
| D5 | A range over filtered units, which can have gaps | **Separate ranges**: "delete the second through fourth paragraphs with moonbase" deletes those three; the verb acts on each. "select" can't take several and fails with the count. Without a filter a range has no gaps and is one range |
| D6 | Counting headings and items among nested ones | **Siblings for ordinals** and first / last: under "Plans" with A, B (B.1, B.2) and C, "the third heading" is C. "the next / previous heading / item" stays by position at any level, as today |
| D7 | Filters on the unit "word" | **Match parts of words**: "the word starting with moon", "the word ending with base", "the word containing oon" all find "moonbase". Other units keep whole-word matching |
| D7′ | "ending in" | **Not used, "ending with" only**: it pairs with "starting with" and keeps "in" for scopes ("the sentence ending in budget in the second paragraph" would be ambiguous) |
| D8 | Ordinals | Words from **"first" to "twentieth"**, and **digit forms of any number** ("21st", "42nd"), checked as numbers are |
| D8′ | "paragraph 3", "sentence two" | **No**, ordinals only. "go to line N" keeps meaning buffer line N without a clash with "the third line" (in the paragraph) |
| D9 | "without WORDS" | **Added now**: "delete the sentences without moonbase", "the first item without a date". Only with / without are negated, no "not starting with" (suggested) |
| D10 | What filters match on links and headings | **Links: the visible text or the URL**, for every filter: "open the link ending with pdf" and "the link starting with annual" both find `[[https://x.org/report.pdf][Annual report]]`. **Headings and sections: the title only**, as today, also for "starting / ending with", without stars, TODO keyword, priority and tags |
| D11 | What "replace A with B" replaces | **Any target**: "replace the second word with moon", "replace the last sentence with see you then", "replace moonbase in the second paragraph with base". B replaces the target's text. For words, the case matching and the trailing "in PART" / "everywhere" stay as they are. The extra "with" splits ("replace the sentence with X with Y") are settled by the buffer, as for "swap" |
| D12 | How units other than sentences widen (D2) | **Up the containers**, from the natural container through each one above it: a word: sentence → paragraph → heading's own text → section → parent sections → buffer; a line: paragraph → heading's own text → …; an item or checkbox: its list → parent lists → heading's own text → …; a heading or section: parent section → its parent → … → buffer; a paragraph or link: heading's own text → section → parent sections → buffer |

### Edge cases (agreed as proposed)

1. **Point in no container** (a blank line, before the first heading, outside a list): the
   container just before point, as for the sentence point is just after; else the next one out.
2. **Too few in some parts of a plural scope:** "the second sentence of every paragraph" skips
   paragraphs with one sentence. It fails only if none has one.
3. **Nested items** as a container: an item counts its own text, without its sub-items, so "the
   first word of every item" doesn't count words twice. Overlapping results are merged (today
   `earwig--resolve-and` fails with "Those overlap").
4. **Positions in a chain:**
   - Words (WORDS, the next W, every W) only as the innermost selector, the first said.
   - "the start / end of" only at the front of the whole target. It's an empty place, not a scope.
   - "the body of", "everything under" and "the subheadings of" at any level: "the first sentence
     of the body of the heading with X".
5. **No "and" inside a chain:** "the first word of A and B" is (the first word of A) and B.
6. **"next" and "this" inside an explicit scope:** "next" is the first after point within the
   scope; "this" only works if point is in the scope.
7. **Reversed ranges** ("the fifth through third", or a target through an earlier one) are
   swapped.
8. **Empty units** (blank lines, empty items) aren't counted.

## Options considered

- **Keep layers, add more of them** (a part-of-a-part rule per depth): rejected in favour of the
  chain. Each layer lists by hand what it takes, which is what made capabilities uneven.
- **D1, the paragraph's container:** the whole section (own text and subheadings together), or
  the buffer. The heading's own text was chosen, provided an explicit scope can override it.
- **D1, lines:** the heading's own text, or the buffer (as "go to line N"). The paragraph was
  chosen, as for sentences, and for multi-line blocks (lists of lines, addresses, verse). In Org a
  paragraph is often one line, so "the third line" there finds nothing.
- **D1′, a section scope as its own text only:** rejected; "the body of" says that.
- **D2:** strict (fail and let the user say "in the section with …"), or a filter always counting
  in the buffer. Widening was chosen as more natural, at the cost that where it counts can shift.
- **D3:** "last" always before point, also with filters; or always from the end, symmetric with
  "first", with "previous" taking over "delete last sentence". Rejected: "delete last sentence" is
  the most common correction while dictating.
- **D4:** a plural as the nearest one (singular), or a plural without a count not reading as
  units at all.
- **D5:** one range from the start of the first match to the end of the last, which "select"
  could take but which takes the paragraphs between too.
- **D6:** siblings for "next" too (changes "the next heading", which could no longer step into
  B.1), or any level everywhere ("the third item" landing in a sub-list).
- **D7:** whole words always (word filters nearly useless), or parts of words for every unit (more
  surprises: "the sentence starting with moon" matching "Moonbase is …").
- **D8:** words to "tenth" only; or any spoken ordinal ("twenty first"), the most complete, with
  more parsing. "UNIT N" except for lines, or for all units.
- **D10:** visible text only, or the URL only. For "starting / ending with", visible text only
  was suggested first and dropped: "the link ending with pdf" wouldn't find a described link.
- **D11:** word forms only (words, the word W, the next / previous / every W, each with a chain
  scope), with units replaced through "rewrite"; or "replace" kept as it is.
- **D12:** the natural container and then the buffer (simple, but jumps far); or the natural
  container, the current section, then the buffer, for every unit.
- **Range word "to"** ("the third to the fifth word"): rejected. "to" is already in "second to
  last" (`earwig-ordinal`), so "the second to last word" would be the penultimate word or the
  second word to the end. It's also a destination ("move … to the end of").

## Things to get right when building it

- **"through" twice.** "The third through fifth word" also reads as the words "the third" through
  "fifth word" (`earwig-target-through`). The units reading has no free words, so ranking (fewest
  free words, see earwig-grammar.el's commentary) already prefers it, and the buffer check backs
  it up.
- **More readings.** Each filter is a free-word slot, and "with" already splits "replace A with
  B", "swap A with B" and destinations. "Swap the sentence starting with A with the sentence
  ending with B" has several readings, which the buffer settles. A chain with a filter at every
  level multiplies readings, and checking each lists units in the buffer: cache unit lists per
  command (suggested) and time a long chain.
- **One filter per selector** (suggested): two filters joined by "and" would clash with "A and
  B" targets.
- **Free words before "in"**, as today: "sign in the second paragraph" is either words "sign" in a
  scope or the words "sign in the second paragraph"; the buffer settles it.
- **Widening (D2) may list every sentence in the buffer.** Time it on a large Org file.
- **Widening and explicit scopes:** the ladder is agreed (D2, D12). Whether an explicit scope ever
  widens: suggested not, it's what was said.
- **Determiners in one rule** (suggested): "the", "this", "current" and the misheard "that" / "a"
  that `earwig-part-with` takes today, the same everywhere. "in" and "of" both join a chain.
- **"every", "all", "each":** "all" alone stays the whole buffer; "all paragraphs" is every
  paragraph (suggested). "each of A … and B" stays the forced list.
- **"replace"** (`earwig-say-replace`, `earwig--replace-words`) takes any target as its old text
  (D11). Its `:check` (something to replace) and `earwig--replace-words`, which reads the words
  out of `near` and `every` specs, have to handle targets that aren't words. "The word W" comes
  with it.
- **Headings and items need sibling lists** for D6, where `earwig--units-in` gives headings at any
  level and sections at the outermost level.
- **What a paragraph is** must agree between the unit around point (`earwig--unit-at`) and the new
  listing: list items and heading titles count as paragraphs for sentences (D1).
- **Breaking changes:**
  - "first [N] UNIT" without a scope was the next N; now it counts from the container's start.
  - `earwig-target` spec shapes change. `earwig--spec-text`, `earwig--choose` (which looks for
    `(in (words …) …)`) and `earwig--replace-words` (which looks for `near` and `every`) depend on
    them. `earwig-part-range` takes a spoken string too, which keeps working.
  - Tests in test/earwig-test.el that expect "first" to mean "next" change.
- **Docs and help:** docs/manual.md, the `:help` strings ("what can I say") and the
  `earwig-target` docstring.

## Build order (agreed)

1. **Listing and resolving, no grammar change.** List every unit in a range, for all units;
   filters as predicates; resolve one selector (quantifier, unit, filter) against a scope. Today's
   specs resolve through it, and behaviour stays the same.
2. **The chain.** The rule `selector ((in | of) selector)*` replaces the layers
   (`earwig-part-units-of`, `earwig-part-ordinal`, `earwig-target-in`, `earwig--heading` …), with
   natural containers (D1), widening (D2, D12), the meaning of "first" / "last" (D3), plurals
   (D4), plural scopes applied to each part, and siblings for ordinals (D6). "replace" takes any
   target (D11).
3. **The filters:** "starting with", "ending with", "without", and parts of words for the unit
   "word" (D7), on links and headings as in D10.
4. **Ranges and ordinals:** "ORDINAL through ORDINAL" (D5), ordinals "first" to "twentieth" and
   digit ordinals (D8), and "TARGET through TARGET" between any two targets.
5. **Tests, the manual and "what can I say".**

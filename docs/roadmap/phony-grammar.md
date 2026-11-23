# Command grammar on phony.el (phases 1 and 2 built)

**Status:** phases 1 and 2 are built. Phase 1 (earwig-grammar.el): all commands are Phony rules,
found without "and then" and ranked over all readings, as below under "Built in phase 1". Phase 2
(earwig-edit.el, earwig-move.el): the new targets and the commands taken from cursorfree, as below
under "Built in phase 2". Phase 3 (hatty) is not built. The background below describes Earwig
before phase 1.

Earwig matched its voice commands with regular expressions
and resolved their targets with hand-written parsing. The idea is to define all commands,
Earwig's own and the user's, as a grammar in [phony.el](https://github.com/ErikPrantare/phony.el),
in Earwig's own English words. Some commands are taken from
[cursorfree.el](https://github.com/ErikPrantare/cursorfree.el), but without depending on it.
Commands would be found in an utterance
without needing "and then" between them. Feature parity is a requirement. Where parity isn't easily
achievable, only minor changes in how Earwig is used are acceptable.

The plan is to try it first (agreed). What Phony lacks is worked around in Earwig for now. The
user will contact Phony's author once the approach is proven, with the upstream requests below
as feedback.

## Background

### Earwig today

- **Commands:**
  - `earwig-commands` (earwig-commands.el) is a flat list of `(PATTERN FUNCTION HELP)`, gathering
    `earwig-edit-commands`, `earwig-structure-commands` and `earwig-org-commands`.
  - `earwig--match-command` tries `earwig-extra-commands` first, then `earwig-commands`, each
    regexp anchored to the whole text. The first match wins, and its groups are the arguments.
  - `earwig--command-text` strips punctuation and squeezes spaces first.
  - `earwig-find-command` retries with `earwig-apply-corrections` (`earwig-corrections-commands`)
    when the text as said doesn't match.
- **Chaining:** `earwig-find-commands` splits at `earwig-chain-words` ("and then",
  `earwig--chain-cuts`). It backtracks so that a part that isn't a command stays joined to the next.
  That's why "replace and then with so" is one command. `earwig-run-command` runs the steps in
  turn, adds an `undo-boundary` after each and stops at the first that fails.
- **Targets** are parsed by hand in earwig-edit.el:
  1. `earwig--target` first tries `earwig--structural-range`: the region, "that", this or
     last/next N units, the whole buffer.
  2. Then `earwig--scoped` for "WORDS in TARGET", which only counts when TARGET is a part of the
     buffer, so "log in screen" stays words.
  3. Then `earwig--through-range` for "A through B".
  4. Then the nearest place the words appear (`earwig--nearest`).
- **Choosing by buffer content:** `earwig--splits` returns every way to split at a separator.
  The first split that finds something in the buffer wins. `earwig-cmd-replace` does the same with
  " with ", so A and B may themselves contain "with".
- **Numbers:** `earwig-parse-number` reads digits and words, "1,000", decimals and digit runs
  ("nineteen eighty-four").
- **Auto-stop:** `earwig--command-heard-complete-p` (earwig.el) re-runs `earwig-find-commands` on
  what's heard so far. "Incomplete" ("go to line" before its number) only means "no match yet".
  The streaming preview (earwig-stream.el) calls `earwig-find-command` on each part to colour it.
- **Help:** "what can I say" (`earwig-cmd-help`) shows the hand-written HELP strings.
- **Helpers for user commands:** `earwig-part-range`, `earwig-when-regexp` and
  `earwig-spoken-time` (earwig-org.el), and `earwig-raw-command`.

### phony.el (v3.0.0, 2026-11-15, AGPL-3)

A grammar engine for voice commands:

- **`phony-defun NAME PATTERN BODY`:** patterns are literals (several words allowed, "hello
  emacs"), references to rules, `seq`, `?`, `*`, `+` and `|`. `(ARG PAT)` binds a value. Rules
  return values to the rules that use them. Keywords:
  - `:interactive`
  - `:mode`
  - `:anchor-beginning` / `:anchor-end`
  - `:contributes-to`
  - `:provides`
  - `:module`
- **Dictionaries** (`phony-define-dictionary`): spoken words → value, changeable at runtime
  (`phony-dictionary-put`, `phony-set-dictionary-alist`). They're matched through a trie.
- **Open rules** (`phony-define-open-rule`): alternatives that other rules add themselves to.
- **Interfaces** (`phony-define-interface`): implementations the user can swap.
- **Modules:** rule packs that do nothing until `phony-enable-module`.
- **Standard library** (phony-stdlib.el): `word`, `phrase`, `digit`, `number` (spoken words
  only), `letter`, `non-alphanumeric-character`, `graphical-character`.
- **Talon export:** it writes Talon files, so Talon only listens for what the grammar allows.
  Talon is the only speech backend.
- **Its own parser:**
  - `phony-evaluate` parses a string as a sequence of interactive rules, with no separator
    between them.
  - It splits on whitespace only, and the case and punctuation normalizer
    (`phony-experimental-set-parser-literal-normalizer`) is experimental.
  - When there's more than one reading it **picks an arbitrary one** (`(car parses)`). Rule
    bodies run after parsing, so they can't reject a reading.
  - `phony-evaluate-as-event` runs each command through the command loop, via simulacrum, so undo
    and keyboard macros work. It runs on the next input processing, not right away.
- The parser is a step-by-step parser combinator (phony-parser.el). Each step knows which
  tokens could come next (`phony-parser--wants`). `phony-parser--parse-utterance` returns **all**
  readings, but it is private.
- **Dependencies:** simulacrum.
- **Pace of change:** three major versions between June and November 2026.
  `phony-evaluate` has only been stable since 3.0.0.

### cursorfree.el (v1.1.0, same author)

A Cursorless-like language on Phony (cursorfree-phony.el), plus a library usable without voice
(cursorfree-core.el):

- **Commands** are `<action> <target>`. A target is a left-to-right pipeline:
  - primitives: `row 42`, `this`, `that`, `clip`, hatty hats
  - modifiers, written after the target: `block`, `line`, `tail`, `end`, `every instance`,
    `next`
  - infixes: `past`, `and`
- **Actions:** take, chuck, bring/move/swap A to B, wrap, and so on.
- **Extending it:** through the open rules `cursorfree-primitive` and `cursorfree-modifier`, and
  the generic functions `cursorfree-get` and `cursorfree-put`.
- **Hats** need [hatty.el](https://github.com/ErikPrantare/hatty.el).

### Why not cursorfree's spoken language as it is

With both on, some words would mean different things. Only one reading would run, picked
arbitrarily:

| Word | Cursorfree | Earwig | Goes wrong |
|------|------------|--------|------------|
| that | target of the last action | the selection, else the last dictation | "capitalize that" after dictating |
| this | point, an empty spot, when nothing is selected | the selection, else the last dictation | "delete this" after dictating deletes nothing |
| and | joins two targets | a word, and part of "and then" | "delete salt and pepper" deletes two things |
| next | the next place the same text appears | "next two lines" after point | "select next line" |
| word | "word foo" is the string "foo" | "last word" before point | "copy word budget" |
| join | lines into one line | sentences split by a period | "join last sentence" |
| row N | line N modulo 100 | "go to line N" is line N | lands on line 142 for 42 |

"copy" means the same in both. "bottom" doesn't clash, as Earwig only says "go to bottom".

Modifiers after the target read oddly in prose:

| Cursorfree | Earwig-style English |
|------------|----------------------|
| `chuck row 42 block` | "delete the paragraph at line 42" |
| `take row 12 tail` | "select from line 12 to the end of the line" |
| `jump sentence end` | "go to the end of the sentence" |
| `copy row 5 past row 9 block` | "copy the paragraphs from line 5 to line 9" |
| `chuck blue bat every instance` | "delete every 'budget'" |

## Design

### All commands in Phony (agreed, if the switch is made)

The user's decision: if Earwig switches to Phony, **all** commands use it, including the
regexp ones in `earwig-extra-commands`. An earlier suggestion kept a regexp layer for parity. That
suggestion is dropped.

This is a breaking change, as regexps match characters and Phony matches words, so there's no
automatic conversion. The manual's examples (docs/manual.md, "Commands of your own") would become
something like the following. It's a sketch: `earwig-part` and `earwig-when` are new rules, and
`earwig-region-or-error` doesn't exist yet.

```elisp
(phony-defun my/git-status ((| "magit" "magit status" (seq (| "git" "good") "status")))
  (magit-status))

(phony-defun my/count-words ("count words" (? "in" (part earwig-part)))
  (let ((range (or part (earwig-region-or-error))))
    (message "%d words" (count-words (car range) (cdr range)))))

(phony-defun my/remind ("remind me" (? (time earwig-when)) "to" (task phrase))
  (my/capture-reminder time task))
```

Details of the switch:

- `earwig-part-range` and `earwig-when-regexp` become rules that return values (`earwig-part`,
  `earwig-when`). User commands then compose with Earwig's units and targets.
- HELP strings become docstrings, or "what can I say" is generated from the patterns.

### Earwig's own language (agreed)

- **Not** cursorfree's spoken language. Earwig's own command words, in English prefix order
  (agreed). All of the clashes above go away, as Earwig picks the words.
- **Taken from cursorfree** (agreed): the commands and targets listed below, which feel natural
  in prose and make editing more efficient.
- **Hatty** (hats over tokens) most likely comes in a later phase (agreed).
- **Targets that compose:** units, counts, "through" and "in" become open rules. A unit added once
  works with every verb, "last N", "in TARGET" and "format".
- **One word, several meanings by structure:** "next two lines" (the units after point), "next
  one" (the next match, `earwig-cmd-next-match`), "the next budget" (the next place the words
  appear). Where both readings fit ("select next line"), ranking decides (below). Today units are
  tried first.

### Targets

| Target | Example | Status |
|--------|---------|--------|
| **that** | the selection if there is one; otherwise the most recent text that went in, whether dictated or put in by a command (moved, copied, duplicated, wrapped, changed). This is cursorfree's "that". Today it is the selection, else the last dictation (`earwig--that`) | agreed |
| **the UNIT with WORDS** | "the sentence with however", "the item with eggs" (cursorfree's `line`, `block`, `sentence` modifiers in English order) | agreed |
| **the start / end of TARGET** | "go to the end of the paragraph with budget" (cursorfree's `beginning`, `end`) | agreed |
| **every WORDS** [in TARGET] | "format bold every deadline in this section" (cursorfree's `every instance`) | agreed |
| **the next WORDS** | "select the next budget" (cursorfree's `next`); "the previous WORDS" goes with it | agreed |
| **A and B** | "delete very and really", "move the item with milk and the item with eggs after the item with bread" (cursorfree's `and`); see below | agreed, where unambiguous |
| **headings, sections and bodies** | see below | agreed to include; words suggested |

"and" joins targets only where that's unambiguous (agreed). The suggested rule follows the
ranking for command boundaries:
- If the whole phrase is in the buffer ("salt and pepper"), it's one target.
- If only both halves are, it's two.
- If neither reading finds anything, the command fails, as it does today.

Headings, for Org and Markdown (the words are suggestions):

| Say | Means |
|-----|-------|
| this heading | the title of the heading point is under, without stars, TODO keyword, priority or tags (as formatting already skips them) |
| this section | that heading with its body and subheadings |
| the body of this heading, the text under this heading | its own text: after the heading line and, in Org, after the planning line (SCHEDULED, DEADLINE) and drawers (properties, logbook), up to its first subheading |
| go into TARGET | to the end of the heading's own text, before its first subheading, to add text there: "go into the heading with budget" (agreed) |
| the heading above, the parent heading | one level up (agreed) |
| the previous heading, the next heading | by position, at any level |
| the heading / section with WORDS | whose title has the words |
| the subheadings [of this heading] | its children |
| last / next N headings / sections | counted, like the other units |
| under TARGET | a destination: as the last child of that heading, the level adjusted |

"the heading above" means the parent heading (agreed). For the heading before it at any level,
say "the previous heading". Examples:

- "title case this heading"
- "move this section after the section with timeline": the subtree moves, as a sibling there
- "move the section with budget under the heading with plans": it becomes a subheading
- "swap this section with the next section"
- "new subheading under the heading with plans", then dictate its title
- "focus on the section with budget"
- "okay, go into the heading with budget", dictate a paragraph, then "go back"

**Body as a target** (agreed). It came up with a heading that has a SCHEDULED line under it.
Going to the heading isn't enough to add to its content. You need to name the body and go to
its end, then dictate:

```org
** Budget review
SCHEDULED: <2026-11-24 Tue>
:PROPERTIES: …
:END:
Numbers from finance are in.        ← "the body of the heading with budget review"
*** Open questions                   ← not part of the body
```

- **The start of the body** is after the planning line and drawers. Org's
  `org-end-of-meta-data` finds it.
- **The end** is before the first subheading, without trailing blank lines.
- **An empty body:** start and end are the same place. Going there opens a line for the text.
- **In Markdown,** the body is the lines after the heading, up to the next heading of any level.
- **Other verbs** work on it too: "select the body of this heading", "move the body of the
  heading with draft under the heading with final".

### Commands taken from cursorfree (agreed)

The commands are agreed. Earwig's words for them are suggestions.

| Say | From cursorfree | Simple | Complex, or with other commands |
|-----|-----------------|--------|---------------------------------|
| move A before / after / under B, or to the start / end of B | `move` | "move last sentence after budget" | "move the item with sharks after the item with Igor" (one command for the manual's four); "move the sentence with however to the end of this paragraph and then replace however with still in that" |
| swap A with B | `swap` | "swap Monday with Tuesday" | "swap the paragraph with budget with the paragraph with timeline" (the second "with" is settled by the buffer, as in "replace") |
| copy A before / after / to the start / end of B | `bring` | "copy last sentence to the end of the paragraph with summary" | "copy the item with milk after the item with bread in the shopping section" |
| rewrite TARGET: delete it and dictate in its place | `change` | "okay, rewrite last sentence", then keep talking | "okay, rewrite from because through Friday in the paragraph with budget", dictate, then "go back" |
| duplicate TARGET | `clone` | "duplicate this line" | "duplicate the item with call mum and then replace mum with dad in that" |
| wrap TARGET in quotes / parentheses / brackets / dashes / commas | `wrap` | "wrap last three words in quotes" (typographic where the buffer uses them) | "wrap from as noted through earlier in commas" for an aside |
| unwrap TARGET, remove the parentheses around TARGET | `unwrap` | "unwrap that" | "remove the quotes around every Earwig in this section" |
| rewrap TARGET in … | `rewrap` | "rewrap that in brackets" | "rewrap the parentheses with as noted earlier in dashes": `(as noted earlier)` becomes `— as noted earlier —` |
| new paragraph / item / heading / subheading before / after / under TARGET | `break`, `drink`, `pour`, `drop`, `float` | "new paragraph before however" (splits the paragraph there) | "okay, new item after the item with eggs", dictate "buy flour", then "go back" |
| open TARGET: follow a link | `pick` | "open the link with roadmap" | "open the link in the last paragraph" |
| focus on TARGET, show everything | `narrow` | "focus on this section" | "focus on the section with budget and then replace cost with price everywhere and then show everything" ("everywhere" is only the section) |
| where is / show me TARGET | `flash` | "where is the sentence with however", to check a target before acting | also as automatic feedback on what a command acted on |

Considered and not taken:
- reflow (`tidy`)
- join lines (`join`, which clashes with "join last sentence")
- list every (`hunt`, which overlaps with "search")
- center / show at the top (`crown`, `center`, `bottom`)
- line-number ranges (`row`, `past`)

Skipped as code-oriented or already in Earwig:
- Earwig already has select, copy, delete, go before/after, the case verbs and "comment that".
- Code-oriented: `fuse`, `paint`, `trim`, `token`, `symbol`, `string`, `indent`, `help`.
- Little use in prose: `car`, `word`, `numb`, `clip`, `primary`, `source`, `its`.
- Not text: window targets (`split`).

### Wording (agreed)

The wording below was settled item by item. Where the tables above differ, this table wins.
Synonyms are cheap in Phony, but each one lengthens "what can I say" and adds a reading to rank.

| # | What | Agreed wording | Notes |
|---|------|----------------|-------|
| 1 | move | "move A before / after / under B", "move A to the start / end of B" | "move" only; "put" stays free for wrapping. No overwriting "move A to B" as in cursorfree, since "replace" covers that |
| 2 | swap | "swap A with B" | "with" only, parallel to "replace A with B"; not "swap A and B". The buffer settles which "with" splits the two |
| 3 | copy to | "copy A before / after / under B", "copy A to the start / end of B" | extends the existing "copy", with move's destinations. Without a destination it copies to the kill ring, as now. "yank" stays kill-ring only |
| 4 | delete and dictate in place | "rewrite TARGET" | not cursorfree's "change", which sounds like it wants a replacement word, as "replace" does. That leaves "change" free |
| 5 | duplicate | "duplicate TARGET" | not "clone". The copy goes right after it, and "that" then means the copy |
| 6 | wrap | "put PAIR around TARGET", "wrap TARGET in PAIR" | both |
| 7 | unwrap | "remove the PAIR around TARGET", "unwrap TARGET" | both. "unwrap" takes the nearest pair around the target |
| 8 | rewrap | "replace the PAIR around TARGET with PAIR", "change the PAIR around TARGET to PAIR" | both. "replace" tells a pair from words by the pair's name followed by "around" |
| 9 | the pairs | quotes, single quotes, parentheses (also "brackets"), square brackets, dashes, commas | "brackets" alone means parentheses. Quotes follow the buffer: typographic where it already uses them, straight otherwise. Dashes are configurable, spaced em dashes by default ("x — aside — y") |
| 10 | new … elsewhere | "new paragraph / item / heading before / after / under TARGET", "new subheading under TARGET", and the same with "add a" ("add a heading after the section with budget") | both. "new heading after the heading with budget" could also be a title; a target that exists in the buffer wins |
| 11 | follow a link | "open the link with WORDS", "open that link", "open the link in TARGET" | "open" only. Told apart from "open agenda" by "link" |
| 12 | narrow | "focus on TARGET" / "show everything", "narrow to TARGET" / "widen" | both pairs |
| 13 | flash | "where is TARGET", "show me TARGET" | both, not "flash". Scrolls there if it's off-screen. "show me everything" flashes the whole buffer; "show everything" widens |
| 14 | go into | "go into TARGET", "add to TARGET" | both. To the end of the heading's own text, before its first subheading |
| 15 | that | "that", "this", "it" | all three the same: the selection, else the most recent text that went in |
| 16 | the unit with words | "the sentence / paragraph / line / item with WORDS", "… containing WORDS" | both. "containing" helps where "with" would stack up, as in "replace" and "swap" |
| 18 | every | "every WORDS", "each WORDS" [in TARGET] | both. "all" stays the whole buffer |
| 19 | next / previous | "the next / previous WORDS", "the following / preceding WORDS" | both. "last" stays a count of units |
| 17 | start / end | "the start / beginning / end of TARGET" | as today, for any target |
| 20 | and | "A and B", "both A and B", "each of A, B and C" | "and" where the buffer allows only one reading. "both" forces two targets, and "each of" forces any number, as separate items. Pauses (Orukeet's commas) aren't relied on |
| 21 | the title | "this heading", "this headline" | both ("headline" is Org's term). The title only, without stars, TODO keyword, priority or tags |
| 22 | heading with everything under it | "this section", "this subtree" | both ("subtree" is Org's term) |
| 23 | its own text | "the body of TARGET", "the text under TARGET" | both. This "under" is followed by a heading, not by a verb's first target, so it isn't the destination "under" |
| 24 | the parent | "the heading above", "the parent heading" | agreed earlier |
| 25 | by position | "the previous heading", "the next heading" | The bare command "next heading", which creates a heading today (earwig-structure.el), is dropped, so "next heading" always means the one after. "new heading" creates. A breaking change |
| 25a | next item | — | The bare commands "next item" and "next bullet" are dropped too, so "the next item" always means the one after. "new item" creates. A breaking change |
| 26 | as a child | "under TARGET", "as a subheading of TARGET", "as a sub-item of TARGET" | both. A destination: the last child, with the level adjusted |
| 27 | by title | "the heading with WORDS", "the heading containing WORDS" | as for other units (#16); not "called" |
| 28 | children | "the subheadings of TARGET"; "everything under TARGET" | different targets. "the subheadings" is the children only; "everything under" is the body and the subheadings, the section without its heading line |
| 29 | list item | "this item", "this bullet", "the item / bullet with WORDS" | both, as "new bullet" already is |

### Implementing them: in Earwig, with no dependency on cursorfree (agreed)

The commands taken from cursorfree are reimplemented in Earwig, and Earwig doesn't depend on
cursorfree (agreed). Why not use cursorfree directly:

1. **No hard dependency that isn't really needed** (the user's principle). Each dependency can
   bring incompatibilities later. cursorfree is aimed at code and Earwig at structured
   dictation, so the two will change in different directions. Phony is the one dependency the
   trial needs.
2. **It would add more than itself.** The package needs phony ≥ 2.0.0, and cursorfree-core
   requires `eww` at load.
3. **It does little of the work.** Each command is a few lines over Emacs primitives (table
   below). What makes them right for prose is already in Earwig:
   - spacing and capitals
   - whole-word matching that ignores punctuation
   - Org and Markdown structure
   - evil, undo and "go back"
   That would have to be wrapped around every call to cursorfree anyway.
4. **Two target models.** Earwig's ranges would have to be translated to and from cursorfree's
   target types (generic functions over its own structs) at every call.
5. **Its "every" isn't Earwig's.** It searches literally, case-sensitively and not by whole
   words, and acting on several targets needs multiple-cursors.
6. **Licence.** cursorfree is AGPL-3. Reimplementing the behaviour, not copying code, keeps
   Earwig's licence simple.

What cursorfree-core does for each command taken, and what Earwig needs:

| Command | What cursorfree-core does | What Earwig needs on top |
|---------|---------------------------|--------------------------|
| move, copy to, swap, duplicate | `cursorfree-get` / `cursorfree-put` and delete; a few lines each | spacing and capitals as for paste (`earwig--space-pasted`), whole lines as lines (`earwig--paste-lines`), evil, one undo step, "that" set to what went in |
| change | jump, then delete | tidying the gap (`earwig--tidy-gap`), dictation following point, "go back" (`earwig--go-commands`) |
| wrap, unwrap, rewrap | inserts the character pair; finds enclosing delimiters by the syntax table (`cursorfree--bounds-outside-at-point`) | typographic quotes, dashes and commas, which text-mode syntax tables don't pair |
| every, the next | literal `search-forward`, case-sensitive and not whole-word; several targets go through multiple-cursors | Earwig's whole-word, punctuation-insensitive matching (`earwig--matches`, `earwig--search`) |
| the UNIT with WORDS, start / end | expands by `thing-at-point` | Earwig's own units, and Org and Markdown headings and items |
| new paragraph / item / heading … | inserts blank lines (`cursorfree-drink` and the others) | earwig-structure.el's heading and item logic, which is Org- and Markdown-aware |
| open | `cursorfree-dwim-follow`: button, shr link, widget, or a per-mode function | `org-open-at-point`, and Markdown's link following |
| focus on | `narrow-to-region` | `org-narrow-to-subtree` for sections, and `widen` |
| flash | `pulse-momentary-highlight-region` (built into Emacs) | nothing |

What Earwig needs for this is a target model of its own:
- a list of ranges, as markers, since "every" and "and" give several
- whether they are whole lines
- the word regexp, for "next one"

Verbs act on several ranges from the last to the first. "change every …" (dictating into
several places at once) is out unless it's done another way; cursorfree needs multiple-cursors
for it.

Later, possibly with hatty: an optional `earwig-cursorfree.el`, loaded only when cursorfree is
installed (`with-eval-after-load`). It would convert Earwig's ranges to cursorfree targets and
add Earwig's targets to `cursorfree-primitive`. Earwig's own grammar would not refer to it.

### Command boundaries found automatically (agreed, from the start)

Boundaries between commands are found automatically from the first version (agreed). "and
then" stays as an optional separator (agreed). Phony already parses commands said one after
another. When every slot is closed (units, counts, numbers, names from a dictionary), there's one
reading:
"select last sentence cut that go to bottom paste".

Free-word slots make it ambiguous. "select budget cut that" is either select "budget cut that",
or select "budget" then cut that. Suggested ranking of the readings (the order isn't settled):

1. **Check what can be checked.**
   - Words to find must be in the buffer.
   - Names must be in their dictionary: buffers, headings, Emacs commands.
   - Numbers must parse.
   - A reading that leaves a bare "replace" fails, so "replace and then with so" stays one
     command.
2. **Free text that can't be checked** (search TEXT, "remind me to TASK") runs to the end of what
   was said, or to "and then". So "search budget go to top" searches for all of it, and "search
   budget and then go to top" splits.
3. **Pauses break ties.** Orukeet puts punctuation where you paused, and Earwig strips it today
   (`earwig--command-text`). "Delete milk. Paste." favours two commands.
4. **Otherwise the fewest commands wins.**

One way to keep "and then" as a separator: an interactive rule matching "and then" that does
nothing. Readings are checked one command at a time against the buffer as it is
when that command runs, since a "cut" changes the buffer for the targets after it:

```
parse utterance → all readings
loop:
  first commands of the remaining readings → check each against the buffer, rank → winner
  run the winner (own undo step; a failure stops the chain, as now)
  keep the readings that start with the winner; drop it from each
```

The preview already marks boundaries (`▶ select budget ▶ cut that`), and "cancel" still applies.

### What else Phony would give Earwig

- **Better auto-stop:**
  - stop as soon as nothing more can follow ("go to top")
  - wait for `earwig-command-auto-stop-incomplete` only while what's said can still go on
    ("go to line …")
  - give up early on what can't become a command
  - the preview could show what's expected next ("go to line ▸ N")
- **Dictionaries filled at runtime** limit "switch to NAME" and "go to heading NAME" to names that
  exist: buffers, Org headings, project files.
- **`:mode`** instead of checks while running. **Modules** for opt-in packs: Org, Magit, the user's
  own.
- **Keyboard macros** that record voice commands, through the event path.
- **Talon, optionally:** a user who has Talon could use the same grammar for recognizing
  commands, while Orukeet keeps dictation.

## Keeping parity

| Today | With Phony |
|-------|------------|
| Choosing by buffer content (`earwig--splits`, `earwig--scoped`, `earwig-cmd-replace`) | ranking over all readings (above) |
| "and then" chaining, stop on failure | automatic boundaries; "and then" as an optional separator; stop on failure as now |
| `earwig--command-text`, case ignored | strip punctuation (keep where pauses were, for ranking) and lowercase before Phony, or use the experimental normalizer; free text keeps `earwig-raw-command` |
| `earwig-apply-corrections` retry | unchanged, as a pass before Phony |
| `earwig-parse-number` | an Earwig provider for the `number` interface; Orukeet writes digits ("42"), which no finite dictionary matches, so it needs a check on single words (see upstream) or ranking |
| "okay" while dictating, no match → dictation | unchanged; more word sequences now parse as commands, so dictation that starts with "okay" is somewhat likelier to run |
| `earwig-extra-commands` regexps | rewritten as `phony-defun` (breaking; see above) |

## Things to get right when building it

- **No speech backend.** `phony-evaluate` uses `phony--exported-grammar`, which only
  `phony--export-all` sets. That function:
  - needs `phony-mode`
  - offers to start the Emacs server
  - runs `phony--sync-state` on a 0.1 s idle timer, writing `active-rules`
  - calls `phony-export-function`, the Talon export

  For the trial, work around it: set `phony-export-function` to `ignore`, and deal with the
  server prompt and the timer in Earwig. A mode with no speech backend is upstream request 2.
- **Event path versus stopping on failure.** `phony-evaluate-as-event` defers commands to the
  command loop, so Earwig can't stop the chain when one fails. Evaluating the readings directly
  keeps stopping on failure but needs extra work for macro recording.
- **Number of readings.** Readings multiply with the number of free-word slots. That's fine for
  short utterances; long chains should be tried.
- **Tests.** test/earwig-test.el has 74 tests, many of them about matching. They have to carry
  over.
- **Licence.** Phony and cursorfree are AGPL-3. Earwig is GPL-3. Thought to be compatible as
  separate packages (GPLv3 §13); not checked further. Code isn't copied from either into Earwig.
- **Moving sections.** Moving a section moves its subtree and adjusts the levels, as a sibling
  after "before / after" and as a child after "under". In Markdown that's on `#` headings outside
  code blocks, as earwig-structure.el does.
- **Several targets.** "every" and "and" give several ranges. Verbs act on them from the last to
  the first, or on markers, so earlier edits don't shift later ranges. The whole command is one
  undo step.

## Upstream requests (phony.el)

For now Earwig works around these (agreed): it calls the private functions and handles the rest
itself. The requests go to Phony's author as feedback once the approach is proven, so the
workarounds should be easy to find and replace later.

1. A public API returning all readings (`phony-parser--parse-utterance` exists, privately),
   and an evaluator for any prepared grammar (`phony--evaluate-ast` only knows the exported
   one). To find where commands start and end, Earwig also needs which spans parse: the readings
   of every prefix from a given word, with rule anchors applied. For now it steps
   `phony-parser--parser` itself and checks `phony--procedure-rule-anchor-beginning-p` and
   `-end-p`.
2. A mode with no speech backend: no Talon export, no server prompt, no active-rules timer. With
   it, a public prepared grammar and a hook run when a rule changes. For now Earwig prepares its
   own (`phony--prepare-grammar`) and advises `phony-request-export` to know when to do it again.
3. A public pattern that accepts a word only if a test passes, for digits like "42"
   (`phony-parser--guard` exists internally). The alternative is to check in Earwig's ranking.
4. The literal normalizer out of experimental, set per parse or per grammar, and changing it
   clears the parser's cache. For now Earwig binds `phony-parser--literal-normalizer` and
   increments `phony-parser--current-generation` itself.
5. Rules that refer to themselves, directly or through other rules. Phony builds its parsers
   eagerly, so it can't. For now targets are layered (see "Built in phase 2"), and a part's
   chain ("the first word of the second sentence in …") is a repeated `earwig--link`, nested
   afterwards by `earwig--fold-chain`.
6. Public access to rules and patterns: a grammar's rules, and a rule's name, docstring, pattern,
   function and kind (procedure, dictionary, open rule), and walking a pattern. Help
   (`earwig--pattern-help`, `earwig--user-commands`) uses about 15 private `phony-pattern--`
   functions for that. A function that shows a pattern as text would cover most of it.
7. A public way to extend `phony-defun` with keywords, or to get a pattern's argument names.
   `earwig-defcommand` calls `phony--collect-arguments` and `phony--expand-implicit-arguments` to
   build its `:check`.
8. Public names for the built-in word and phrase patterns, `phony--builtin-word` and
   `phony--builtin-phrase`, which `earwig-number`, `earwig-words` and `earwig-text` use.

## Options considered

- **Enable `cursorfree-phony-mode` as it is:** rejected because of the clashes and the
  postfix order above.
- **Phony behind the existing dispatch, keeping a regexp layer for `earwig-extra-commands`,
  `phrase` targets resolved by `earwig--target`, and "and then":** suggested as a first phase for
  easy parity. Superseded by the user's decision that all commands use Phony.
- **Keep "and then" as the only separator:** rejected. Boundaries are found automatically from
  the start, and "and then" stays optional.
- **Wait for the upstream changes before building:** rejected. The user tries it first with
  workarounds and gives feedback upstream once it's proven.
- **cursorfree-core under the hood** for the commands taken: Earwig would translate its ranges to
  cursorfree targets and call `cursorfree-do-move` and the others. Rejected, for the reasons in
  "Implementing them" above.
- **Passing commands through to cursorfree's own grammar** (`cursorfree-phony-mode`): rejected,
  for the clashes above.
- **Reimplementing in Earwig:** agreed. Each command is a few lines over Emacs primitives and
  Earwig's existing range, paste and structure code. An optional bridge can come with hatty.
- **Suggested phases (only hatty's place is agreed):**
  1. All commands on Phony, with automatic boundaries and ranking over readings. Closed slots
     are in the grammar, and free-word slots are resolved by Earwig.
  2. The new targets as open rules, including headings and sections. The commands taken from
     cursorfree, reimplemented in Earwig.
  3. Hatty, most likely in a later phase (agreed), with the optional `earwig-cursorfree.el`.

## Built in phase 1

- **earwig-grammar.el** holds the workarounds, `earwig-defcommand` (a `phony-defun` with `:help`,
  `:check` and `:go`), the shared rules (`earwig-number`, `earwig-words`, `earwig-text`, and the
  open rules `earwig-part` and `earwig-target`), and finding, ranking and running commands. The
  other files define their commands as rules next to the functions they call.
- **Finding commands:** instead of enumerating every reading of the whole utterance, Earwig steps
  Phony's parser from each word position and records which commands end where. Readings are
  paths through that table, so spans (for `earwig-raw-command` and pauses) come for free and
  readings aren't multiplied out. 35 words take under 0.05 s, uncompiled.
- **Ranking, as built** (the order was open): readings that can't be evaluated (a number that
  doesn't parse) only to say so; then the buffer check; greedy free text only before "and then";
  fewest "and then" taken into commands; fewest pauses inside commands; fewest commands; the
  user's rules before Earwig's; fewest free words; free words split as early as possible.
  Without the buffer (preview, auto-stop, `earwig-find-commands`) fewest free words comes before
  fewest commands, as words to find can't be ruled out then.
- **Checks:** a command's arguments are evaluated before it runs, so `earwig-number` rules out
  readings by signalling. Every `earwig-target` value is resolved against the buffer, and
  `:check` covers the rest ("replace" has something to replace, "select" alone has a region).
- **Help** stays hand-written for Earwig's commands (`:help`); the user's rules are listed from
  their patterns, with their docstring's first line.
- **Direct evaluation**, not the event path: the chain still stops at the first failure, and each
  command is its own undo step. Keyboard macros of voice commands aren't there.
- **Numbers:** `earwig-number` is Earwig's own rule over any words, checked by
  `earwig-parse-number`, rather than a provider of Phony's `number` interface. A provider without
  a module would take over `number` for all of the user's Phony rules.
- **Breaking:** `earwig-extra-commands` is obsolete; Earwig warns once if it's set. The bare
  commands "next heading", "next item" and "next bullet" stayed until phase 2 made "the next
  heading" a target. `earwig-when-regexp` became the dictionary `earwig-when`, and
  `earwig-part-range` takes an `earwig-part` value (or still a spoken string).
- **Not done:** the better auto-stop from `phony-parser--wants` and dictionaries filled at
  runtime for names (buffers, headings).

## Built in phase 2

- **Targets** are layered, as Phony can't build a rule that refers to itself (its parsers are built
  eagerly): `earwig--simple-target` (parts, words, A through B, WORDS in PART, the next WORDS), then
  `earwig--one-target` (also the start or end of one of those, and every WORDS), then "A and B",
  "both A and B" and "each of A … and B" of those. Parts under a heading ("the body of", "everything
  under", "the subheadings of") take `earwig--heading`, a part that names a heading. Destinations are
  the open rule `earwig-destination`.
- **New `earwig-part`s:** "the UNIT with / containing WORDS", "the parent heading", the body, everything under, the subheadings. So they work as scopes too: "replace cost
  with price in the section with budget". UNIT gained heading (headline), section (subtree), item
  (bullet) and link, so "this item", "the next heading", "last two sections" and "the link with
  roadmap" come from the existing rules.
- **Ranges:** a target resolves to a list of ranges, `(BEG END LINE-P REGEXP UNIT)`, in buffer
  order (`earwig--ranges`). UNIT says how the text moves: a section with its levels, lines, a
  paragraph, or text. Verbs act on several ranges from the last, in one undo step
  (`earwig--one-undo-step`, a change group); "select" takes one only. `earwig-target-ranges` is
  the public form; `earwig-target-range` signals for several.
- **How the open points were settled:**
  - Headings are counted by position at any level ("the next heading"); sections at the level of
    the one point is in, not past its parent ("the next section"), so "swap this section with the
    next section" swaps siblings. Items by position, at any level.
  - "the next WORDS" starts after point and "the previous WORDS" ends before it, so after "go before
    budget", "the next budget" is the one after.
  - "A and B" of words is one target when "A and B" is in the buffer as words (that reading fails
    its check); "both" and "each of" force several.
  - "everything under" starts after Org's planning line and drawers, as the body does, so deleting
    it keeps the schedule.
  - "new paragraph before WORDS" in the middle of a paragraph splits it, with the new, empty
    paragraph between; next to a paragraph, section or item it goes beside it.
  - "unwrap" takes off quotes and brackets only; commas and dashes go when named ("remove the commas
    around …"), and are found only right next to the target.
  - "change every …" (dictating into several places) is left out.
  - The bare commands "next heading", "next item" and "next bullet" are dropped (wording #25, #25a).
  - "go to the start of line | sentence | paragraph" became "go to the start / end of TARGET",
    reading the old phrases the same way. "go before / after" takes any target.
- **"that"** is the region, else the text that went in last: `earwig--put` records what a command
  put in, with the `earwig--last-dictation` of the time, so a later dictation is newer.
- **Flash:** what a command put in flashes (`earwig-flash`, an overlay, so "where is every budget"
  shows them all), for `earwig-flash-duration` seconds (1.5).
- **After the phase 2 review** (tmp/demo/phase2-test-plan.md):
  - "WORDS in PART" is every place WORDS are in PART, as "replace A with B in PART" already was;
    commands that act on one place take the nearest (`earwig--choose`).
  - "the parent heading | headline" replaced "the heading above", which sounded like the previous
    heading.
  - "this", "that" and "a" go for "the" in "the UNIT with WORDS" (and "this" in the body, the
    subheadings, the start / end of), as the speech model often hears them for it.
  - "the word(s) WORDS" is words, even ones a target reserves: "wrap the word this in quotes".
  - "the first / last [N] UNITs of PART" (`(within EDGE N UNIT PART)`), and "first" as "next".
  - "replace the next / previous / every A with B"; "format TARGET STYLE"; "wrap … into PAIR";
    more PAIR words ("parenthesis", singulars).
  - "new item under HEADING" goes on with the list its text ends with, or starts one.
  - Deleting the start of a sentence takes punctuation left there and passes on its capital
    (`earwig--tidy-sentence-start`); not for "rewrite", where dictation takes its place.
  - A transcription without letters or digits, as a dash the model writes for silence, is
    nothing heard (`earwig-heard-words-p`).
- **After the second review** (tmp/demo/phase2-test-plan-amendments.md):
  - The sentence point is inside is neither the last nor the next one (it was the last); right
    after one, or just before its period, it's still the last. So "moonbase in last sentence"
    from mid-sentence is the sentence before.
  - "the second … tenth [to last] UNIT of PART" (`(nth N FROM UNIT PART)`, the dictionary
    `earwig-ordinal`), "next to last", "penultimate".
  - "to" / "into" DEST is "under" (`earwig-destination-into`), with a simple target so "to the
    end of" keeps its meaning. A region of whole lines is lines (items if it starts at one), so
    "select the first two items … move that to …" moves items; the numbered list left behind is
    repaired.
  - "new item" never copies a checkbox; only "new checkbox" makes one.
- **After the third review:** "checkbox" is a UNIT, an item with one (`earwig--items-of`), so
  "the checkbox with WORDS", "this checkbox" and "the next checkbox" are targets, and items and
  checkboxes move under each other. "new sub checkbox" is a structure phrase, and "new checkbox
  before / after / under TARGET" makes one; under an item, a sub-item.
- **Word matching:** an apostrophe between letters joins them, as an underscore does, but a quote
  next to a space doesn't, so "unwrap go" finds `'go'` in text-mode, where `'` is a word character.
- **Markdown:** headings are `#` lines outside code blocks, sections are separated by blank lines.

## Decide first

1. Whether to keep Phony after the trial. Costs:
   - a new dependency on phony, which brings simulacrum
   - a fast-moving upstream
   - a breaking change to `earwig-extra-commands`

Settled in phase 1 (see "Built in phase 1"): the ranking order, help, direct evaluation, numbers,
and the migration note (the manual's "Commands of your own"). Settled in phase 2 (see "Built in
phase 2"): "change every …" left out, and the bare "next heading", "next item" and "next bullet"
dropped.

# Where md4c parses differently from the parser before it

Each case below rendered differently before the switch to md4c (#195); the golden file pins how it
renders now. The pull request lists what each one did before.

## A table after a paragraph line

Results:
| a | b |
|---|---|
| 1 | 2 |

## A delimiter row with fewer cells than the header

| one | two |
| --- |
| x | y |

## A table ends only at a blank line

| a |
|---|
| 1 |
## heading after the table

## A pipe in a code span in a table cell

| command |
|---|
| `ls | wc -l` |

## Single tildes inside a word

H~2~O and E=mc~2~

## Indented HTML after a paragraph

para
    <div>indented four</div>

## A thematic break after a reference definition

[d]: /def
	---

## Looseness after an HTML block in an item

- <div>
  html
  </div>

- item
- item two

## An item that starts with indented code

1.     code

    para

## A reference definition then a list in an item

- [r]: /url

  - nested

## Continuation lines keep no indentation

1. ## heading

	back\
 slash

## Backticks: a long run that never closes

````````` x `code one`, `.`, more `code two`; `x` end

## An empty task item

- [ ]
- [x] done

#!/bin/sh
# Prints a text-rendering sample (emoji, symbols, CJK, box drawing, styles)
# for tests/scripts/text.txt screenshots.
e=$(printf '\033')
printf 'Emoji:   😀 🚀 ✅ 👍🏽 👨‍👩‍👧 🇯🇵 ❤️  ⚠️ \n'
printf 'Symbols: ⏺ ● ✓ ✗ ▸ ▶ ★ ⚡ → ← ↑ ↓ ⌘ ⌥ ⇧ … • · ° ± ≠ ≤ ≥ ∞ λ π Σ\n'
printf 'CJK:     日本語のテキスト 中文 한국어 | ｶﾀｶﾅ ｗｉｄｅ\n'
printf 'Latin:   The quick brown fox jumps over the lazy dog 0123456789 -> => != == ===\n'
printf 'Accents: café naïve Ångström résumé e\314\201 (e+combining) ñ ü ß\n'
printf '%s[1mBold%s[0m %s[3mItalic%s[0m %s[1;3mBoldItalic%s[0m %s[4mUnderline%s[0m %s[21mDouble%s[0m %s[4:3mCurly%s[0m %s[9mStrike%s[0m %s[2mFaint%s[0m %s[7mInverse%s[0m\n' $e $e $e $e $e $e $e $e $e $e $e $e $e $e $e $e $e $e
printf '%s[31mred %s[32mgreen %s[33myellow %s[34mblue %s[35mmagenta %s[36mcyan %s[38;2;255;140;0mtruecolor%s[0m %s[4:3;58;2;255;0;0mred curly%s[0m\n' $e $e $e $e $e $e $e $e $e $e
printf '╭──────────┬──────────╮  ┏━━━━┳━━━━┓  ╔════╦════╗  ┌─┐\n'
printf '│ rounded  │ light    │  ┃ hv ┃    ┃  ║ db ║    ║  │ │\n'
printf '├──────────┼──────────┤  ┣━━━━╋━━━━┫  ╠════╬════╣  └─┘\n'
printf '╰──────────┴──────────╯  ┗━━━━┻━━━━┛  ╚════╩════╝  ╴╶╵╷\n'
printf 'Blocks:  █▓▒░ ▀▄▌▐ ▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉ ▖▗▘▙▚▛▜▝▞▟\n'
printf 'Braille: ⠁⠃⠇⡇⣇⣧⣷⣿  Powerline: \356\202\260 \356\202\262 \356\202\240\n'
printf '%s[48;5;236m%s[38;5;250m bg row: ⏺ Thinking… ▸ tool call ✓ done %s[0m\n' $e $e $e

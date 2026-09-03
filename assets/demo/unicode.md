# 文字幅 — wide glyphs

issy measures display width per codepoint: CJK and emoji take two
cells, combining marks take none, so everything after them lines up.

| 言語        | greeting        | mood  |
|-------------|-----------------|-------|
| 日本語      | こんにちは      | 🍵    |
| 中文        | 你好            | 🐉    |
| Deutsch     | Grüß dich       | 🥨    |
| Français    | Ça va ?         | 🥐    |

- a click on either half of a wide glyph snaps to the glyph
- backspace removes a whole codepoint, never a stray lead byte
- soft-wrap and horizontal scroll count cells, not bytes

```zig
const greeting = "こんにちは、世界 🌏"; // 29 bytes, 19 cells
```

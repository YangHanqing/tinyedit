# TinyEdit

[简体中文](README.md) | **English**

TinyEdit is a **native macOS text editor** for reading and editing everyday files such as TXT, Markdown (MD) and JSON. Its clean, modern SwiftUI interface keeps the app lightweight while providing a complete set of everyday editing tools.

TinyEdit has no folder management, project management or other IDE features. Open a file to read and edit it, or start typing without creating a file first. Tabs and unsaved text are kept automatically, so you can pick up where you left off after closing the window or quitting.

![TinyEdit overview](assets/screenshots/overview.png)

## Features

All screenshots use the English interface and dark theme. The interface language can be changed in Settings.

### General features

| Feature | Description | Image |
| --- | --- | --- |
| Everyday editing | Tabs, find and replace, word wrap, line numbers, indent guides, matching brackets and selected-word highlighting. Duplicate, move, delete and join lines, or toggle comments. |  |
| Files and encodings | UTF-8, UTF-16 and GB18030 (including GBK / GB2312), with line endings preserved. External file changes and deletions prompt you to choose what to do; reloaded changes are marked beside the line numbers. |  |
| Command line | Run `tinyedit file` in Terminal to open a file, `tinyedit file:120` to open it at line 120, and `command \| tinyedit` to open what a command prints in a new tab. See [Command line](#command-line) below to install it. |  |
| Session recovery | Tabs, unsaved text, cursor and scroll position are kept automatically. Recovery data is separate from your files; files change only when you save them. |  |
| Text from images | Paste a screenshot or drop a picture to insert its text. Recognition uses Apple Vision on your Mac. On macOS 26, tables can become text ready to paste into a spreadsheet. |  |
| Appearance and languages | Light, dark or system appearance, four app icons (Notepad, Code Editor, Manuscript and Minimal Cursor) and multiple editor backgrounds. Available in English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German, French and Spanish. |  |
| Syntax highlighting | 36 languages and formats, including JSON, Markdown, Python, JavaScript, TypeScript, Swift, SQL and YAML. Detected from files and content automatically, or selected manually from the status bar. | <img src="assets/screenshots/syntax-highlighting.png" alt="Syntax highlighting" width="560"> |
| Command palette | Press ⇧⌘P to find and run commands or switch to an open tab. Available commands include:<br>• JSON: format, minify, escape and unescape strings.<br>• Encoding: Base64/URL encode and decode, unescape Unicode, decode JWTs, convert Unix timestamps to dates.<br>• Lines: sort ascending/descending, reverse, shuffle and remove duplicates.<br>• Cleanup: remove blank lines, trailing whitespace, ANSI escape codes (such as terminal colors) and invisible characters.<br>• Translation and requests: translate a selection or document, and send curl requests.<br>Text tools work on the selection, or the whole document when nothing is selected. Text changes can be undone. | <img src="assets/screenshots/command-palette.png" alt="Command palette" width="560"> |
| Arithmetic as you type | Type an expression to see the result at the end of the line, then press Tab to insert it. Supports arithmetic, parentheses, powers `2^10`, roots `sqrt(144)`, percent, remainder, factorial, `max`/`min`/`avg`, rounding, logarithms, trigonometry and full-width operators. Exact results use decimal arithmetic, so `0.1 + 0.2` gives `0.3`. Enabled for plain text by default, with an option to include Markdown. | <img src="assets/screenshots/calculator.png" alt="Inline arithmetic" width="560"> |
| Send curl requests | Paste a curl command, review the request and click Send. The response card shows status, time, size, body and headers, with JSON formatted automatically. Copy the result, replace the command or open it in a new tab. No terminal needed, and nothing is sent until you choose Send. | <img src="assets/screenshots/curl-request.png" alt="curl request and response" width="560"> |
| Translation | Translate a selection or a whole document with the original and translation side by side. Copy the result, replace the original or open it in a new tab. Use Apple Translation or an OpenAI-compatible hosted service or local model. Long documents are split into segments, and interrupted translations can continue. | <img src="assets/screenshots/translation.png" alt="Translation panel" width="560"> |
| Recognize pasted content | Paste Base64 to see its decoded text, ready to copy or replace. Also recognizes JWTs, URL encoding, Unicode escapes, JSON strings and Unix timestamps. Pasted terminal color codes and invisible characters get a cleanup suggestion. | <img src="assets/screenshots/paste-base64.png" alt="Automatic Base64 paste decoding" width="560"> |

### Markdown

| Feature | Description | Image |
| --- | --- | --- |
| Markdown preview | Press ⇧⌘V to read source and preview side by side, or have Markdown open in preview by default. Supports headings, lists, quotes, tables, code blocks and images, including images inside tables. HTML `<img>` sizing and `<br>` line breaks are supported. | <img src="assets/screenshots/markdown-tasks.png" alt="Markdown preview and tasks" width="560"> |
| Tasks | Write tasks with `- [ ]`, then click a preview checkbox or press ⌘↩ to toggle completion. The status bar tracks progress, and Return continues the list while editing. |  |

### JSON

| Feature | Description | Image |
| --- | --- | --- |
| Paste and format JSON | Paste JSON into an empty tab, or replace the whole document, to get a syntax and formatting suggestion. Format it in one click while preserving key order and numbers as written. Minify, escape and unescape tools are also available. | <img src="assets/screenshots/json-format.png" alt="JSON paste and formatting suggestion" width="560"> |
| Copy values and preview content | Place the cursor on a key or value to copy its path, key or value from the status bar. Strings are copied without quotes and with escapes resolved. Lines with image links or embedded images show a picture icon; click it to preview the image, see its dimensions and size, or copy and save it. Object key counts and array item counts follow the cursor in the status bar. Inline annotations show dates for timestamps and color swatches, with actions to open links or decode content. | <img src="assets/screenshots/json-values.png" alt="JSON value actions and image preview" width="560"> |
| Open Value: read a value separately | Place the cursor on an object, array or ordinary string, then click **Open Value** in the status bar to view and edit it in a new tab. Useful for long values and nested data. Strings are unescaped, and JSON objects or arrays stored inside strings are formatted automatically. | <img src="assets/screenshots/json-open-value.png" alt="Open Value in the JSON status bar" width="560"> |

## Download and install

Download the latest version from [Releases](../../releases) and drag TinyEdit into Applications.

- macOS 15 or later.
- Apple silicon (M-series) Mac. Intel Macs are not supported yet.
- Files up to 64 MB. Above 2 MB, only visible text is highlighted; above 5 MB, highlighting and Markdown preview are disabled.

## Command line

TinyEdit comes with a `tinyedit` command. In Settings ▸ General ▸ Command Line Tool, click Copy and run the install line in Terminal (it asks for an administrator password). The command links to the script inside the app, so it stays current when TinyEdit updates.

```sh
tinyedit notes.md             # open a file; a missing one is created empty first
tinyedit a.txt b.json         # open several files, one tab each
tinyedit main.swift:120       # open at line 120 (main.swift:120:5 for a column too)
curl -s https://api.example.com/items | tinyedit   # open what a command prints in a new Untitled tab
pbpaste | tinyedit            # piped text gets the paste offers: language, Format JSON, escape-code cleanup
tinyedit                      # bring TinyEdit to the front
tinyedit -h                   # show every option
```

## Privacy and network access

TinyEdit collects no user data. Editing, text recognition, text tools and session recovery stay on your Mac. Apple Translation runs locally; the first use of a language may require a language pack download.

## Build from source

Install Xcode 27 or later and XcodeGen. Run `xcodegen generate` from the repository root, open `TinyEdit.xcodeproj` and run the **TinyEdit** scheme.

## License

GNU General Public License v3.0 (GPL v3).

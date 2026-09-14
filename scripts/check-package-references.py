"""Restricted package documentation grammar plus syntax-aware TS references.

Markdown supports fenced/inline code, inline links/images and reference links.
Reference labels unescape punctuation, collapse whitespace and Unicode-casefold.
Nested label markup and backticks in destinations are unsupported.
Definitions must be single-line. Destinations are bare or angle-delimited,
without titles/backslash escapes/local queries. Raw HTML links/images and indented code are rejected. Fragment targets
are accepted without claiming heading validation. External URLs are never fetched.
"""
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
from urllib.parse import unquote, urlsplit


def require(condition, message):
    if not condition:
        raise ValueError(message)


def prose(text):
    lines = []
    fence = None
    for line in text.splitlines(keepends=True):
        match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*?)(?:\n)?$", line)
        if fence:
            if match and match[1][0] == fence[0] and len(match[1]) >= fence[1] and not match[2].strip():
                fence = None
            lines.append("\n")
        elif match:
            fence = (match[1][0], len(match[1]))
            lines.append("\n")
        else:
            require(not (line.startswith("    ") and line.strip()), "indented Markdown code is unsupported; use fences")
            lines.append(line)
    require(fence is None, "unterminated Markdown fence")
    text = "".join(lines)
    out = []
    i = 0
    while i < len(text):
        if text.startswith("<!--", i):
            end = text.find("-->", i + 4)
            require(end >= 0, "unterminated Markdown comment")
            out.append(" " * (end + 3 - i)); i = end + 3
        elif text.startswith("](", i):
            # Destinations are not code spans. Preserve their bytes rather than
            # letting backticks turn a missing path into an empty/self link.
            depth = 1
            end = i + 2
            while end < len(text) and depth:
                require(text[end] != "`", "backtick destinations are unsupported")
                if text[end] == "(": depth += 1
                if text[end] == ")": depth -= 1
                end += 1
            require(depth == 0, "unterminated Markdown destination")
            out.append(text[i:end]); i = end
        elif text.startswith("]:", i):
            line_start = text.rfind("\n", 0, i) + 1
            require(re.match(r"^ {0,3}\[", text[line_start:i]) is not None,
                    "unsupported Markdown definition context")
            end = text.find("\n", i)
            if end < 0: end = len(text)
            require("`" not in text[i + 2:end], "backtick definition destinations are unsupported")
            out.append(text[i:i + 2]); i += 2
        elif text[i] == "\\" and i + 1 < len(text):
            out.extend(text[i:i + 2]); i += 2
        elif text[i] == "`":
            end = i
            while end < len(text) and text[end] == "`":
                end += 1
            marker = text[i:end]
            close = next((end + match.start() for match in re.finditer(r"`+", text[end:])
                          if len(match[0]) == len(marker)), -1)
            require(close >= 0, "unterminated Markdown code span")
            out.append(" " * (close + len(marker) - i)); i = close + len(marker)
        else:
            out.append(text[i]); i += 1
    return "".join(out)


def bracket(text, start):
    require(text[start] == "[", "invalid Markdown label")
    depth = 1
    i = start + 1
    while i < len(text):
        if text[i] == "\\":
            i += 2; continue
        if text[i] == "[":
            depth += 1
        if text[i] == "]":
            depth -= 1
            if depth == 0:
                return text[start + 1:i], i + 1
        i += 1
    return None


def nested_markup(value):
    index = 0
    while index < len(value):
        if value[index] == "\\":
            index += 2
            continue
        if value[index] == "[":
            return True
        index += 1
    return False


def label(value):
    require(len(value) <= 999 and not re.search(r"\n\s*\n", value), "unsupported Markdown reference label")
    value = re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])", r"\1", value)
    return " ".join(value.split()).casefold()


def destination(value):
    value = value.strip()
    if value.startswith("<"):
        require(value.endswith(">") and ">" not in value[1:-1], "unsupported Markdown destination/title")
        value = value[1:-1]
    require(not any(c.isspace() for c in value) and "\\" not in value,
            "escaped destinations, whitespace and titles are unsupported")
    require(not re.search(r"%(?![0-9a-fA-F]{2})", value), "invalid destination encoding")
    return value


def target(files, name, value):
    value = destination(value)
    parts = urlsplit(value)
    if parts.scheme:
        require(parts.scheme in {"https", "http", "mailto"}, "unsupported documentation URL scheme")
        require(parts.username is None and parts.password is None, "credential-bearing documentation URL forbidden")
        return
    require(not parts.netloc and not parts.query, "unsupported local documentation destination")
    if not parts.path:
        return  # Current document/fragment; anchors are deliberately not checked.
    decoded = unquote(parts.path, encoding="utf-8", errors="strict")
    require(not decoded.startswith("/") and "\\" not in decoded, "documentation link escapes package")
    normalized = posixpath.normpath(posixpath.join(posixpath.dirname(name), decoded))
    require(not normalized.startswith("../") and normalized in files, "missing or escaping documentation link")


def check_markdown(files):
    for name, data in files.items():
        if not name.endswith(".md"):
            continue
        text = prose(data.decode("utf-8"))
        require(not re.search(r"<\s*(?:a|img)\b", text, re.I), "HTML links/images are unsupported")
        # Multi-line definitions are outside this grammar, not silently ignored.
        for start in re.finditer(r"(?m)^ {0,3}(?=\[)", text):
            candidate = bracket(text, start.end())
            if candidate and text[candidate[1]:].startswith(":"):
                require("\n" not in candidate[0], "multi-line Markdown definitions are unsupported")
        definitions = {}
        body = []
        for line in text.splitlines(keepends=True):
            stripped = line.lstrip(" ")
            parsed = bracket(stripped, 0) if stripped.startswith("[") else None
            if parsed and stripped[parsed[1]:].startswith(":"):
                key = label(parsed[0])
                require(key and key not in definitions, "empty or duplicate Markdown definition")
                value = stripped[parsed[1] + 1:].strip()
                require(value, "multi-line or empty Markdown definition is unsupported")
                target(files, name, value)  # Check unused definitions too.
                definitions[key] = value
                body.append("\n")
            else:
                body.append(line)
        text = "".join(body)
        i = 0
        while i < len(text):
            if text[i] == "\\":
                i += 2; continue
            if text[i] != "[":
                i += 1; continue
            parsed = bracket(text, i)
            if not parsed:
                i += 1; continue
            content, end = parsed
            require(not nested_markup(content), "nested Markdown label markup is unsupported")
            if end < len(text) and text[end] == "(":
                depth = 1; cursor = end + 1
                while cursor < len(text) and depth:
                    require(text[cursor] != "\\", "escaped Markdown destinations are unsupported")
                    if text[cursor] == "(": depth += 1
                    if text[cursor] == ")": depth -= 1
                    cursor += 1
                require(depth == 0, "unterminated Markdown link")
                target(files, name, text[end + 1:cursor - 1]); i = cursor; continue
            following = end
            while following < len(text) and text[following].isspace():
                following += 1
            if "\n\n" not in text[end:following] and following < len(text) and text[following] == "[":
                reference = bracket(text, following)
                require(reference is not None, "unterminated Markdown reference")
                key = label(reference[0] or content)
                require(key in definitions, "undefined explicit Markdown reference")
                i = reference[1]; continue
            # A shortcut is a link only when its definition exists; those targets
            # were validated above. Other bracketed text remains ordinary prose.
            label(content)
            i = end


def check(files, typescript_path):
    check_markdown(files)
    compiler = Path(typescript_path)
    require(compiler.is_absolute() and compiler.is_file(), "explicit pinned TypeScript compiler required")
    helper = Path(__file__).with_name("check-package-imports.mjs")
    environment = {key: os.environ[key] for key in ["PATH", "HOME", "TMPDIR"] if key in os.environ}
    result = subprocess.run(["node", str(helper), str(compiler)],
                            input=json.dumps({name: data.decode("utf-8") for name, data in files.items()}).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=30)
    require(result.returncode == 0, "packaged TypeScript reference/syntax check failed")

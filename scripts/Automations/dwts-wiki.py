#!/usr/bin/env python3
"""Read DWTS Wikipedia weekly tables, using only the Python standard library.

Examples (--couples is required only when reading couple information):
    python3 dwts_wiki.py --get-weeks --print
    python3 dwts_wiki.py --pre-show --week-tag '#Week_4:_Mariah_Carey_Night' \
        --couples '{"Amber Glenn": "Pasha Pashkov"}' --print

Couples may be a JSON object mapping full celebrity names to full pro names,
or a JSON list of {"star_name": ..., "pro_name": ...} objects. Pass inline JSON
or @filename. Matching uses BOTH first names, ignoring case and accents.

CLI: one JSON document on stdout; --print enables indentation. Errors are JSON
with a nonzero exit code. Python callers: fetch_information(...) returns a dict.
No database writes, scheduling, confirmation logic, or photo processing.

Set DWTS_WIKI_USER_AGENT to identify your deployment with contact information.
"""

import argparse
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path


DEFAULT_PAGE = (
    "https://en.wikipedia.org/wiki/"
    "Dancing_with_the_Stars_(American_TV_series)_season_35"
)
MODES = {"pre-show", "live-show", "post-show", "get-weeks"}
VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr",
}
EMPTY_VALUES = {"", "—", "–", "-", "tba", "tbd", "n/a", "?"}


class WikiError(ValueError):
    """Invalid input, unavailable page, or an unsupported source format."""


@dataclass(eq=False)
class Node:
    tag: str
    attrs: dict = field(default_factory=dict)
    children: list = field(default_factory=list)
    parent: object = None

    def walk(self):
        yield self
        for child in self.children:
            if isinstance(child, Node):
                yield from child.walk()

    def ancestor(self, tag):
        node = self.parent
        while node is not None:
            if node.tag == tag:
                return node
            node = node.parent
        return None

    def text(self):
        # Footnotes and edit controls are not part of names or data values.
        if self.tag in {"sup", "script", "style"} or "mw-editsection" in self.attrs.get("class", "").split():
            return ""
        if self.tag == "br":
            return "\n"
        pieces = [child.text() if isinstance(child, Node) else child
                  for child in self.children]
        return "".join(pieces)


class DocumentParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("document")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, dict(attrs), parent=self.stack[-1])
        self.stack[-1].children.append(node)
        if tag not in VOID_TAGS:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def clean(value):
    return " ".join(value.split())


def normalized(value):
    value = unicodedata.normalize("NFKD", value).casefold()
    return "".join(c for c in value if not unicodedata.combining(c))


def first_name(value):
    words = re.findall(r"[^\W\d_]+(?:[-’'][^\W\d_]+)*", normalized(value))
    return words[0] if words else ""


def normalize_couples(couples):
    if isinstance(couples, dict):
        couples = [{"star_name": star, "pro_name": pro} for star, pro in couples.items()]
    if not isinstance(couples, list) or not couples:
        raise WikiError("Couples must be a nonempty JSON object or list.")
    result, seen = [], set()
    for entry in couples:
        if not isinstance(entry, dict):
            raise WikiError("Each couple must contain star_name and pro_name.")
        pair = {}
        for key in ("star_name", "pro_name"):
            name = entry.get(key)
            if not isinstance(name, str) or len(clean(name).split()) < 2:
                raise WikiError(f"{key} must include both first and last names.")
            pair[key] = clean(name)
        key = (first_name(pair["star_name"]), first_name(pair["pro_name"]))
        if key in seen:
            raise WikiError(f"Ambiguous input: multiple couples have first names {key}.")
        seen.add(key)
        result.append(pair)
    return result


def read_couples(argument):
    try:
        raw = Path(argument[1:]).read_text(encoding="utf-8") if argument.startswith("@") else argument
        return normalize_couples(json.loads(raw))
    except (OSError, json.JSONDecodeError) as exc:
        raise WikiError(f"Cannot read couples JSON: {exc}") from exc


def page_location(page_url):
    parsed = urllib.parse.urlsplit(page_url)
    if parsed.scheme != "https" or parsed.hostname != "en.wikipedia.org" or not parsed.path.startswith("/wiki/"):
        raise WikiError("--page-url must be an https://en.wikipedia.org/wiki/... article URL.")
    title = urllib.parse.unquote(parsed.path[len("/wiki/"):])
    if not title:
        raise WikiError("The Wikipedia article title is missing.")
    return title, "https://en.wikipedia.org/wiki/" + urllib.parse.quote(title, safe="_():,")


def fetch_page(page_url=DEFAULT_PAGE):
    title, _ = page_location(page_url)
    query = urllib.parse.urlencode({
        "action": "parse", "page": title, "prop": "text|revid",
        "format": "json", "formatversion": "2", "redirects": "1", "maxlag": "5",
    })
    request = urllib.request.Request(
        "https://en.wikipedia.org/w/api.php?" + query,
        headers={
            "User-Agent": os.getenv("DWTS_WIKI_USER_AGENT", "DWTSWikiReader/1.0 (personal read-only fantasy tool)"),
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        retry = exc.headers.get("Retry-After")
        suffix = f"; Retry-After: {retry}" if retry else ""
        raise WikiError(f"Wikipedia returned HTTP {exc.code}{suffix}. Retry on a later invocation.") from exc
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
        raise WikiError(f"Cannot fetch Wikipedia: {exc}") from exc
    if "error" in data:
        error = data["error"]
        raise WikiError(f"Wikipedia API error {error.get('code')}: {error.get('info')}")
    parsed = data.get("parse", {})
    html = parsed.get("text")
    if isinstance(html, dict):
        html = html.get("*")  # Also accepts formatversion=1 fixtures.
    if not isinstance(html, str) or not html:
        raise WikiError("Wikipedia did not return article HTML.")
    return html, parsed.get("revid")


def heading_level(node):
    return int(node.tag[1]) if re.fullmatch(r"h[1-6]", node.tag) else None


def heading_anchor(node):
    if node.attrs.get("id"):
        return node.attrs["id"]
    return next((child.attrs["id"] for child in node.walk() if child.attrs.get("id")), "")


def weekly_sections(root, source_url):
    nodes = list(root.walk())
    start = next((i for i, n in enumerate(nodes)
                  if heading_level(n) and normalized(clean(n.text())) == "weekly scores"), None)
    if start is None:
        raise WikiError("The article has no 'Weekly scores' section.")
    level = heading_level(nodes[start])
    end = next((i for i in range(start + 1, len(nodes))
                if heading_level(nodes[i]) and heading_level(nodes[i]) <= level), len(nodes))
    weeks = []
    for i in range(start + 1, end):
        node = nodes[i]
        if not heading_level(node):
            continue
        title = clean(node.text())
        match = re.match(r"^Week\s+(\d+)\b", title, re.I)
        anchor = heading_anchor(node)
        if match and anchor:
            stop = next((j for j in range(i + 1, end)
                         if heading_level(nodes[j]) and heading_level(nodes[j]) <= heading_level(node)), end)
            weeks.append({
                "week": int(match.group(1)), "title": title,
                "week_tag": "#" + anchor,
                "url": source_url + "#" + urllib.parse.quote(anchor, safe="_():,"),
                "nodes": nodes[i + 1:stop],
            })
    return weeks


def normalize_tag(tag):
    # Accept #anchor, bare anchor, or the complete article URL with its fragment.
    if "://" in tag:
        tag = urllib.parse.urlsplit(tag).fragment
    return normalized(urllib.parse.unquote(tag.lstrip("#")).replace("_", " ").strip())


def table_grid(table):
    """Expand rowspan/colspan so each data row has its proper couple and result."""
    rows = [n for n in table.walk() if n.tag == "tr" and n.ancestor("table") is table]
    slots = {}
    result = []
    for row_index, row in enumerate(rows):
        col = 0
        for cell in (n for n in row.children if isinstance(n, Node) and n.tag in {"th", "td"}):
            while (row_index, col) in slots:
                col += 1
            try:
                rowspan = int(cell.attrs.get("rowspan", 1))
                colspan = int(cell.attrs.get("colspan", 1))
            except (TypeError, ValueError) as exc:
                raise WikiError("A table has an invalid row or column span.") from exc
            if rowspan == 0:
                rowspan = len(rows) - row_index
            if not 1 <= rowspan <= len(rows) or not 1 <= colspan <= 100:
                raise WikiError("A table has an unsupported row or column span.")
            for r in range(row_index, row_index + rowspan):
                for c in range(col, col + colspan):
                    slots[r, c] = cell
            col += colspan
        width = max((c for r, c in slots if r == row_index), default=-1) + 1
        result.append([slots.get((row_index, c)) for c in range(width)])
    return result


def column_type(cell):
    if cell is None:
        return None
    name = normalized(clean(cell.text())).strip(":")
    if name in {"couple", "couples"}:
        return "couple"
    if name in {"score", "scores"}:
        return "scores"
    if name in {"dance", "dances", "dance type", "style"}:
        return "dance"
    if "music" in name or name in {"song", "songs", "song choice"}:
        return "music"
    if name in {"result", "results", "status"}:
        return "result"
    return None


def field_value(row, columns, field_name):
    cells = []
    for index in columns.get(field_name, []):
        if index < len(row) and row[index] is not None and row[index] not in cells:
            cells.append(row[index])
    value = clean(" ".join(cell.text() for cell in cells))
    return None if normalized(value) in EMPTY_VALUES else value


def pair_key(label):
    names = re.split(r"\s*(?:&|\band\b)\s*", label, maxsplit=1, flags=re.I)
    return (first_name(names[0]), first_name(names[1])) if len(names) == 2 else None


def music_information(raw):
    if raw is None:
        return {"song": None, "artist": None}
    # Quotes let a song title itself contain an em dash without becoming an artist.
    quoted = re.fullmatch(r'["“](.*)["”](?:\s*[—–-]\s*(.+))?', raw)
    if quoted:
        song, artist = quoted.groups()
    else:
        pieces = re.split(r"\s+[—–]\s+", raw, maxsplit=1)
        song, artist = pieces[0], pieces[1] if len(pieces) == 2 else None
    return {"song": clean(song), "artist": clean(artist) if artist else None}


def score_information(raw):
    info = {"scores": None, "total": None, "scores_raw": raw}
    if raw is None:
        return info
    tuples = re.findall(r"\((\s*\d+(?:\.\d+)?(?:\s*,\s*\d+(?:\.\d+)?)+\s*)\)", raw)
    if len(tuples) != 1:
        info["warning"] = "Expected exactly one complete comma-separated judge-score tuple."
        return info
    scores = [float(value.strip()) for value in tuples[0].split(",")]
    if any(not 0 < value <= 10 for value in scores):
        info["warning"] = "A judge score is outside the expected range of 1 through 10."
        return info
    info["scores"] = [int(value) if value.is_integer() else value for value in scores]
    total = re.match(r"^(\d+(?:\.\d+)?)\s*\(", raw)
    if total:
        value = float(total.group(1))
        info["total"] = int(value) if value.is_integer() else value
        if value != sum(scores):
            info["warning"] = "Listed total differs from judge-score sum; may include bonuses."
    return info


def elimination_information(raw):
    eliminated = None
    if raw:
        text = normalized(raw)
        if re.search(r"\bnot eliminated\b", text):
            eliminated = False
        elif re.search(r"\beliminated\b", text) and not re.search(r"\bsafe\b", text):
            eliminated = True
        elif re.search(r"\bsafe\b", text) and not re.search(r"\beliminated\b", text):
            eliminated = False
    return {"eliminated": eliminated, "result": raw}


def parse_information(html, mode, couples=None, week_tag=None, page_url=DEFAULT_PAGE, revision_id=None):
    """Parse supplied HTML into a JSON-serializable dict (also useful for tests)."""
    if mode not in MODES:
        raise WikiError(f"Unsupported mode: {mode}")
    if mode != "get-weeks" or couples is not None:
        couples = normalize_couples(couples)
    _, source_url = page_location(page_url)
    parser = DocumentParser()
    parser.feed(html)
    weeks = weekly_sections(parser.root, source_url)
    result = {
        "mode": mode, "source_url": source_url, "revision_id": revision_id,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
    }
    if mode == "get-weeks":
        result["weeks"] = [{key: value for key, value in week.items() if key != "nodes"} for week in weeks]
        return result
    if not isinstance(week_tag, str) or not week_tag.strip():
        raise WikiError("--week-tag is required for pre-show, live-show, and post-show.")
    selected = [week for week in weeks if normalize_tag(week["week_tag"]) == normalize_tag(week_tag)]
    if len(selected) != 1:
        raise WikiError("Week tag not found or ambiguous. Run --get-weeks for valid tags.")
    week = selected[0]
    result.update({"week": week["week"], "week_tag": week["week_tag"], "source_url": week["url"]})
    records = [{**couple, "found": False, "performances": []} for couple in couples]
    lookup = {(first_name(c["star_name"]), first_name(c["pro_name"])): c for c in records}
    required = {"pre-show": {"couple", "dance", "music"},
                "live-show": {"couple", "scores"}, "post-show": {"couple", "result"}}[mode]
    recognized = 0
    for table in (n for n in week["nodes"] if n.tag == "table" and n.ancestor("table") is None):
        grid = table_grid(table)
        header_index, columns = None, {}
        for i, row in enumerate(grid):
            candidate = {}
            for j, cell in enumerate(row):
                kind = column_type(cell)
                if kind:
                    candidate.setdefault(kind, []).append(j)
            if required <= candidate.keys():
                header_index, columns = i, candidate
                break
        if header_index is None:
            continue
        recognized += 1
        caption = next((clean(n.text()) for n in table.children if isinstance(n, Node) and n.tag == "caption"), None)
        table_pairs = {}
        for row_index, row in enumerate(grid[header_index + 1:], start=1):
            label = field_value(row, columns, "couple")
            record = lookup.get(pair_key(label)) if label else None
            if record is None:
                continue
            # Abbreviated last names do not change a first-name match, but two
            # different labels for that same pair in one table are ambiguous.
            key = pair_key(label)
            if key in table_pairs and table_pairs[key] != label:
                raise WikiError(f"Ambiguous Wikipedia rows for first-name pair {key}.")
            table_pairs[key] = label
            data = {"wiki_couple": label, "table": caption,
                    "table_index": recognized, "row_index": row_index}
            if mode == "pre-show":
                data["dance"] = field_value(row, columns, "dance")
                data.update(music_information(field_value(row, columns, "music")))
            elif mode == "live-show":
                data.update(score_information(field_value(row, columns, "scores")))
            else:
                data.update(elimination_information(field_value(row, columns, "result")))
            record["found"] = True
            record["performances"].append(data)
    result["couples"] = records
    result["warnings"] = []
    if not recognized:
        result["warnings"].append("No table with the required headings is available in this week section.")
    return result


def fetch_information(mode, couples=None, week_tag=None, page_url=DEFAULT_PAGE):
    """Fetch Wikipedia once and return a dict; never print or write to a database."""
    if mode not in MODES:
        raise WikiError(f"Unsupported mode: {mode}")
    if mode != "get-weeks" or couples is not None:
        couples = normalize_couples(couples)
    if mode != "get-weeks" and not week_tag:
        raise WikiError("week_tag is required for this mode.")
    html, revision_id = fetch_page(page_url)
    return parse_information(html, mode, couples, week_tag, page_url, revision_id)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_mutually_exclusive_group(required=True)
    for mode, description in (
        ("pre-show", "Get dance types, songs, and explicitly listed artists."),
        ("live-show", "Get individual judge scores and listed totals."),
        ("post-show", "Get elimination flags and raw result text."),
        ("get-weeks", "List week headings/tags under Weekly scores."),
    ):
        modes.add_argument("--" + mode, dest="mode", action="store_const", const=mode, help=description)
    parser.add_argument("--couples", metavar="JSON_OR_@FILE", help="Full-name couples JSON, inline or @filename; required except with --get-weeks.")
    parser.add_argument("--week-tag", help="Week fragment, with or without #; required except with --get-weeks.")
    parser.add_argument("--print", dest="pretty", action="store_true", help="Pretty-print JSON. Without this flag, stdout still contains compact JSON.")
    parser.add_argument("--page-url", default=DEFAULT_PAGE, help="Wikipedia article URL (default: American season 35).")
    args = parser.parse_args(argv)
    try:
        if args.mode != "get-weeks" and args.couples is None:
            raise WikiError("--couples is required for pre-show, live-show, and post-show.")
        if args.mode != "get-weeks" and not args.week_tag:
            raise WikiError("--week-tag is required for this mode.")
        couples = read_couples(args.couples) if args.couples is not None else None
        result = fetch_information(args.mode, couples, args.week_tag, args.page_url)
        status = 0
    except WikiError as exc:
        result = {"error": str(exc), "mode": args.mode}
        status = 1
    print(json.dumps(result, ensure_ascii=False, indent=2 if args.pretty else None,
                     separators=None if args.pretty else (",", ":")))
    return status


if __name__ == "__main__":
    sys.exit(main())


#!/usr/bin/env python3
"""Checks that the docs show the Example's code verbatim.

For every `// readme:begin NAME` … `// readme:end NAME` region in
Sources/Example, dedented:

- README.md, the full walkthrough, shows it in a ```swift block marked
  `<!-- example: NAME -->`;
- a block marked `<!-- example: NAME -->`, in README.md or a DocC article,
  is exactly that region, and NAME is a region that exists;
- any other ```swift block — in README.md, a DocC article, or a `///` doc
  comment in Sources — that shows part of a region (a line no other region
  has) shows all of it, verbatim.

Exits 1 and names each block that breaks a rule.

Run from the package root: `python3 Scripts/check-docs.py`
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGION = re.compile(r"// readme:begin (\w+)\n(.*?)\n[ \t]*// readme:end \1", re.S)
BLOCK = re.compile(r"(?:<!-- example: (\w+) -->\n)?```swift\n(.*?)\n```", re.S)
DOC_COMMENT = re.compile(r"^[ \t]*/// ?(.*)$")


def dedent(code):
    lines = code.split("\n")
    indent = min(len(line) - len(line.lstrip()) for line in lines if line.strip())
    return "\n".join(line[indent:] for line in lines)


def unique_lines(name, regions):
    """The region's lines that no other region contains."""
    others = [code for other, code in regions.items() if other != name]
    return [
        line
        for line in regions[name].split("\n")
        if len(line.strip()) > 3 and not any(line in code for code in others)
    ]


def doc_comments(source):
    """The text of a Swift file's `///` comments, one paragraph per run of them."""
    runs, run = [], []
    for line in source.split("\n"):
        match = DOC_COMMENT.match(line)
        if match:
            run.append(match.group(1))
        elif run:
            runs.append("\n".join(run))
            run = []
    if run:
        runs.append("\n".join(run))
    return "\n\n".join(runs)


def main():
    regions = {}
    for source in sorted((ROOT / "Sources/Example").glob("*.swift")):
        for match in REGION.finditer(source.read_text()):
            regions[match.group(1)] = dedent(match.group(2))
    if not regions:
        print("no readme regions found in Sources/Example")
        return 1

    readme = ROOT / "README.md"
    texts = {doc: doc.read_text() for doc in [readme, *sorted(ROOT.glob("Sources/*/*.docc/*.md"))]}
    for source in sorted(ROOT.glob("Sources/*/**/*.swift")):
        if not source.is_relative_to(ROOT / "Sources/Example"):
            texts[source] = doc_comments(source.read_text())
    blocks = {doc: BLOCK.findall(text) for doc, text in texts.items()}

    problems = []
    for name in regions:
        if not any(marker == name for marker, _ in blocks[readme]):
            problems.append(f"README.md does not show readme region '{name}'")
    for doc, doc_blocks in blocks.items():
        where = doc.relative_to(ROOT)
        for marker, block in doc_blocks:
            if marker:
                if marker not in regions:
                    problems.append(f"{where}: no readme region named '{marker}'")
                elif block != regions[marker]:
                    problems.append(f"{where}: the '{marker}' block differs from the Example")
                continue
            for name, code in regions.items():
                if any(line in block for line in unique_lines(name, regions)) and code not in block:
                    problems.append(f"{where}: a block shows part of readme region '{name}', not all of it")
    for problem in problems:
        print(problem)
    if not problems:
        print(f"all {len(regions)} readme regions are shown verbatim in the docs")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

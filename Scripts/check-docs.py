#!/usr/bin/env python3
"""Checks that the docs show the Example's code verbatim.

For every `// readme:begin NAME` … `// readme:end NAME` region in
Sources/Example, dedented:

- README.md, the full walkthrough, shows it verbatim in a ```swift block;
- any ```swift block in README.md or a DocC article that shows part of it
  (a line no other region has) shows all of it, verbatim.

Exits 1 and names each region that breaks a rule.

Run from the package root: `python3 Scripts/check-docs.py`
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REGION = re.compile(r"// readme:begin (\w+)\n(.*?)\n[ \t]*// readme:end \1", re.S)
SWIFT_BLOCK = re.compile(r"```swift\n(.*?)\n```", re.S)


def dedent(code):
    lines = code.split("\n")
    indent = min(len(line) - len(line.lstrip()) for line in lines if line.strip())
    return "\n".join(line[indent:] for line in lines)


def marker(name, regions):
    """The region's first line that no other region contains, if any."""
    others = [code for other, code in regions.items() if other != name]
    for line in regions[name].split("\n"):
        if len(line.strip()) > 3 and not any(line in code for code in others):
            return line
    return None


def main():
    regions = {}
    for source in sorted((ROOT / "Sources/Example").glob("*.swift")):
        for match in REGION.finditer(source.read_text()):
            regions[match.group(1)] = dedent(match.group(2))

    readme = ROOT / "README.md"
    docs = [readme, *sorted(ROOT.glob("Sources/*/*.docc/*.md"))]
    blocks = {doc: SWIFT_BLOCK.findall(doc.read_text()) for doc in docs}

    if not regions:
        print("no readme regions found in Sources/Example")
        return 1
    problems = []
    for name, code in regions.items():
        if not any(code in block for block in blocks[readme]):
            problems.append(f"readme region '{name}' is not shown verbatim in README.md")
        line = marker(name, regions)
        for doc, doc_blocks in blocks.items():
            for block in doc_blocks:
                if line and line in block and code not in block:
                    where = doc.relative_to(ROOT)
                    problems.append(f"readme region '{name}' differs from the Example in {where}")
    for problem in problems:
        print(problem)
    if not problems:
        print(f"all {len(regions)} readme regions are shown verbatim in the docs")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

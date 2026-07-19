#!/usr/bin/env python3
"""Convert a .xcstrings String Catalog into classic .lproj/Localizable.strings files.

This environment only has the Xcode Command Line Tools (no actool / full Xcode),
so SwiftPM's `swift build` cannot compile .xcstrings into per-language resources
-- it just copies the raw JSON. `String(localized:)` in AgentNotch's sources uses
the default `Bundle.main` lookup, which only finds classic .strings files under
Contents/Resources/<lang>.lproj inside the .app bundle itself (not inside a
nested SwiftPM resource bundle). This script bridges that gap by emitting those
.lproj/Localizable.strings files directly into the built .app as a build step.
"""
import json
import sys
from pathlib import Path


def escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("\"", "\\\"")
        .replace("\n", "\\n")
    )


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: xcstrings_to_strings.py <Localizable.xcstrings> <Contents/Resources dir>", file=sys.stderr)
        sys.exit(1)

    catalog_path = Path(sys.argv[1])
    resources_dir = Path(sys.argv[2])

    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})

    per_lang: dict[str, list[tuple[str, str]]] = {}
    for key, entry in strings.items():
        for lang, loc in entry.get("localizations", {}).items():
            unit = loc.get("stringUnit")
            if not unit:
                continue
            value = unit.get("value", "")
            per_lang.setdefault(lang, []).append((key, value))

    for lang, pairs in per_lang.items():
        lproj = resources_dir / f"{lang}.lproj"
        lproj.mkdir(parents=True, exist_ok=True)
        out_path = lproj / "Localizable.strings"
        lines = [f"\"{escape(k)}\" = \"{escape(v)}\";" for k, v in sorted(pairs)]
        out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"Wrote {len(per_lang)} .lproj/Localizable.strings files to {resources_dir}")


if __name__ == "__main__":
    main()

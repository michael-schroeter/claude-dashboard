#!/usr/bin/python3
"""Packages the extension as a .vsix – no Node or npm needed, just Python 3.

Usage:   python3 tools/package.py
Output:  dist/claude-dashboard-<version>.vsix

Install it with:
  "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
      --install-extension dist/claude-dashboard-<version>.vsix
"""

import json
import pathlib
import zipfile
from xml.sax.saxutils import escape

ROOT = pathlib.Path(__file__).resolve().parent.parent
# Only these files go into the extension (no notes, no CLAUDE.md).
INCLUDE = ["package.json", "package.nls.json", "package.nls.de.json", "README.md", "LICENSE", "extension.js", "lib", "media", "docs"]

CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".css" ContentType="text/css"/>
  <Default Extension=".svg" ContentType="image/svg+xml"/>
  <Default Extension=".png" ContentType="image/png"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
  <Override PartName="/extension/LICENSE" ContentType="text/plain"/>
</Types>
"""


def localized(pkg, key):
    """Resolves "%key%" placeholders from package.nls.json (English)."""
    value = pkg[key]
    if value.startswith("%") and value.endswith("%"):
        nls = json.loads((ROOT / "package.nls.json").read_text("utf-8"))
        value = nls.get(value[1:-1], value)
    return value


def manifest(pkg):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="{escape(pkg['name'])}" Version="{escape(pkg['version'])}" Publisher="{escape(pkg['publisher'])}"/>
    <DisplayName>{escape(pkg['displayName'])}</DisplayName>
    <Description xml:space="preserve">{escape(localized(pkg, 'description'))}</Description>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{escape(pkg['engines']['vscode'])}"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
"""


def files():
    for entry in INCLUDE:
        path = ROOT / entry
        if path.is_file():
            yield path
        else:
            yield from sorted(p for p in path.rglob("*") if p.is_file() and p.name != ".DS_Store")


def main():
    pkg = json.loads((ROOT / "package.json").read_text("utf-8"))
    out = ROOT / "dist" / f"{pkg['name']}-{pkg['version']}.vsix"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("extension.vsixmanifest", manifest(pkg))
        for path in files():
            name = "extension/" + path.relative_to(ROOT).as_posix()
            z.write(path, name)
            print("  ", name)
    print(out)


if __name__ == "__main__":
    main()

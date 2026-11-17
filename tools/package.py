#!/usr/bin/python3
"""Packages the extension as a .vsix – no Node or npm needed, just Python 3.

Usage:   python3 tools/package.py
Output:  dist/claude-dashboard-<version>.vsix

The package is ready for the VS Code Marketplace (upload it on
https://marketplace.visualstudio.com/manage) and for a local install:
  "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
      --install-extension dist/claude-dashboard-<version>.vsix
"""

import json
import pathlib
import re
import zipfile
from xml.sax.saxutils import escape, quoteattr

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = "Claude Dashboard.app"
# Only these files go into the extension (no notes, no CLAUDE.md). The README
# pictures stay out: in the package the README points to them on GitHub.
INCLUDE = ["package.json", "package.nls.json", "package.nls.de.json", "README.md", "CHANGELOG.md", "LICENSE",
           "extension.js", "lib", "media"]

CONTENT_TYPES = """<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json"/>
  <Default Extension=".js" ContentType="application/javascript"/>
  <Default Extension=".css" ContentType="text/css"/>
  <Default Extension=".svg" ContentType="image/svg+xml"/>
  <Default Extension=".png" ContentType="image/png"/>
  <Default Extension=".jpg" ContentType="image/jpeg"/>
  <Default Extension=".md" ContentType="text/markdown"/>
  <Default Extension=".vsixmanifest" ContentType="text/xml"/>
  <Default Extension=".plist" ContentType="application/xml"/>
  <Default Extension=".icns" ContentType="image/icns"/>
  <Override PartName="/extension/LICENSE" ContentType="text/plain"/>
  <Override PartName="/extension/menubar-app/Claude Dashboard.app/Contents/MacOS/ClaudeDashboard" ContentType="application/octet-stream"/>
  <Override PartName="/extension/menubar-app/Claude Dashboard.app/Contents/_CodeSignature/CodeResources" ContentType="application/xml"/>
</Types>
"""


def localized(pkg, key):
    """Resolves "%key%" placeholders from package.nls.json (English)."""
    value = pkg[key]
    if value.startswith("%") and value.endswith("%"):
        nls = json.loads((ROOT / "package.nls.json").read_text("utf-8"))
        value = nls.get(value[1:-1], value)
    return value


def github(pkg):
    """owner/repo from the repository URL."""
    url = pkg["repository"]["url"]
    match = re.match(r"https://github\.com/([^/]+/[^/.]+)", url)
    if not match:
        raise SystemExit(f"repository.url is not a GitHub URL: {url}")
    return match.group(1)


def readme_for_marketplace(pkg):
    """The README with relative links made absolute, as vsce does: the
    Marketplace shows pictures only from https addresses. Pictures come from
    raw.githubusercontent.com, other files from their GitHub page."""
    repo = github(pkg)
    raw = f"https://raw.githubusercontent.com/{repo}/HEAD/"
    blob = f"https://github.com/{repo}/blob/HEAD/"

    def absolute(target, picture):
        if re.match(r"^([a-z]+:|#|/)", target):
            return target
        return (raw if picture else blob) + target

    text = (ROOT / "README.md").read_text("utf-8")
    # Markdown links and pictures: [text](target) and ![alt](target "title")
    text = re.sub(
        r"(!?)\[([^\]]*)\]\(([^)\s]+)((?:\s+\"[^\"]*\")?)\)",
        lambda m: f"{m.group(1)}[{m.group(2)}]({absolute(m.group(3), m.group(1) == '!')}{m.group(4)})",
        text,
    )
    # HTML pictures: <img src="...">
    text = re.sub(r'(<img\b[^>]*\bsrc=")([^"]+)(")', lambda m: m.group(1) + absolute(m.group(2), True) + m.group(3), text)
    return text


def manifest(pkg):
    repo_url = f"https://github.com/{github(pkg)}"
    banner = pkg.get("galleryBanner", {})
    properties = [
        ("Microsoft.VisualStudio.Code.Engine", pkg["engines"]["vscode"]),
        ("Microsoft.VisualStudio.Code.ExtensionDependencies", ""),
        ("Microsoft.VisualStudio.Code.ExtensionPack", ""),
        ("Microsoft.VisualStudio.Code.ExtensionKind", "workspace"),
        ("Microsoft.VisualStudio.Code.LocalizedLanguages", ""),
        ("Microsoft.VisualStudio.Code.EnabledApiProposals", ""),
        ("Microsoft.VisualStudio.Code.ExecutesCode", "true"),
        ("Microsoft.VisualStudio.Services.Links.Source", repo_url),
        ("Microsoft.VisualStudio.Services.Links.Getstarted", repo_url),
        ("Microsoft.VisualStudio.Services.Links.GitHub", repo_url),
        ("Microsoft.VisualStudio.Services.Links.Support", pkg["bugs"]["url"]),
        ("Microsoft.VisualStudio.Services.Links.Learn", pkg["homepage"]),
        ("Microsoft.VisualStudio.Services.Branding.Color", banner.get("color", "")),
        ("Microsoft.VisualStudio.Services.Branding.Theme", banner.get("theme", "")),
        ("Microsoft.VisualStudio.Services.GitHubFlavoredMarkdown", "true"),
        ("Microsoft.VisualStudio.Services.Content.Pricing", "Free"),
        ("Microsoft.VisualStudio.Services.CustomerQnALink", pkg["qna"]),
    ]
    assets = [
        ("Microsoft.VisualStudio.Code.Manifest", "extension/package.json"),
        ("Microsoft.VisualStudio.Services.Content.Details", "extension/README.md"),
        ("Microsoft.VisualStudio.Services.Content.Changelog", "extension/CHANGELOG.md"),
        ("Microsoft.VisualStudio.Services.Content.License", "extension/LICENSE"),
        ("Microsoft.VisualStudio.Services.Icons.Default", "extension/" + pkg["icon"]),
    ]
    prop_xml = "\n".join(f'      <Property Id="{k}" Value={quoteattr(v)}/>' for k, v in properties)
    asset_xml = "\n".join(f'    <Asset Type="{t}" Path={quoteattr(p)} Addressable="true"/>' for t, p in assets)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id={quoteattr(pkg['name'])} Version={quoteattr(pkg['version'])} Publisher={quoteattr(pkg['publisher'])}/>
    <DisplayName>{escape(pkg['displayName'])}</DisplayName>
    <Description xml:space="preserve">{escape(localized(pkg, 'description'))}</Description>
    <Tags>{escape(','.join(pkg.get('keywords', [])))}</Tags>
    <Categories>{escape(','.join(pkg.get('categories', [])))}</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
{prop_xml}
    </Properties>
    <License>extension/LICENSE</License>
    <Icon>extension/{escape(pkg['icon'])}</Icon>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
{asset_xml}
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


def app_files(pkg):
    """The menu bar app from dist/ (build it first: sh menubar/build.sh).
    zipfile keeps the file modes, so the program stays executable."""
    app = ROOT / "dist" / APP
    version = app / "Contents" / "Info.plist"
    if not version.exists() or f"<string>{pkg['version']}</string>" not in version.read_text("utf-8"):
        raise SystemExit(f"dist/{APP} is missing or not version {pkg['version']}: run sh menubar/build.sh first")
    for path in sorted(p for p in app.rglob("*") if p.is_file()):
        yield path, "extension/menubar-app/" + path.relative_to(ROOT / "dist").as_posix()


def main():
    pkg = json.loads((ROOT / "package.json").read_text("utf-8"))
    for key in ("publisher", "icon", "bugs", "homepage", "qna"):
        if not pkg.get(key):
            raise SystemExit(f"package.json needs '{key}' for the Marketplace")
    out = ROOT / "dist" / f"{pkg['name']}-{pkg['version']}.vsix"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("extension.vsixmanifest", manifest(pkg))
        for path in files():
            name = "extension/" + path.relative_to(ROOT).as_posix()
            if path == ROOT / "README.md":
                z.writestr(name, readme_for_marketplace(pkg))
            else:
                z.write(path, name)
            print("  ", name)
        for path, name in app_files(pkg):
            z.write(path, name)
            print("  ", name)
    print(out)


if __name__ == "__main__":
    main()

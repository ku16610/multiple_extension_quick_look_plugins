# Multiple Extension Quick Look Plugins

Quick Look preview extensions for macOS 14+ that parse and display the contents of various file types directly , no subprocess spawning needed.

This was created as a small test , and to solve some personal annoyances in my life.

## Supported Formats

| Format     | UTI(s)                                                | Approach                          |
|------------|-------------------------------------------------------|-----------------------------------|
| `.ini`     | `com.microsoft.ini`                                   | Pure Swift INI parser + HTML      |
| `.zip`     | `public.zip-archive`                                  | Pure Swift ZIP central directory  |
| `.dmg`     | `com.apple.disk-image-udif`, `com.apple.disk-image`   | Koly block footer parse (metadata)|
| `.7z`      | `org.7-zip.7-zip-archive`                             | C bridge to `/usr/lib/libarchive.2.dylib` |
| `.iso`     | `public.iso-image`                                    | C bridge to `/usr/lib/libarchive.2.dylib` |
| `.exe`/`.dll` | `com.microsoft.windows-executable`, `com.microsoft.windows-dynamic-link-library` | Pure Swift PE header parser |

## Requirements

- macOS 14.0+
- Xcode 15+ (for building)
- XcodeGen (for generating the Xcode project)

## Build & Install

```bash
# Install XcodeGen (if not installed)
brew install xcodegen

# Generate Xcode project
xcodegen

# Build
xcodebuild -project IniPreviewer.xcodeproj -scheme IniPreviewer -configuration Release -derivedDataPath build archive -archivePath /tmp/IniPreviewer.xcarchive

# Deploy
rm -rf /Applications/IniPreviewer.app
cp -R /tmp/IniPreviewer.xcarchive/Products/Applications/IniPreviewer.app /Applications/

# Register extensions
for ext in /Applications/IniPreviewer.app/Contents/PlugIns/*.appex; do
  pluginkit -a "$ext"
done

# Reset QuickLook cache
launchctl start com.apple.quicklook
```

## Testing

Generate test fixtures and verify individual extensions:

```bash
# INI
echo -e "[section]\nkey=value" > /tmp/test.ini
qlmanage -p /tmp/test.ini

# ZIP
echo "hello" | zip -q /tmp/test.zip -
qlmanage -p /tmp/test.zip

# DMG
hdiutil create -size 1m -fs HFS+ /tmp/test.dmg
qlmanage -p /tmp/test.dmg

# 7z
# install p7zip first: brew install p7zip
echo "hello" > /tmp/test.txt && 7z a /tmp/test.7z /tmp/test.txt
qlmanage -p /tmp/test.7z

# ISO
mkdir -p /tmp/iso_test && echo "hello" > /tmp/iso_test/hello.txt
hdiutil makehybrid -iso -o /tmp/test.iso /tmp/iso_test
qlmanage -p /tmp/test.iso

# PE (Windows executable)
# Download any .exe or .dll file
qlmanage -p /path/to/file.exe
```

Test from Finder by selecting a file and pressing Space.

## Architecture

Each file type is a separate Quick Look app extension (`app-extension` type) embedded in a minimal host app. All extensions use the data-based `QLPreviewProvider` API (`QLIsDataBasedPreview=true`) and return styled HTML.

| Extension              | API                              |
|------------------------|----------------------------------|
| IniPreviewExtension    | Pure Swift — key/value parser    |
| ZipPreviewExtension    | Pure Swift — central directory   |
| DmgPreviewExtension    | Pure Swift — koly block parse    |
| SevenZipPreviewExtension | C bridge — libarchive          |
| IsoPreviewExtension    | C bridge — libarchive            |
| PePreviewExtension     | Pure Swift — PE header parse     |

## Notes

- DMG preview shows metadata (size, compression) since listing files requires mounting the image, which is blocked by sandbox.
- Extensions are sandboxed with `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-only`.
- `qlmanage -p` without `-o` outputs to stdout and exits; use it to verify the extension loads. For file output in tests, add `-o /tmp/qlout`, though this may be broken on some macOS versions.
- If previews stop working after rebuilding, run `launchctl start com.apple.quicklook` to restart QuickLook.

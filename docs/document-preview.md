# Built-in document previews

The IDE and chat side panel use the same preview for PDF, Word and Excel, and the same bundled LaTeX compiler. **Users do not install Office, LibreOffice, MacTeX, MiKTeX or TeX Live.** Document processing is local; no conversion service is used.

## Word

Open a **.docx** file to render it immediately with native Flutter widgets (`docx_file_viewer`). There is no WebView, LibreOffice subprocess, or intermediate PDF. Text, lists, tables, images and supported document formatting are rendered by the library. Results are not guaranteed to reproduce Microsoft Word's pagination or advanced layout exactly. Local and remote project bytes use the same renderer.

## Excel

Open a **.xlsx** file for a read-only, scrollable data grid with row/column headings and worksheet tabs. Shared/inline strings, numbers, booleans and saved formula results are read directly from OOXML. Formula text is shown in the cell tooltip; a formula without a saved result is shown as its expression. There is no formula execution or external-link fetching.

This is a data preview, not Excel itself: charts, pivot tables, merged-cell layout, custom number/date formatting and formula recalculation are not implemented. Limits are 10,000 rows, 256 columns, 200,000 nonempty cells per workbook and 100 sheets; truncated data is explicitly indicated. Parsing runs off the UI isolate. Office previews limit compressed input to 32 MB and declared expanded content to 128 MB.

**Legacy binary .doc and .xls files are explicitly unsupported.** The preview explains that they need to be saved as .docx / .xlsx. They never fall through to the text editor or its save path. Password-protected/encrypted Office files are not supported.

## PDF

PDF uses pdfrx/PDFium inside the app: scrolling, page navigation, zoom and Reload. A reload uses a new document-cache key so the old PDF is not accidentally reused. PDF/Office documents do not pass through the UTF-8 editor.

## LaTeX

Open the main **.tex** file and press **Compile LaTeX Preview**. The app's own **Tectonic 0.17.0** helper (XeTeX-based) compiles the editor's unsaved snapshot. Source remains editable and is not overwritten; relative inputs and images are resolved from the source directory. Source/preview switching retains the mounted editor.

The compiler and a prepared subset of TeX resources/fonts ship inside the installation:

- macOS Apple silicon and Intel: matching native helper, signed before the containing app is sealed/notarized.
- Windows x64: bundled x64 helper. Windows ARM64 uses the same separate helper under **Windows 11 x64 emulation**.
- No PATH search, system TeX fallback or runtime downloads. Compilation uses a local directory bundle with `--only-cached` and `--untrusted`. Shell escape is not enabled.
- The curated resources cover article/book/report/ctexart, common AMS math, geometry, graphics, colors, hyperlinks, tables, listings, fontspec/xeCJK and Latin Modern/Fandol fonts. This is not the complete multi-gigabyte TeX Live distribution. Missing packages produce a build-log error rather than initiating a download.
- Output/auxiliary files live in a unique temporary directory, removed after success or failure. Each compilation has a two-minute timeout and bounded diagnostics. A failed recompile leaves the last successful preview available with the new error/log.

Only local desktop LaTeX projects are supported. Remote, mobile and web compilation, pdfLaTeX/LuaLaTeX engine switching, custom recipes and SyncTeX are not implemented. Included files use their saved disk contents; only the main editor snapshot is unsaved. Compile only trusted input: disabling shell escape is **not a full security sandbox**.

## Building and testing the bundled runtime

Normal distribution entry points `tool/build_macos.dart` and `tool/build_windows.dart` call `tool/prepare_latex.dart` before packaging. The build machine downloads pinned, SHA-256-verified upstream engine archives. During resource preparation only, it fetches the pinned TeX bundle snapshot's required resources using the committed smoke documents. It then creates a local bundle, records every file's SHA-256, and compiles those documents against a **cold cache, offline bundle** before allowing packaging. The other architecture reuses that verified resource set. This increases build/installer size but imposes no user installation step.

For local Flutter development, prepare the matching helper once and explicitly point the debug app at it:

	dart run tool/prepare_latex.dart --platform macos-arm64
	BAOCODE_LATEX_RUNTIME="$PWD/build/latex/macos-arm64" flutter run -d macos

Use `macos-x64`, `windows-x64` or `windows-arm64` as appropriate. `--out` selects an output directory. Production ignores the runtime override and resolves only its app-owned installation directory. A plain `flutter build` is not the distribution packaging command and does not stage the helper.

Relevant tests:

	flutter test test/ide/document_preview test/ide/ide_workspace_model_test.dart
	BAOCODE_LATEX_RUNTIME="$PWD/build/latex/macos-arm64" TECTONIC_CACHE_DIR="$(mktemp -d)" flutter test test/ide/document_preview/latex_integration_test.dart

Licenses/provenance notices and the resource manifest are copied into the runtime directory. Flutter's dependency license registry also includes the native Word renderer and its Dart dependencies.

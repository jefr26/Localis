# Localis

A menu bar assistant for macOS that runs Apple's on-device language model. Ask questions, rewrite text, or drop in a document and get a summary, all without your data leaving your Mac.

Localis is built on Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework. It is a single SwiftUI app with no third-party dependencies.

## Features

- **Lives in the menu bar.** Click the drop icon to open a floating panel. Press Esc to close it. It stays open while you drag files in from Finder.
- **On-device by default.** Requests go to the Apple Intelligence model on your Mac.
- **Works with files.** Attach or drop PDF, Word (`.doc`/`.docx`), RTF, ODT, Markdown, plain text, code, CSV, JSON, HTML and similar files (up to 20 MB, 300,000 characters).
- **Handles long documents.** When a file doesn't fit in the model's context, Localis picks a strategy:
  - **Read all**: splits the file into parts, takes notes on each part, then answers from the notes. Thorough but slower. **Fast mode** reads only an evenly spread sample of 4 parts.
  - **Search**: finds the passages most relevant to your question with BM25 keyword ranking, which runs locally without the model. It then answers from those passages in a single call. Much faster.
  - **Automatic** (default): summaries and templates read everything; specific questions use search, and fall back to reading everything if nothing matches.
- **One-click templates.** Summarize, key points, explain simply, review code and key facts for files. Translate, proofread, write an email and explain for text.
- **Private Cloud Compute (optional).** On macOS 27, Localis can send requests to Apple's larger model running on [Private Cloud Compute](https://security.apple.com/blog/private-cloud-compute/). This requires a signed build; see [Private Cloud Compute](#private-cloud-compute).
- **English and Spanish.** The interface follows your system language, and the model replies in the language of your request.

## Requirements

| | |
|---|---|
| **To run** | macOS 26 or later on a Mac that supports Apple Intelligence, with Apple Intelligence turned on |
| **Private Cloud Compute** | macOS 27 or later, and a build signed with the PCC entitlement |
| **To build** | Xcode 27 (macOS 27 SDK, Swift 6.4) on Apple Silicon |

## Install

Download `Localis-<version>.zip` from the [Releases](../../releases) page, unzip it, and move `Localis.app` to `/Applications`.

Release builds are ad-hoc signed and **not notarized**, so macOS blocks them the first time you open them. To allow it, do one of the following:

- Open **System Settings → Privacy & Security** and click **Open Anyway** next to the Localis message.
- Or remove the quarantine flag from the terminal:

  ```sh
  xattr -dr com.apple.quarantine /Applications/Localis.app
  ```

Localis has no Dock icon. Look for the drop in the menu bar.

## Build from source

```sh
git clone <this repo>
cd Localis
bash build_app.sh            # builds ./Localis.app
open Localis.app
```

`build_app.sh` compiles the Swift package in release mode, assembles the app bundle, compiles the icon and translations, and signs the app. Options:

| Command | Result |
|---|---|
| `bash build_app.sh` | Ad-hoc signed app, no sandbox |
| `SANDBOX=1 bash build_app.sh` | Sandboxed app with read-only access to files you pick, and no network |
| `bash build_app.sh install` | Also copies the app to `/Applications` |
| `PROFILE=path/to.provisionprofile bash build_app.sh` | Signs with your developer identity and enables Private Cloud Compute |

These can be combined, for example `SANDBOX=1 PROFILE=… bash build_app.sh install`.

## Private Cloud Compute

Private Cloud Compute requires the restricted entitlement `com.apple.developer.private-cloud-compute`. macOS only accepts it from an app signed with a provisioning profile that grants it. Without the entitlement, the system reports PCC as available but rejects every request. For that reason, Localis hides the PCC button unless the running copy has the entitlement.

To enable it:

1. In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list), create a macOS App ID and enable the Private Cloud Compute capability. Apple may require you to request access.
2. Create a **macOS App Development** provisioning profile for that App ID, your certificate and your Mac, and download it.
3. Build with the profile:

   ```sh
   PROFILE=~/Downloads/Localis.provisionprofile bash build_app.sh
   ```

   The script checks that the profile includes the entitlement, uses the profile's bundle identifier, embeds the profile and signs with your `Apple Development` identity. If you have more than one identity, set `SIGN_ID`.

Once enabled, a cloud button appears in the panel header. The button is disabled, with a tooltip explaining why, when PCC is unavailable or your usage quota has been reached.

## Localization

Strings live in a String Catalog, [`Resources/Localizable.xcstrings`](Resources/Localizable.xcstrings), with Spanish as the source language and an English translation. Open the catalog in Xcode to edit it. `build_app.sh` compiles it into `.lproj` folders inside the app.

To try another language without changing your system language:

```sh
open Localis.app --args -AppleLanguages "(en)"
```

To add a language, add its translations to the catalog and append its code to `CFBundleLocalizations` in [`Resources/Info.plist`](Resources/Info.plist).

The prompts sent to the model are localized too. Keys starting with `prompt.` hold the internal instructions, so the request, the instructions and the answer stay in the same language.

## Project structure

```
Sources/Localis/
  LocalisApp.swift      App entry point, menu bar item and floating panel
  PromptView.swift      SwiftUI interface
  ModelService.swift    Model access (on-device and PCC), long-file pipeline, errors
  Retrieval.swift       BM25 passage search for long documents
  FileReader.swift      Text extraction from PDF, Word, RTF and plain-text files
  Templates.swift       One-click templates and file modes
  MenuBarIcon.swift     Menu bar icon, drawn as a template image
Resources/
  AppIcon.icon          App icon (Icon Composer)
  Localizable.xcstrings Translations
  Info.plist            Bundle metadata
  Localis.entitlements  Sandbox entitlements
build_app.sh            Builds, signs and optionally installs Localis.app
```

## Releases

The [Build and release](.github/workflows/release.yml) workflow builds the app on every push and pull request to `main`. Pushing a version tag also publishes a GitHub release with the zipped app:

```sh
git tag v0.2.0
git push origin v0.2.0
```

The tag sets the app's version (`CFBundleShortVersionString`), and the workflow run number sets its build number. You can also start the workflow manually from the Actions tab. A manual run builds the app and uploads it as a workflow artifact without creating a release.

## Privacy

Without Private Cloud Compute, everything runs on your Mac. Localis makes no network requests of its own, and the sandboxed build has no network access at all. When you turn on Private Cloud Compute, requests are processed by Apple's Private Cloud Compute servers, which are designed not to store or expose your data.

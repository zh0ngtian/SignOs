# Contributing

SignOs is based on Feather and targets stock iOS. Contributions must preserve that compatibility. Project workflow and delivery requirements live in [AGENTS.md](AGENTS.md).

Any contributions should follow the [Code of Conduct](./CODE_OF_CONDUCT.md).

## Rules

- **No usage of any exploits of any kind**.
- **No contributions related to retrieving any signing certificates owned by companies**.
- **Modifying any hardcoded links should be discussed before changing**.
- **If you're planning on making a large contribution, discuss it in this repository's issue tracker beforehand**.
- **Your contributions should be licensed appropriately**. 
  - Feather: GPLv3
  - AltSourceKit: MIT
  - NimbleKit: MIT 
  - Zsign: MIT
- **Typo contributions are okay**, just make sure they are appropriate.
  - This includes localizations
- **Code cleaning contributions are okay**.

## Contributing to SignOs

#### Compiling requirements

- Xcode 26 or newer on macOS (the project uses Swift language mode 5)
- iOS deployment target: 16.0
- Private TLS files configured as described in [README.md](README.md#building)

1. Clone repository
    ```sh
    git clone --recursive https://github.com/zh0ngtian/SignOs.git
    ```
    - `Zsign` and `IDeviceKitten` are submodules; recursive checkout is required.

2. Opening with Xcode
    ```sh
    cd SignOs && open Feather.xcworkspace
    ```

#### Localizations
- For localizations, you will need Xcode 15 or higher to edit the `Feather/Resources/Localizable.xcstrings` file, or some alternative software which allows you to edit an `.xcstrings` file. 
- We use a newer format for convenience, but at a cost of less accessibility when it comes to actually editing it.
  - **Disclaimer: do NOT edit by hand.**
- Some localizations were imported from V1, if they don't make sense please feel free to change them.
- After localizing, please have another person review your localizations (unless the owners have asked you personally to help translate). 
  - We want high quality localizations and have them actually make sense when in the application.
  - They will not be merged unless the latter was done.

#### Making a pull request

- Make sure your contributions stay isolated in their own branch, and not `main`.
- When contributing don't be afraid of any reviewers requesting changes or judging how you wrote something, it's all to keep the project clean and tidy.

## Contributing to Zsign

When contributing to Zsign, head over to [khcrysalis/Zsign-Package](https://github.com/khcrysalis/Zsign-Package/tree/package) and make your contributions.

Submodule changes require an explicit commit-reference update in this repository; they are not synchronized automatically.

## Contributing to the wiki
- If you want to add a page or suggest edits, make an issue with your proposed changes.

Before delivery, push the change and confirm that `iOS Build Check / iOS Release build` succeeds for the same commit. The workflow runs on main pushes and PRs; its IPA artifacts require separate signing for installation.

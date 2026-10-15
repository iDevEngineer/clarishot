# Contributing to Clarishot

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with:
- what you did, what you expected, and what happened instead
- your macOS version and Clarishot version (**Preferences → About**)
- a screenshot or short recording if it's visual

Please don't include screenshots that show passwords, keys or other private details.

## Suggesting a feature

Open an issue describing the problem it solves. A rough sketch or a screenshot of a similar feature
elsewhere helps.

## Making a change

1. Fork the repo and create a branch: `git checkout -b fix-pin-resize`.
2. Build and try your change: `./scripts/build-app.sh` (see the [developer guide](docs/DEVELOPMENT.md)).
3. Keep the change focused, and match the style of the code around it.
4. Add a line to **Unreleased** in [`CHANGELOG.md`](CHANGELOG.md).
5. Open a pull request explaining what changed and how you tested it.

## Ground rules

- Everything stays on the user's Mac: no network calls, accounts or analytics.
- New permissions need a clear reason and should only be requested when the feature is used.
- Be kind in issues and reviews.

By contributing, you agree your work is released under the [GNU General Public License v3.0](LICENSE).

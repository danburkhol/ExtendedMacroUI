---
name: release
description: >
  Cut a new release of Extended Macro UI: bump the addon version, optionally
  refresh embedded libraries, lint, commit, tag and push so the GitHub Actions
  packager uploads the build to CurseForge. Use when the user wants to mark,
  cut, ship or publish a new version, bump the version and tag a release, or
  "release vX.Y.Z".
---

# Cutting a release

Releasing is driven entirely by a pushed git tag: `.github/workflows/release.yml`
runs the [BigWigs packager](https://github.com/BigWigsMods/packager) on any
`v*` tag, which zips the addon and uploads it to CurseForge using the
`CF_API_KEY` and `X_CURSE_PROJECT_ID` repo secrets. This skill's job is to get a
clean, version-bumped, linted commit tagged correctly and pushed.

## Version model (read before touching anything)

- The addon version lives in **one place only**: `## Version:` in
  [`ExtendedMacroUI.toc`](../../../ExtendedMacroUI.toc). Lua reads it at runtime
  via `C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")` (see
  [`Transfer.lua`](../../../Transfer.lua)), so there is no second copy to update.
- **Do NOT touch `Transfer.VERSION`** in `Transfer.lua`. That is the
  import/export *payload format* version and is bumped only when the export
  format itself changes — never for a normal release.
- This repo folder **is** the live in-game addon, so keep `## Version:` a literal
  (e.g. `0.12.0`), never the packager's `@project-version@` token — that would
  show up as garbage in game.
- Use [semver](https://semver.org): `MAJOR.MINOR.PATCH`. The git tag is the
  version prefixed with `v` (TOC `0.12.0` → tag `v0.12.0`). They must match.

## Steps

### 1. Resolve the new version

- Read the current `## Version:` from the TOC.
- Determine the target version from the user's request:
  - An explicit version (`release 0.12.0`) → use it verbatim.
  - A bump keyword (`patch` / `minor` / `major`) → increment accordingly.
  - Nothing specified → propose a `patch` bump of the current version and ask
    the user to confirm or override before continuing.
- Reject a target that is not strictly greater than the current version, and
  check the tag doesn't already exist (`git tag --list "v<new>"`).

### 2. Pre-flight checks

- `git status --porcelain` — the tree should contain only changes the user
  intends to ship. If there are unexpected modified files, stop and show them;
  don't bundle stray edits into a release.
- Confirm the branch is `main` and current with the remote
  (`git fetch` then compare), unless the user says otherwise.
- Confirm `## Interface:` in the TOC is right for the target realm. It drives
  the game version the packager sets on CurseForge. If unsure, ask the user to
  confirm in game with `/dump select(4, GetBuildInfo())`. Never guess it.

### 3. (Optional) Refresh embedded libraries

Only do this when the user explicitly asks to update dependencies — don't
auto-refresh libs as part of a routine release. The libs are vendored in
`Libs/` and declared in the TOC's `## X-Embeds:` line:

| Library             | Upstream                                             |
| ------------------- | ---------------------------------------------------- |
| LibStub             | https://www.wowace.com/projects/libstub              |
| CallbackHandler-1.0 | WoWUIDev/Ace3 (`CallbackHandler-1.0`)                |
| LibDataBroker-1.1   | https://github.com/tekkub/libdatabroker-1-1          |
| LibDBIcon-1.0       | https://www.wowace.com/projects/libdbicon-1-0        |

To update one: replace its file(s) under `Libs/<lib>/` with the latest upstream
release copy **unmodified**, keep the directory layout and the TOC load order,
then re-run luacheck and ask the user to smoke-test in game before releasing.
Bump the addon version (step 1) to reflect the change. If library churn becomes
frequent, consider converting them to packager `externals` in `.pkgmeta` — but
note that would stop the vendored copies from existing in this live dev folder,
so only do it with the user's agreement.

### 4. Bump the version

Edit `## Version:` in the TOC to the new version. Nothing else needs editing for
a version-only release.

### 5. Lint — must be clean

Run luacheck over the addon's own Lua (never the libs or the Blizzard clone; the
`.luacheckrc` already excludes them):

```
"C:/Users/agent/tools/luacheck/luacheck.exe" .
```

It must report **0 warnings**. Fix anything it flags — or, if the warning is a
genuinely new allowed global, add it to `read_globals` in `.luacheckrc` — before
continuing. (See the [luacheck location](../../../CLAUDE.md) convention.)

### 6. Commit and push main

```
git add ExtendedMacroUI.toc
git commit -m "Release v<new>"
git push origin main
```

Include any library files from step 3 in the `git add` if that path was taken.

### 7. Tag and push the tag

```
git tag -a v<new> -m "v<new>"
git push origin v<new>
```

The tag push is what triggers the release workflow. Do not create the tag before
`main` is pushed, so the tag points at a commit that exists on the remote.

### 8. Report and verify

Tell the user the release is building and give them the links to watch:

- Actions run: the repo's **Actions** tab (the "Release" workflow).
- Result: the CurseForge project's **Files** page once the upload finishes.

Do not claim the upload succeeded until the workflow run is green — if the user
wants confirmation, check the run's conclusion (e.g. via `gh run list`/`gh run
view`) rather than assuming. If it fails, a 401 from CurseForge almost always
means `CF_API_KEY` isn't a valid upload API token.

## Notes

- The packager auto-generates the CurseForge changelog from git commits since
  the previous tag, so write meaningful commit messages; there's no manual
  CHANGELOG file to maintain.
- Follow the repo's commit attribution convention for any commits you create.

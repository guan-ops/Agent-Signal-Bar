# GitHub Release Management

This repository uses GitHub Actions for continuous integration and tag-based releases.

## Daily Checks

Every push and pull request to `main` runs:

- shell script syntax checks
- Python script regression tests
- `swift test`
- builds of every product, including the Intel (`x86_64`) slices
- `./script/verify_local_integrations.sh`

CI does not build the Windows version (`Integrations/Windows`). It is built and tested only by the
release workflow.

Workflow file:

```text
.github/workflows/ci.yml
```

## Release Flow

Releases are created from Git tags. Use semantic version tags:

```bash
v1.0.0
v1.0.1
v1.1.0
```

To publish a new release:

```bash
git status --short
git pull --ff-only
PREVIOUS_TAG=v<previous-version>
NEXT_TAG=v<next-version>
cp "docs/releases/${PREVIOUS_TAG}.md" "docs/releases/${NEXT_TAG}.md"
# Edit docs/releases/${NEXT_TAG}.md before tagging.
git tag "${NEXT_TAG}"
git push origin "${NEXT_TAG}"
```

Pushing the tag starts:

```text
.github/workflows/release.yml
```

The release workflow runs tests, packages the app, verifies checksums, and creates a
**draft** release with:

- `AgentSignalBar.zip`
- `AgentSignalBar.dmg`
- `appcast.xml`
- `AgentSignalBar-v<version>-macos-universal.zip`
- `AgentSignalBar-v<version>-macos-universal.dmg`
- `AgentSignalBar-macos-universal-appcast.xml`
- `AgentSignalBar-release-manifest.json`
- `AgentSignalBar-SHA256SUMS.txt`

Its `windows` job then builds the Windows version, runs the Windows unit tests, and uploads to the
same draft:

- `AgentSignalBar-v<version>-windows-x64-setup.exe`
- `AgentSignalBar-v<version>-windows-x64.zip`
- `AgentSignalBar-windows-x64-appcast.xml`
- `AgentSignalBar-windows-SHA256SUMS.txt`

Nothing is public until a maintainer publishes the draft (see below).

## Publishing the Draft

Immutable releases are enabled for this repository. Once a release is published, its assets can't
be added, replaced or deleted, and its tag is locked. If the release is deleted later, the same tag
name still can't be used again. That is why the workflow stops at a draft: both platforms' files
have to be on the release before it is published.

When both jobs have succeeded, check the draft:

```bash
TAG=v<version>
gh release view "$TAG" --json isDraft,assets --jq '{isDraft, assets: [.assets[].name]}'
CHECK_DIR="$(mktemp -d /private/tmp/asb-release-check.XXXXXX)"
gh release download "$TAG" --dir "$CHECK_DIR"
(cd "$CHECK_DIR" \
  && shasum -a 256 -c AgentSignalBar-SHA256SUMS.txt \
  && shasum -a 256 -c AgentSignalBar-windows-SHA256SUMS.txt)
grep -h "shortVersionString" "$CHECK_DIR"/*appcast*.xml
```

Expect `isDraft: true`, the 8 macOS files and the 4 Windows files, both checksum files passing, and
the new version in all three appcasts. Then publish:

```bash
gh release edit "$TAG" --draft=false --latest
```

This step can't be undone. Both update feeds are read from `releases/latest/download/`, so installed
apps see the new version only after this.

If a job fails, the draft stays unpublished and no user sees it. Re-run the failed job from the
Actions page; the Windows upload uses `--clobber`, so a re-run replaces its files. If the fix needs a
code change, delete the draft and the tag (neither is locked before publishing), merge the fix and
push the tag again. After publishing, fix problems with a new patch version instead.
 macOS binaries by default (`arm64 x86_64`),
so the app, bundled CLI, release CLI, and icon preview CLI are verified for both
Apple Silicon and Intel Mac.

`appcast.xml` is the legacy Sparkle update feed used by existing installed apps.
New builds point to the platform-named universal feed:

```text
https://github.com/guan-ops/Agent-Signal-Bar/releases/latest/download/AgentSignalBar-macos-universal-appcast.xml
```

Keep publishing both feeds during the migration so older installs can still
update through `appcast.xml`.

Before publishing Sparkle-enabled releases from GitHub Actions, configure the repository secret:

```text
SPARKLE_PRIVATE_KEY
```

Export the private key locally with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.agentsignallight.AgentSignalLight \
  -x /tmp/AgentSignalBar-sparkle-private-key.txt
```

Paste that file's contents into the GitHub Actions secret, then delete the exported file. Do not commit Sparkle private keys.

The release body is read from:

```text
docs/releases/<tag>.md
```

For example, tag `v1.0.4` uses:

```text
docs/releases/v1.0.4.md
```

Every release note should be bilingual and use this structure:

- English
  - Highlights
  - Changes
  - Fixes, when applicable
  - Release verification
  - Downloads
- 简体中文
  - 亮点
  - 改进
  - 修复，如适用
  - 发布验证
  - 下载

This keeps GitHub Releases readable instead of publishing only an automatic commit list.

## Version Checklist

Before tagging a new version, confirm:

- `VERSION` has the intended `VERSION=x.y.z` and monotonically increasing `BUILD=n`.
- `docs/releases/<tag>.md` exists and includes clear Chinese and English release notes.
- `README.md` and `README.zh-CN.md` describe the current behavior.
- `SPARKLE_PRIVATE_KEY` is configured in the `release` environment before pushing a tag. Both the macOS and the Windows appcasts are signed with it.
- `./script/verify_release_all.sh --skip-package` passes if artifacts already exist, including universal architecture checks.
- `./script/verify_release_all.sh` passes for a full local release gate and confirms the app/CLI contain `arm64 x86_64` slices.

## Commit Identity

Use the GitHub noreply identity so commits are attributed to the `guan-ops` account while keeping the real email private:

```bash
git config --global user.name "XiongYang Guan"
git config --global user.email "202207961+guan-ops@users.noreply.github.com"
```

## Notes

The generated DMG is a local/self-use build unless Developer ID signing and notarization credentials are configured. See `docs/RELEASE_CHECKLIST.md` for distribution readiness.

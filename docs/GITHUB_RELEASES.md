# GitHub Release Management

This repository uses GitHub Actions for continuous integration and tag-based releases.

## Daily Checks

Every push and pull request to `main` runs:

- shell script syntax checks
- `swift test`
- `./script/verify_local_integrations.sh`

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

The release workflow runs tests, packages the app, verifies checksums, and uploads:

- `AgentSignalBar.zip`
- `AgentSignalBar.dmg`
- `AgentSignalBar-release-manifest.json`
- `AgentSignalBar-SHA256SUMS.txt`

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
- `./script/verify_release_all.sh --skip-package` passes if artifacts already exist.
- `./script/verify_release_all.sh` passes for a full local release gate.

## Commit Identity

Use the GitHub noreply identity so commits are attributed to the `guan-ops` account while keeping the real email private:

```bash
git config --global user.name "XiongYang Guan"
git config --global user.email "202207961+guan-ops@users.noreply.github.com"
```

## Notes

The generated DMG is a local/self-use build unless Developer ID signing and notarization credentials are configured. See `docs/RELEASE_CHECKLIST.md` for distribution readiness.

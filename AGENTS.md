# Repository Agent Instructions: tomatt CI Delivery

This repository builds the macOS app `tomatt.app` from `tomatt.xcodeproj` using the `tomatt` scheme.

## Build, signing, and notarization authority

- GitHub Actions is the only authorized build, signing, notarization, stapling, validation, packaging, and artifact source for this repository.
- The workflow is `.github/workflows/main.yml`; it is intended to run on branch pushes and `v*` tags.
- Never run local Xcode builds, local `xcodebuild`, local signing builds, or local notarization for this repo.
- Do not materially edit `.github/workflows/main.yml` unless a GitHub Actions log for the exact commit proves a workflow defect.
- If CI fails, inspect remote logs with `gh run view --repo tingkai-c/tomatt <run-id> --log-failed`, patch only the proven defect, commit, push, and re-run CI.

## Git and GitHub CLI policy

- Use concise normal git commit messages in this repository.
- Do not use OMX Lore Commit Protocol trailers here; this file is the repo-local override for commit-message style.
- Push completed work to `origin` so GitHub Actions can produce the signed artifact.
- Always pass `--repo tingkai-c/tomatt` to `gh` commands. Do not rely on `gh`'s inferred repository, because local remotes include upstream repositories.

## Required post-task delivery loop

After any agent completes a task, feature, or bug fix:

1. Confirm `.github/workflows/main.yml` is unchanged unless CI evidence requires a workflow fix.
2. Run only static/non-build checks locally. Do not run local builds.
3. Commit with a concise normal commit message and no OMX Lore trailers.
4. Push to `origin`.
5. Identify the GitHub Actions run for the exact pushed commit SHA.
6. Wait for that run to complete successfully.
7. Download the artifact from that run ID.
8. Unzip the artifact and confirm it contains `tomatt.app`.
9. Quit any running `tomatt` process.
10. Back up an existing `/Applications/tomatt.app` using a timestamped backup path.
11. Install the downloaded CI artifact to `/Applications/tomatt.app`.
12. Report the CI URL, artifact path/name, install path, and backup path when present.

Reference command shape:

```bash
repo="tingkai-c/tomatt"
sha="$(git rev-parse HEAD)"
run_id="$(gh run list --repo "$repo" --commit "$sha" --limit 1 --json databaseId --jq '.[0].databaseId')"
run_url="$(gh run view --repo "$repo" "$run_id" --json url --jq .url)"
gh run watch --repo "$repo" "$run_id" --exit-status
```

Artifact install command shape:

```bash
repo="tingkai-c/tomatt"
workdir="/tmp/tomatt-ci-artifact-$run_id"
stamp="$(date +%Y%m%dT%H%M%S)"

rm -rf "$workdir"
mkdir -p "$workdir/download" "$workdir/unzipped"

gh run download --repo "$repo" "$run_id" --dir "$workdir/download"
zip_path="$(find "$workdir/download" -type f -name '*.zip' | head -n 1)"
test -n "$zip_path"
ditto -x -k "$zip_path" "$workdir/unzipped"
test -d "$workdir/unzipped/tomatt.app"

osascript -e 'tell application "tomatt" to quit' 2>/dev/null || true
sleep 2
if pgrep -x tomatt >/dev/null 2>&1; then
  echo "tomatt is still running; cannot safely replace /Applications/tomatt.app" >&2
  exit 1
fi

if [[ -d /Applications/tomatt.app ]]; then
  mv /Applications/tomatt.app "/Applications/tomatt.app.backup-$stamp"
fi
cp -R "$workdir/unzipped/tomatt.app" /Applications/tomatt.app
```

If permissions block installation to `/Applications`, stop and report the exact command and error instead of silently installing elsewhere.

## Apple signing secrets

Signing material lives outside the repo under `~/certificates/apple/` and must never be committed or printed.

The app-specific signing notes file is:

```text
~/certificates/apple/apps/tomatt/README.md
```

Canonical GitHub Actions secret names for `tingkai-c/tomatt`:

- `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`
- `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `APPLE_TEAM_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_BASE64`

Do not rotate or re-seed secrets just to prove setup. Rotate or sync secrets only when CI logs show missing, invalid, or expired credentials, or when the user explicitly requests a credential refresh. When syncing is required, read from `~/certificates/apple/team` and pass values to `gh secret set --repo tingkai-c/tomatt` through stdin or `--body` without printing values.

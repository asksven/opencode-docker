# Dockerfile Review Follow-up Plan

## Context

PR [#1](https://github.com/asksven/opencode-docker/pull/1) was merged before the Copilot review completed. The PR merged at `2026-09-13T16:09:02Z`; the review was submitted at `2026-09-13T16:12:10Z`.

The review identified four valid issues:

1. The Compose service references the wrong container repository.
2. The uv cache is not re-owned when `PUID`/`PGID` are changed at runtime.
3. Clearing supplementary groups prevents the unprivileged process from accessing a normally permissioned host Docker socket.
4. The documented Buildx command combines a multi-platform build with the single-image Docker exporter.

Implement these fixes in a follow-up branch and pull request based on the merged `main` branch. Keep the changes focused on the review findings.

## PR #2 Copilot Review Handover

This section is the authoritative implementation plan for the Copilot review on PR [#2](https://github.com/asksven/opencode-docker/pull/2). It supersedes the historical plan retained later in this document.

Copilot reviewed PR #2 at commit `a19ecf584f9f5f4f41e154db2dd1bc28050c059c` and submitted two inline comments:

1. [Publication is not gated on runtime tests](https://github.com/asksven/opencode-docker/pull/2#discussion_r4004123502).
2. [The release polling interval changed from 15 minutes to daily](https://github.com/asksven/opencode-docker/pull/2#discussion_r4004123538).

### Review Disposition

#### Must Fix: Gate publication on successful image tests

The first comment is valid and requires a workflow change. Both workflows currently run independently after relevant changes reach `main`:

- `.github/workflows/test-image.yml` builds and tests the image.
- `.github/workflows/update-image.yml` builds and pushes the image.

Because neither workflow waits for the other, `update-image.yml` can publish while `test-image.yml` is still running, and can still publish if the test workflow later fails. The publish workflow must own an explicit dependency on the runtime test result.

#### No Change: Preserve the once-daily schedule

The second comment correctly identifies the behavioral change, but no correction is required. Changing the schedule to once daily was an explicit user requirement made after the initial plan. Preserve:

```yaml
schedule:
  - cron: '0 0 * * *'  # Every day at 00:00 UTC
```

Do not restore the 15-minute cadence. The accepted tradeoff is that a new upstream OpenCode release can wait almost 24 hours before publication. Push-triggered source rebuilds and manual dispatches remain available independently of this daily polling cadence.

## Target Workflow Design

Use `test-image.yml` as both the pull-request test workflow and a reusable workflow called by `update-image.yml`.

The intended flow is:

```text
Pull request affecting image code or tests:
  test-image.yml -> build both platforms -> runtime entrypoint tests

Relevant push to main, daily schedule, or manual dispatch:
  update-image.yml/check
    -> if no update: stop successfully
    -> if update required: reusable test-image.yml
      -> if tests fail or are cancelled: do not publish
      -> if tests pass: update-image.yml/publish
```

This design is preferred over `workflow_run` because it keeps the update decision, required test, and publication in one visible job dependency graph. It also avoids passing state between independent workflow runs.

## Required Implementation

### 1. Make `test-image.yml` reusable

File: `.github/workflows/test-image.yml`

Keep the existing `pull_request` trigger and add `workflow_call` with a typed input:

```yaml
on:
  pull_request:
    paths:
      - Dockerfile
      - entrypoint.sh
      - tests/**
      - .github/workflows/test-image.yml
      - .github/workflows/update-image.yml
  workflow_call:
    inputs:
      opencode_version:
        description: OpenCode version to build and test
        required: false
        type: string
        default: latest
```

Implementation requirements:

- Remove the direct `push` trigger from `test-image.yml`. Push-triggered testing will be invoked by `update-image.yml`; retaining both paths would run duplicate tests and would not itself gate publication.
- Add `.github/workflows/update-image.yml` to the pull-request path filter because changes to publication orchestration should exercise the reusable workflow before merge.
- Keep workflow permissions at `contents: read` and do not request package write access.
- Do not inherit or pass repository secrets into this reusable test workflow.
- Keep QEMU setup and Buildx setup before image builds.
- Keep the multi-platform validation build for `linux/amd64,linux/arm64`.
- Keep the loaded native runtime image used by `tests/test-entrypoint.sh`.
- Keep `REQUIRE_DOCKER_SOCKET: '1'` so missing socket coverage fails in CI instead of silently weakening the publication gate.

### 2. Test the exact OpenCode version selected for publication

File: `.github/workflows/test-image.yml`

Both Docker build steps currently hard-code:

```yaml
OPENCODE_VERSION=latest
```

Replace that value with the reusable workflow input, while retaining `latest` as the fallback for direct pull-request runs:

```yaml
build-args: |
  OPENCODE_VERSION=${{ inputs.opencode_version || 'latest' }}
```

Apply this to both:

- `Build all target platforms`
- `Build runtime test image`

Behavior by invocation:

- A pull-request event has no caller-supplied input and must test `latest`.
- A call from `update-image.yml` must test the exact version emitted by the release-detection step.

Do not rely solely on the `workflow_call` default for pull-request events; retain the explicit `|| 'latest'` fallback.

### 3. Add a gated reusable test job to `update-image.yml`

File: `.github/workflows/update-image.yml`

Add a job after `check` and before the publishing job:

```yaml
  test:
    needs: check
    if: ${{ needs.check.outputs.needs_update == 'true' }}
    permissions:
      contents: read
    uses: ./.github/workflows/test-image.yml
    with:
      opencode_version: ${{ needs.check.outputs.version }}
```

Requirements:

- Call the reusable workflow at job level with `uses`; do not attempt to call it from a step.
- Use the local `./.github/workflows/test-image.yml` reference without an `@ref`. GitHub resolves a local reusable workflow from the same commit as the caller.
- Pass `needs.check.outputs.version`, ensuring tests and publication use the same requested OpenCode version.
- Run the test job only when `needs_update` is `true`.
- Grant only `contents: read` to the calling test job.
- Do not use `secrets: inherit`.

### 4. Make publication depend on the test result

File: `.github/workflows/update-image.yml`

Rename the current `build` job to `publish` so its side effect is explicit. Change its dependencies from only `check` to both `check` and `test`:

```yaml
  publish:
    needs: [check, test]
    if: >-
      ${{
        !cancelled() &&
        needs.check.result == 'success' &&
        needs.check.outputs.needs_update == 'true' &&
        needs.test.result == 'success'
      }}
```

Requirements:

- Publication must not run if `check` fails.
- Publication must not run if the reusable test fails, is skipped unexpectedly, or is cancelled.
- Publication must remain skipped when `needs_update` is `false`.
- Do not use `always()` by itself; it could allow execution after failures unless every dependency result is guarded explicitly.
- Keep `packages: write` isolated to the `publish` job.
- Keep the existing checkout, QEMU, Buildx, GHCR login, multi-platform build/push, version tag, `latest` tag, and post-push manifest inspection.
- Continue passing `needs.check.outputs.version` as `OPENCODE_VERSION` to the publish build.

Expected failure behavior:

- Release feed or manifest comparison failure: `check` fails; `test` and `publish` do not run.
- No update needed: `check` succeeds; `test` and `publish` are skipped; the workflow succeeds.
- Image build or runtime test failure: `test` fails; `publish` is skipped; the workflow fails.
- Cancellation during checking or testing: `publish` is skipped.
- Push or manifest inspection failure: `publish` fails and the workflow reports failure.

### 5. Preserve update triggers and decision behavior

File: `.github/workflows/update-image.yml`

Keep all current update entry points:

- Relevant pushes to `main` for `Dockerfile`, `entrypoint.sh`, or `.github/workflows/update-image.yml` force `needs_update=true`.
- The daily `0 0 * * *` schedule checks for a new stable OpenCode version.
- Manual dispatch remains available.
- `force_rebuild=true` forces `needs_update=true` even when manifests match.

Do not add `tests/**` or `.github/workflows/test-image.yml` to the publishing workflow's push paths. Changes only to tests should validate in their pull request, but should not republish an unchanged production image after merge.

Prefer evaluating the `force_rebuild` input as a boolean GitHub expression rather than interpolating it into shell. If the existing shell comparison is retained, verify it behaves correctly for push and schedule events where that input is unset.

## Event Matrix

Verify the resulting workflows against every supported event:

| Event | Update decision | Image tests | Publish |
| --- | --- | --- | --- |
| PR changing Dockerfile, entrypoint, tests, or either workflow | Not applicable | Run with `OPENCODE_VERSION=latest` | Never |
| Relevant push to `main` | Forced update | Run with detected stable version | Only after success |
| Daily schedule, manifests match | No update | Skip | Skip |
| Daily schedule, new version or missing manifest | Update | Run with detected stable version | Only after success |
| Manual dispatch without force, manifests match | No update | Skip | Skip |
| Manual dispatch with force | Forced update | Run with detected stable version | Only after success |
| Check failure | Unknown | Skip | Skip |
| Test failure or cancellation | Update required | Fail/cancel | Skip |

## Verification Plan

### Static validation

Run from the repository root:

```bash
shellcheck entrypoint.sh tests/test-entrypoint.sh
sh -n entrypoint.sh
bash -n tests/test-entrypoint.sh
git diff --check
```

Install or use `actionlint` and validate both workflow files:

```bash
actionlint .github/workflows/test-image.yml .github/workflows/update-image.yml
```

Confirm the workflow structure manually or with an Actions-aware parser:

- `test-image.yml` includes both `pull_request` and `workflow_call` but no `push` trigger.
- The reusable input is a string and defaults to `latest`.
- Both test builds consume the effective input value.
- `update-image.yml` has `check -> test -> publish` dependencies.
- Only `publish` has `packages: write`.
- The schedule remains `0 0 * * *`.

### Pull-request validation

Push the workflow changes to PR #2 and confirm:

- The `Test Docker Image` workflow starts for the workflow changes.
- Both architecture builds succeed.
- The loaded runtime image succeeds in `tests/test-entrypoint.sh`.
- No package publication job runs for the pull request.
- The check reports the PR head SHA, not the default branch SHA.

### Gating validation

Before merging, inspect the rendered Actions dependency graph and confirm that `publish` depends on the reusable `test` job.

After merging a relevant image-source change to `main`, confirm in one `Update Docker Image` run:

1. `check` sets `needs_update=true` and emits the detected version.
2. `test` runs using that version.
3. `publish` remains pending or skipped until `test` completes.
4. `publish` starts only after `test` succeeds.

Validate the failure gate without publishing a broken image. A safe approach is to inspect a PR run with a deliberately failing test and confirm that the reusable workflow fails, then validate the `publish` condition through `actionlint` and the Actions job graph. Do not merge an intentionally failing test into `main` merely to exercise the production publisher.

### Published image validation

After the first successful gated publication:

```bash
docker buildx imagetools inspect ghcr.io/asksven/opencode-docker:<version>
docker buildx imagetools inspect ghcr.io/asksven/opencode-docker:latest
```

Confirm:

- Both tags resolve successfully.
- Both tags point to the newly published release.
- The manifest contains `linux/amd64` and `linux/arm64` images.
- The workflow's post-push inspection succeeded.
- Pulling and running `latest` passes the Docker CLI example documented in `README.md`.

### No-update validation

Run a manual dispatch with `force_rebuild=false` after the version and `latest` manifests match. Confirm:

- `check` sets `needs_update=false`.
- `test` is skipped.
- `publish` is skipped.
- The overall workflow is successful rather than failed.

Then run a manual dispatch with `force_rebuild=true` and confirm the complete `check -> test -> publish` path runs.

## Acceptance Criteria

- PR image tests continue to run without package write permission.
- `test-image.yml` is reusable through `workflow_call`.
- `test-image.yml` no longer runs independently on pushes to `main`.
- Both test builds use `latest` for PRs and the detected release version when called by the update workflow.
- Every source-triggered, scheduled, or manually forced publication requires a successful reusable image test.
- A failed or cancelled test cannot start the publish job.
- A no-update run skips both test and publish jobs without failing the workflow.
- Only the publish job has `packages: write`.
- The once-daily `0 0 * * *` schedule remains unchanged.
- The current 15-minute polling cadence is not restored.
- `actionlint`, shell syntax checks, ShellCheck, and `git diff --check` pass.
- The first gated publish produces valid amd64 and arm64 manifests for both the version tag and `latest`.

## Scope Boundaries

- Do not change the daily schedule; it is an explicit product decision.
- Do not replace the workflow dependency with branch-protection assumptions. Branch protection can gate merging, but it does not create a runtime dependency inside a post-merge publication workflow.
- Do not use a `workflow_run` chain unless the reusable-workflow approach proves impossible.
- Do not grant package write permission to PR tests or the reusable test job.
- Do not pass repository secrets to PR-controlled image or entrypoint tests.
- Do not change Docker socket permissions or weaken `REQUIRE_DOCKER_SOCKET=1` in CI.
- Do not redesign the image into exact artifact promotion as part of this fix. Testing and publishing rebuild the same commit and OpenCode version, but external package sources can still change between builds; digest-based promotion is a separate enhancement.
- Do not modify Dockerfile contents, entrypoint behavior, Compose configuration, or user documentation unless required to keep them consistent with the workflow gating change.

## Historical Plan

The remaining sections document the implementation and review history leading to PR #2. They are reference material only and must not override the PR #2 handover above.

### Previous Implementation Review Findings

The original changes below were implemented in PR #2. Their requirements are retained for traceability.

### Must Fix

#### 1. Ensure source changes are published to `latest`

Files: `.github/workflows/update-image.yml`, `README.md`, `docker-compose.yml`

The updated README and Compose file use `ghcr.io/asksven/opencode-docker:latest`, but the currently published `latest` image predates these source changes. It therefore does not yet contain the added Docker tooling, cache ownership fix, or socket-group propagation documented by this change.

The existing workflow does not resolve this after merge:

- It runs on a schedule or manual dispatch, not on source pushes to `main`.
- Its comparison only checks whether the current OpenCode version tag and `latest` point to equivalent manifests.
- If the upstream OpenCode version has not changed, a Dockerfile or entrypoint change does not make `needs_update` true.
- Manual dispatch follows the same comparison and cannot force a source-only rebuild.

Update the workflow so relevant image-source changes can rebuild and publish the current OpenCode version and `latest`. The minimal recommended approach is:

- Add a `push` trigger for `main`, restricted to image inputs such as `Dockerfile`, `entrypoint.sh`, and the workflow itself.
- Keep the release-feed lookup so the image retains the current OpenCode version tag.
- Make the build job run unconditionally for that relevant `push` event, while preserving the existing manifest comparison for scheduled runs.
- Optionally add a boolean `force_rebuild` input to `workflow_dispatch`, but do not rely on manual dispatch as the only way source fixes reach the registry.
- Avoid triggering image rebuilds for README-only or Compose-only changes.

After merge, confirm that both the current version tag and `latest` resolve to the newly built multi-platform manifest. Then run the README's `docker version` example against the published image.

Completion criteria:

- A relevant push to `main` rebuilds the image even when the OpenCode version is unchanged.
- Scheduled runs still skip a build when neither the OpenCode version nor image source has changed.
- `ghcr.io/asksven/opencode-docker:latest` contains the entrypoint and Docker tooling from this change.
- The published manifest contains both `linux/amd64` and `linux/arm64` images.

#### 2. Complete image-level runtime verification

Files: `entrypoint.sh`, `Dockerfile`, `docker-compose.yml`

Static checks and Compose rendering pass, but the implementation environment had no Docker daemon at `/var/run/docker.sock`. As a result, the local image build, `docker compose pull`, custom-ID cache test, and Docker socket integration test were not executed. These checks are required because the new behavior crosses image ownership, privilege dropping, supplementary groups, and host-daemon access.

Run the verification commands already listed in this plan on a trusted host with a working Docker daemon. Do not approve or publish the implementation until all of the following are demonstrated:

- The image builds for `linux/amd64` and `linux/arm64`.
- Starting as root with non-default `PUID`/`PGID` drops to exactly those IDs.
- The resulting process can write to `UV_CACHE_DIR`.
- With no socket mounted, no unexpected supplementary groups remain.
- With a socket whose GID differs from `PGID`, the process receives that numeric GID as its supplementary group and `docker version` reaches the daemon.
- With a socket whose GID equals `PGID`, access works through the primary group and supplementary groups remain cleared.
- Commands containing empty or whitespace-containing arguments survive the entrypoint unchanged.
- `docker compose pull` succeeds for the corrected image reference.

### Should Fix

#### 1. Qualify Docker socket propagation documentation

Files: `README.md`, optionally `docker-compose.yml`

The README currently states unconditionally that the entrypoint grants the socket's numeric group ID. That only happens when the container starts as root. An explicit Docker `--user` override, or enabling the commented `user` setting in `docker-compose.yml`, bypasses UID/GID remapping and supplementary-group setup.

Update the README to state that automatic socket-group propagation requires the default root-starting entrypoint. Warn that overriding the container user disables this setup and may make a `0660` Docker socket inaccessible unless groups are configured externally. Consider removing or clarifying the commented Compose `user` example so it does not suggest a configuration that silently bypasses `PUID`/`PGID` and socket handling.

#### 2. Make the local build example native-platform by default

File: `README.md`

The local build example hard-codes `--platform linux/amd64`. On an ARM64 host this becomes a cross-platform build, and this Dockerfile executes target binaries during `RUN` instructions. Without registered binfmt/QEMU emulation, the example can fail even though a native ARM64 build would work.

Prefer omitting `--platform` from the local `--load` example so Buildx selects the host platform. If the platform remains explicit, document that ARM64 users must substitute `linux/arm64` and that cross-platform local builds require emulation.

#### 3. Document multi-platform builder prerequisites

File: `README.md`

Registry authentication is not the only prerequisite for the documented multi-platform `--push`. The builder must also support both target platforms, either through native workers or binfmt/QEMU emulation. The GitHub workflow explicitly configures QEMU and Buildx before building.

Add a concise prerequisite next to the multi-platform command stating that it requires a multi-platform-capable Buildx builder and native workers or binfmt/QEMU support.

#### 4. Add repeatable entrypoint regression coverage

Files: new test script or existing test location if one is introduced, plus CI configuration if appropriate

The cache and socket fixes currently rely on manual image-level verification. Add repeatable coverage for the security-relevant entrypoint branches:

- Non-default `PUID`/`PGID` with a writable uv cache.
- No socket mounted.
- Socket GID equal to `PGID`.
- Socket GID different from `PGID`.
- Exact preservation of command arguments, including empty and whitespace-containing values.

The tests should assert final UID, primary GID, supplementary groups, cache writability, and socket accessibility. Keep a real `docker version` integration check for a trusted Docker-enabled environment even if lower-level tests use a temporary Unix socket.

## Required Changes

### 1. Make the uv cache writable with custom IDs

File: `entrypoint.sh`

The Dockerfile creates `/home/opencode/.cache/uv` and sets it as `UV_CACHE_DIR`, but the entrypoint only changes ownership of `.config` and `.local` after remapping the `opencode` user.

Update the runtime ownership operation to include `/home/opencode/.cache`:

- Continue changing ownership only when the container starts as root.
- Keep the ownership paths explicit: `.config`, `.local`, and `.cache`.
- Do not recursively change ownership of unrelated mounted paths or `/workspace`.
- Preserve the existing configurable `PUID` and `PGID` behavior.

Expected result: starting the image with non-default `PUID`/`PGID` leaves `UV_CACHE_DIR` writable by the final unprivileged process.

Review: [discussion_r4000111525](https://github.com/asksven/opencode-docker/pull/1#discussion_r4000111525)

### 2. Propagate Docker socket access safely

File: `entrypoint.sh`

The Dockerfile tells users they can mount `/var/run/docker.sock`, but the entrypoint executes the application with `setpriv --clear-groups`. A typical host socket has mode `0660` and ownership `root:<host-docker-gid>`, so the final process cannot access it unless its primary GID happens to match the socket GID.

When the entrypoint starts as root:

- Check whether `/var/run/docker.sock` is a Unix socket.
- Read its numeric GID with `stat`.
- If the socket GID differs from `PGID`, pass that numeric GID to `setpriv` as a supplementary group using `--groups`.
- If the socket GID equals `PGID`, or no socket is mounted, retain the current behavior of clearing supplementary groups.
- Continue setting the final real/effective UID and GID to `PUID` and `PGID`.
- Use the numeric socket GID directly. Do not depend on the host and container having matching group names.
- Do not change socket permissions and do not use `chmod 666`.
- Preserve argument boundaries when executing `"$@"`.

The intended control flow is equivalent to:

```sh
if [ -S /var/run/docker.sock ]; then
    socket_gid="$(stat -c '%g' /var/run/docker.sock)"
    if [ "${socket_gid}" != "${PGID}" ]; then
        exec setpriv --reuid "${PUID}" --regid "${PGID}" --groups "${socket_gid}" "$@"
    fi
fi

exec setpriv --reuid "${PUID}" --regid "${PGID}" --clear-groups "$@"
```

Adapt this to the existing entrypoint rather than duplicating its UID/GID setup.

Expected result: mounting a standard host Docker socket allows the unprivileged `opencode` process to use the Docker CLI without making the socket world-writable.

Review: suppressed Dockerfile line 45 comment in the [overall review](https://github.com/asksven/opencode-docker/pull/1#pullrequestreview-5191314046)

### 3. Correct the Compose image reference

File: `docker-compose.yml`

Change the service image from:

```yaml
image: ghcr.io/asksven/opencode:1.18.18
```

to:

```yaml
image: ghcr.io/asksven/opencode-docker:latest
```

Rationale:

- `.github/workflows/update-image.yml` publishes `ghcr.io/asksven/opencode-docker`.
- `README.md` documents that same repository.
- `ghcr.io/asksven/opencode-docker:1.18.18` currently returns `manifest unknown`.
- `ghcr.io/asksven/opencode-docker:latest` exists and is a multi-architecture image.
- The workflow advances the published version automatically, but it does not update a Compose version pin.

Do not add image-variable indirection unless a separate requirement calls for user-selectable image tags.

Expected result: `docker compose pull` retrieves an image produced by this repository.

Review: [discussion_r4000111539](https://github.com/asksven/opencode-docker/pull/1#discussion_r4000111539)

### 4. Replace the invalid Buildx example

Files: `Dockerfile`, `README.md`

Remove the trailing build-command comment from the Dockerfile. Build usage belongs in the README, and the current command is invalid because `--output type=docker` cannot load a multi-platform manifest into the local Docker image store.

Expand the README's Building section with two clearly separated examples.

Local, single-platform build:

```bash
docker buildx build \
  --platform linux/amd64 \
  --load \
  -t opencode-docker:local \
  .
```

Use the host's platform instead of hard-coding `linux/amd64` if that better matches the final documentation, but keep this example single-platform when using `--load`.

Multi-platform registry build:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t ghcr.io/asksven/opencode-docker:<tag> \
  .
```

State that the multi-platform command requires registry authentication and a real tag in place of `<tag>`.

Expected result: neither documented command combines multiple platforms with `--load` or `--output type=docker`.

Review: suppressed Dockerfile line 162 comment in the [overall review](https://github.com/asksven/opencode-docker/pull/1#pullrequestreview-5191314046)

### 5. Document Docker socket security

File: `README.md`

Add a short section for using the included Docker CLI:

- Explain that the image contains the Docker CLI, Compose plugin, and Buildx plugin, but no Docker daemon.
- Show `/var/run/docker.sock:/var/run/docker.sock` as the optional socket mount.
- Explain that the entrypoint grants the unprivileged process the socket's numeric group when the socket is present.
- Warn that access to the Docker daemon is effectively root-level access to the host and should only be enabled for trusted workloads.

Do not add the socket mount to the default Compose service. It should remain an explicit opt-in because of its host-level security implications.

## Verification

Run all checks from the repository root.

### Static checks

```bash
shellcheck entrypoint.sh
git diff --check
```

If `hadolint` is available locally, also run:

```bash
hadolint Dockerfile
```

### Compose validation

Provide required environment variables while validating the rendered configuration:

```bash
TZ=Europe/Berlin \
OPENROUTER_API_KEY=placeholder \
docker compose config
```

Confirm that the rendered image is `ghcr.io/asksven/opencode-docker:latest`, then run:

```bash
docker compose pull
```

### Image build

Build a local single-platform test image:

```bash
docker buildx build \
  --platform linux/amd64 \
  --load \
  -t opencode-docker:review-fixes \
  .
```

On an ARM64 host, use `linux/arm64` for the local loaded build.

Also verify that both supported Dockerfile architecture paths build. Use a multi-platform Buildx builder and either a disposable registry tag with `--push` or a non-loading validation output appropriate for the available builder. Do not attempt to load both architectures into the local Docker image store.

### Custom UID/GID and uv cache

Run the image with IDs that differ from the image defaults:

```bash
docker run --rm \
  -e PUID=12345 \
  -e PGID=12345 \
  --entrypoint /usr/local/bin/entrypoint.sh \
  opencode-docker:review-fixes \
  sh -c 'test "$(id -u)" = 12345 && test "$(id -g)" = 12345 && touch "${UV_CACHE_DIR}/write-test"'
```

The command must exit successfully and create the cache probe as UID/GID `12345:12345`.

### Docker socket group

On a trusted test host with a running Docker daemon:

```bash
docker run --rm \
  -e PUID=12345 \
  -e PGID=12345 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --entrypoint /usr/local/bin/entrypoint.sh \
  opencode-docker:review-fixes \
  sh -c 'id && docker version'
```

Confirm that:

- The process UID and primary GID are `12345`.
- The socket's numeric GID appears in the process's supplementary groups when it differs from `12345`.
- `docker version` reaches the host daemon successfully.
- Running without the socket still starts normally and does not retain unexpected supplementary groups.

## Acceptance Criteria

- A custom `PUID`/`PGID` can write to `UV_CACHE_DIR`.
- The unprivileged process can access an explicitly mounted Docker socket through its numeric socket GID.
- No socket permissions are broadened by the image or entrypoint.
- The default Compose configuration uses `ghcr.io/asksven/opencode-docker:latest`.
- `docker compose config` and `docker compose pull` succeed with required environment values supplied.
- Local build documentation uses one platform with `--load`.
- Multi-platform build documentation uses `--push`.
- The Dockerfile no longer contains the invalid multi-platform Docker-exporter example.
- The README warns that Docker socket access is equivalent to host root access.
- `shellcheck entrypoint.sh`, `git diff --check`, and the local image build pass.

## Scope Boundaries

- Modify the image publishing workflow only as required by Must Fix finding 1; avoid unrelated workflow changes.
- Do not add a Docker daemon to the image.
- Do not make Docker socket mounting part of the default Compose configuration.
- Do not introduce compatibility layers or configuration options unrelated to these review comments.
- Do not alter existing persistent-volume paths beyond the required cache ownership fix.

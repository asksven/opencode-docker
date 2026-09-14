# Dockerfile Review Follow-up Plan

## Context

PR [#1](https://github.com/asksven/opencode-docker/pull/1) was merged before the Copilot review completed. The PR merged at `2026-09-13T16:09:02Z`; the review was submitted at `2026-09-13T16:12:10Z`.

The review identified four valid issues:

1. The Compose service references the wrong container repository.
2. The uv cache is not re-owned when `PUID`/`PGID` are changed at runtime.
3. Clearing supplementary groups prevents the unprivileged process from accessing a normally permissioned host Docker socket.
4. The documented Buildx command combines a multi-platform build with the single-image Docker exporter.

Implement these fixes in a follow-up branch and pull request based on the merged `main` branch. Keep the changes focused on the review findings.

## Implementation Review Findings

The original changes below have been implemented in the current worktree. The following findings remain outstanding and must be handled by Luna before the work is considered complete.

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

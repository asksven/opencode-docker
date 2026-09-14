# OpenCode Docker

This repository provides a Docker image for running [OpenCode](https://github.com/anomalyco/opencode).
The image is automatically built and updated via GitHub Actions whenever a new release of OpenCode is published.

This project is adapted from [pilinux/opencode-docker](https://github.com/pilinux/opencode-docker), with a
non-root entrypoint (configurable via `PUID`/`PGID`) and a leaner, feed-based release-automation workflow.

Published images are available on GitHub Container Registry at `ghcr.io/asksven/opencode-docker`,
tagged with the corresponding OpenCode version (e.g., `ghcr.io/asksven/opencode-docker:1.18.18`) and `latest`.

List of available versions can be found on the [GitHub Container Registry page](https://github.com/asksven/opencode-docker/pkgs/container/opencode-docker).

## Prerequisites

- Docker
- Docker Compose

## Usage

You can run the OpenCode server using the provided `docker-compose.yml`:

```bash
docker compose up -d
```

This will start the OpenCode web interface on `http://localhost:4096`.

## Configuration

### Environment Variables (set in .env)

- `TZ` - Timezone setting
- `OPENCODE_SERVER_USERNAME` - Server username
- `OPENCODE_SERVER_PASSWORD` - Server password

### Volumes

For persistent data and configuration, the following volumes can be mounted:

- `./data/share:/home/opencode/.local/share/opencode` - For shared data, including `auth.json` for LLM provider pre-configuration
- `./data/state:/home/opencode/.local/state/opencode`
- `./data/config:/home/opencode/.config/opencode` - For configuration files, including `opencode.json` for OpenCode pre-configuration

### Docker CLI Access

The image includes the Docker CLI, Compose v2 plugin, and Buildx plugin, but does not include a Docker daemon. To use the CLI with a host daemon, explicitly mount the host socket:

```bash
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/asksven/opencode-docker:latest \
  docker version
```

When the socket is mounted and the container uses the default root-starting entrypoint, the entrypoint grants the unprivileged process access through the socket's numeric group ID. Overriding the container user bypasses this setup and may make a `0660` socket inaccessible unless its groups are configured externally. Docker socket access is effectively root-level access to the host, so only enable this mount for trusted workloads.

### LLM Provider Authentication

To authenticate with LLM providers, you can create an `auth.json` file in the `/home/opencode/.local/share/opencode` directory with the following structure:

```json
{
  "github-copilot": {
    "type": "oauth",
    "access": "",
    "refresh": "",
    "expires": 0
  }
}
```

### LLM Provider Configuration

`opencode.json` can be used and saved to the `/home/opencode/.config/opencode` directory to pre-configure LLM providers.
For example, to whitelist specific models for the GitHub Copilot provider, you can use the following configuration:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "github-copilot/gpt-5-mini",
  "provider": {
    "github-copilot": {
      "whitelist": ["gpt-5-mini", "gpt-4.1"]
    }
  }
}
```

## Building

The Docker image is built for both `linux/amd64` and `linux/arm64` architectures.
Images are automatically pushed to GitHub Container Registry (`ghcr.io/asksven/opencode-docker`) with version tags matching OpenCode releases and a `latest` tag for the most recent release.

To build and load a local image, build one platform at a time:

```bash
docker buildx build \
  --load \
  -t opencode-docker:local \
  .
```

To publish a multi-platform image, authenticate to GitHub Container Registry, use a multi-platform-capable Buildx builder with native workers or binfmt/QEMU support, and replace `<tag>` with the desired image tag:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t ghcr.io/asksven/opencode-docker:<tag> \
  .
```

## Contributing

Feel free to open issues or submit pull requests for improvements to the Docker setup.

## License

Released under the [MIT license](LICENSE).

## Disclaimer

This repository is not affiliated with the OpenCode project. It is an independent effort to provide a Docker image for OpenCode users.
The OpenCode project is developed and maintained by the Anomaly team.
For any issues or contributions related to OpenCode itself, please refer to the [OpenCode repository](https://github.com/anomalyco/opencode).

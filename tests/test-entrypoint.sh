#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-opencode-docker:entrypoint-test}"
REQUIRE_DOCKER_SOCKET="${REQUIRE_DOCKER_SOCKET:-0}"

docker image inspect "${IMAGE}" >/dev/null

docker run --rm \
    -e PUID=12345 \
    -e PGID=12345 \
    --entrypoint /usr/local/bin/entrypoint.sh \
    "${IMAGE}" \
    sh -c '
        set -eu
        test "$(id -u)" = 12345
        test "$(id -g)" = 12345
        test "$(id -G)" = 12345
        test -w "${UV_CACHE_DIR}"
        touch "${UV_CACHE_DIR}/write-test"
        test "$1" = ""
        test "$2" = "argument with spaces"
    ' entrypoint-test '' 'argument with spaces'

if [ ! -S /var/run/docker.sock ]; then
    if [ "${REQUIRE_DOCKER_SOCKET}" = "1" ]; then
        echo "Docker socket tests require /var/run/docker.sock" >&2
        exit 1
    fi
    echo "Docker socket tests skipped: /var/run/docker.sock is not available"
    exit 0
fi

socket_gid="$(stat -c '%g' /var/run/docker.sock)"

docker run --rm \
    -e PUID=12345 \
    -e PGID="${socket_gid}" \
    -e EXPECTED_SOCKET_GID="${socket_gid}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint /usr/local/bin/entrypoint.sh \
    "${IMAGE}" \
    sh -c '
        set -eu
        test "$(id -u)" = 12345
        test "$(id -g)" = "${EXPECTED_SOCKET_GID}"
        test "$(id -G)" = "${EXPECTED_SOCKET_GID}"
        docker version >/dev/null
    '

different_pgid=12345
if [ "${different_pgid}" = "${socket_gid}" ]; then
    different_pgid=12346
fi

docker run --rm \
    -e PUID="${different_pgid}" \
    -e PGID="${different_pgid}" \
    -e EXPECTED_PRIMARY_ID="${different_pgid}" \
    -e EXPECTED_SOCKET_GID="${socket_gid}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --entrypoint /usr/local/bin/entrypoint.sh \
    "${IMAGE}" \
    sh -c '
        set -eu
        test "$(id -u)" = "${EXPECTED_PRIMARY_ID}"
        test "$(id -g)" = "${EXPECTED_PRIMARY_ID}"
        test "$(id -g)" != "${EXPECTED_SOCKET_GID}"
        case " $(id -G) " in
            *" ${EXPECTED_SOCKET_GID} "*) ;;
            *) exit 1 ;;
        esac
        docker version >/dev/null
    '

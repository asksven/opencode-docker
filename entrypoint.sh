#!/bin/sh
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

if [ "$(id -u)" = "0" ]; then
    usermod -o -u "${PUID}" opencode
    groupmod -o -g "${PGID}" opencode

    chown -R "${PUID}:${PGID}" \
        /home/opencode/.config \
        /home/opencode/.local \
        /home/opencode/.cache
    chown "${PUID}:${PGID}" /home/opencode

    export HOME=/home/opencode

    if [ -S /var/run/docker.sock ]; then
        socket_gid="$(stat -c '%g' /var/run/docker.sock)"
        if [ "${socket_gid}" != "${PGID}" ]; then
            exec setpriv --reuid "${PUID}" --regid "${PGID}" \
                --groups "${socket_gid}" "$@"
        fi
    fi

    exec setpriv --reuid "${PUID}" --regid "${PGID}" --clear-groups "$@"
fi

exec "$@"

#!/bin/sh
# Connects for real to sshd containers (test/remote/ssh_e2e_test.dart): a
# password-only one (127.0.0.1:2221), a key-only one (:2222), and a jump
# host (:2223, password) in front of one with no port of its own (`inner`,
# key); and one for a bad network (:2224, key), which may shape its own
# traffic (netem: test/remote/ssh_resilience_e2e_test.dart). Builds the
# server from the sources for them. Needs Docker.
#
#   sh tool/ssh_e2e.sh          start them, run the tests, leave them up
#   sh tool/ssh_e2e.sh --up     start them only (for another machine to
#                               run the tests: BAOCODE_SSH_E2E_BIND=0.0.0.0
#                               to listen on the network, not this one only)
#   sh tool/ssh_e2e.sh --down   remove them
set -eu
cd "$(dirname "$0")/.."
work="${BAOCODE_SSH_E2E:-${TMPDIR:-/tmp}/baocode-ssh-e2e}"
containers="bao-e2e-pw bao-e2e-key bao-e2e-bastion bao-e2e-inner bao-e2e-flaky"
bind="${BAOCODE_SSH_E2E_BIND:-127.0.0.1}"

if [ "${1:-}" = --down ]; then
  docker rm -f $containers >/dev/null 2>&1 || true
  docker network rm bao-e2e >/dev/null 2>&1 || true
  exit 0
fi

mkdir -p "$work"
[ -f "$work/testkey" ] || ssh-keygen -q -t ed25519 -N '' -f "$work/testkey" -C baocode-ssh-e2e
cat > "$work/Dockerfile" <<'DOCKER'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server iproute2 procps \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd && rm -f /etc/ssh/ssh_host_*
COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"]
DOCKER
cat > "$work/start.sh" <<'START'
#!/bin/sh
# Host keys of its own: a container made again has others.
ssh-keygen -A >/dev/null
useradd -m -s /bin/bash "$SSH_USER"
if [ -n "${SSH_PASSWORD:-}" ]; then
  echo "$SSH_USER:$SSH_PASSWORD" | chpasswd
  printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication no\nPubkeyAuthentication no\n' \
    > /etc/ssh/sshd_config.d/auth.conf
else
  home="/home/$SSH_USER"
  mkdir -p "$home/.ssh" && echo "$SSH_KEY" > "$home/.ssh/authorized_keys"
  chown -R "$SSH_USER" "$home/.ssh" && chmod 700 "$home/.ssh" && chmod 600 "$home/.ssh/authorized_keys"
  printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/auth.conf
fi
exec /usr/sbin/sshd -D -e
START
docker build -q -t baocode-ssh-e2e "$work" >/dev/null

key="$(cat "$work/testkey.pub")"
docker rm -f $containers >/dev/null 2>&1 || true
docker network create bao-e2e >/dev/null 2>&1 || true
run() { docker run -d --network bao-e2e "$@" baocode-ssh-e2e >/dev/null; }
run --name bao-e2e-pw -p $bind:2221:22 -e SSH_USER=tester -e SSH_PASSWORD=pw-secret
run --name bao-e2e-key -p $bind:2222:22 -e SSH_USER=tester -e SSH_KEY="$key"
run --name bao-e2e-bastion -p $bind:2223:22 -e SSH_USER=ops -e SSH_PASSWORD=bastion-secret
run --name bao-e2e-inner --network-alias inner -e SSH_USER=tester -e SSH_KEY="$key"
run --name bao-e2e-flaky --cap-add NET_ADMIN -p $bind:2224:22 -e SSH_USER=tester -e SSH_KEY="$key"

dart run tool/build_remote_server.dart --out "$work/remote"
[ "${1:-}" = --up ] && exit 0
BAOCODE_SSH_E2E="$work" BAOCODE_REMOTE_SERVER_DIR="$work/remote" \
  flutter test test/remote/ssh_e2e_test.dart test/remote/ssh_resilience_e2e_test.dart \
  --run-skipped -t ssh-e2e

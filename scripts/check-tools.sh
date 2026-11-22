#!/usr/bin/env bash
# Checks whether all required tools are installed and whether their versions
# match versions.env. Different versions are only a warning.
source "$(dirname "$0")/lib.sh"

missing=0
different=0

check_version() {
  local tool="$1"
  local expected="$2"
  shift 2

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  MISSING  %-10s (version %s required)\n' "$tool" "$expected"
    missing=$((missing + 1))
    return
  fi

  local output
  output="$("$@" 2>&1 || true)"
  if grep -qF "$expected" <<<"$output"; then
    printf '  OK       %-10s %s\n' "$tool" "$expected"
  else
    printf '  OTHER    %-10s expected %s, found: %s\n' "$tool" "$expected" "$(head -n 1 <<<"$output")"
    different=$((different + 1))
  fi
}

check_present() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  OK       %-10s present\n' "$tool"
  else
    printf '  MISSING  %-10s\n' "$tool"
    missing=$((missing + 1))
  fi
}

step "Tools"
check_present docker
check_present git
check_present curl
check_present openssl
check_present gh
check_version kind "$KIND_VERSION" kind version
check_version kubectl "$KUBECTL_VERSION" kubectl version --client
check_version helm "$HELM_VERSION" helm version --short
check_version oras "$ORAS_VERSION" oras version
check_version cosign "$COSIGN_VERSION" cosign version
check_version kyverno "$KYVERNO_CLI_VERSION" kyverno version
check_version jq "$JQ_VERSION" jq --version
check_version yq "$YQ_VERSION" yq --version

if [ "$missing" -gt 0 ]; then
  fail "$missing tool(s) missing. Installation hints are in the README."
fi

step "Docker"
if ! docker info >/dev/null 2>&1; then
  fail "Docker is not running. Please start Docker and try again."
fi
info "Docker is running."

# The images of the example application only exist for amd64. On machines with
# an ARM processor (e.g. Apple Silicon) they have to be emulated.
architecture="$(docker run --rm --platform linux/amd64 "$ALPINE_IMAGE" uname -m 2>/dev/null || true)"
if [ "$architecture" = "x86_64" ]; then
  info "amd64 images run (emulated if necessary)."
else
  fail "amd64 images cannot be started. On macOS enable the option 'Use Rosetta for x86_64/amd64 emulation' in Docker Desktop."
fi

# On Linux kind recommends higher inotify limits, otherwise some pods do not start.
if [ "$(uname -s)" = "Linux" ]; then
  watches="$(sysctl -n fs.inotify.max_user_watches)"
  instances="$(sysctl -n fs.inotify.max_user_instances)"
  if [ "$watches" -lt 524288 ] || [ "$instances" -lt 512 ]; then
    info "WARNING: inotify limits are low. Recommended (see README):"
    info "  sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512"
  fi
fi

step "Result"
if [ "$different" -gt 0 ]; then
  info "$different tool(s) in a different version. The testbed usually still works;"
  info "for comparable measurements please use the versions from versions.env."
else
  info "Everything ready."
fi

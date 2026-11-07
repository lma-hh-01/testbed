#!/usr/bin/env bash
# Prueft, ob alle benoetigten Werkzeuge installiert sind und ob ihre Versionen
# mit versions.env uebereinstimmen. Abweichende Versionen sind nur eine Warnung.
source "$(dirname "$0")/lib.sh"

missing=0
different=0

check_version() {
  local tool="$1"
  local expected="$2"
  shift 2

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf '  FEHLT    %-10s (benoetigt Version %s)\n' "$tool" "$expected"
    missing=$((missing + 1))
    return
  fi

  local output
  output="$("$@" 2>&1 || true)"
  if grep -qF "$expected" <<<"$output"; then
    printf '  OK       %-10s %s\n' "$tool" "$expected"
  else
    printf '  ANDERS   %-10s erwartet %s, gefunden: %s\n' "$tool" "$expected" "$(head -n 1 <<<"$output")"
    different=$((different + 1))
  fi
}

check_present() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  OK       %-10s vorhanden\n' "$tool"
  else
    printf '  FEHLT    %-10s\n' "$tool"
    missing=$((missing + 1))
  fi
}

step "Werkzeuge"
check_present docker
check_present git
check_present curl
check_present openssl
check_version kind "$KIND_VERSION" kind version
check_version kubectl "$KUBECTL_VERSION" kubectl version --client
check_version helm "$HELM_VERSION" helm version --short
check_version oras "$ORAS_VERSION" oras version
check_version cosign "$COSIGN_VERSION" cosign version
check_version kyverno "$KYVERNO_CLI_VERSION" kyverno version
check_version jq "$JQ_VERSION" jq --version
check_version yq "$YQ_VERSION" yq --version

if [ "$missing" -gt 0 ]; then
  fail "$missing Werkzeug(e) fehlen. Installationshinweise stehen in der README."
fi

step "Docker"
if ! docker info >/dev/null 2>&1; then
  fail "Docker laeuft nicht. Bitte Docker starten und erneut versuchen."
fi
info "Docker laeuft."

# Die Images der Beispielanwendung gibt es nur fuer amd64. Auf Rechnern mit
# ARM-Prozessor (z. B. Apple Silicon) muessen sie emuliert werden.
architecture="$(docker run --rm --platform linux/amd64 "$ALPINE_IMAGE" uname -m 2>/dev/null || true)"
if [ "$architecture" = "x86_64" ]; then
  info "amd64-Images laufen (gegebenenfalls emuliert)."
else
  fail "amd64-Images lassen sich nicht starten. Unter macOS in Docker Desktop die Option 'Use Rosetta for x86_64/amd64 emulation' aktivieren."
fi

# kind empfiehlt unter Linux hoehere inotify-Grenzen, sonst starten Pods teils nicht.
if [ "$(uname -s)" = "Linux" ]; then
  watches="$(sysctl -n fs.inotify.max_user_watches)"
  instances="$(sysctl -n fs.inotify.max_user_instances)"
  if [ "$watches" -lt 524288 ] || [ "$instances" -lt 512 ]; then
    info "WARNUNG: inotify-Grenzen sind niedrig. Empfohlen (siehe README):"
    info "  sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512"
  fi
fi

step "Ergebnis"
if [ "$different" -gt 0 ]; then
  info "$different Werkzeug(e) in anderer Version. Das Testbed laeuft in der Regel trotzdem;"
  info "fuer vergleichbare Messungen bitte die Versionen aus versions.env verwenden."
else
  info "Alles bereit."
fi

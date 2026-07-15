#!/usr/bin/env sh
#
# kubernetes-provisioner bootstrap installer.
#
#   curl -fsSL https://raw.githubusercontent.com/adomi-io/kubernetes-provisioner/main/install.sh | sh
#
# Grabs kubectl, helm, helmfile, and the helm-diff plugin if you don't have them,
# then downloads this repo so you can bootstrap the cluster with helmfile. Add
# helmfile arguments after the URL to run a command right away:
#
#   curl -fsSL .../install.sh | sh -s -- apply
#
# Environment:
#   DOMAIN        your domain         (e.g. example.com; prompted if unset + interactive)
#   ACME_EMAIL    Let's Encrypt email (e.g. you@example.com; prompted if unset)
#   AUTHENTIK_ADMIN_EMAIL     email for the initial Authentik admin (akadmin); optional
#   AUTHENTIK_ADMIN_PASSWORD  password for that admin; optional. Hashed locally when
#                 Python is available (else stored as-is in the in-cluster Secret) and
#                 read by Authentik on first boot only - never stored in git/OpenBao.
#   REPO          git repo            (default: adomi-io/kubernetes-provisioner)
#   REF           branch/tag/sha      (default: main)
#   INSTALL_DIR   where to checkout   (default: ./kubernetes-provisioner; when run
#                 from inside an existing checkout, that checkout is used as-is)
#   NO_RUN=1      install + checkout only, run nothing
#
# POSIX sh on purpose - runs before bash is guaranteed.
set -eu

REPO="${REPO:-adomi-io/kubernetes-provisioner}"
REF="${REF:-main}"
# Remember whether INSTALL_DIR was set explicitly before we apply the default.
INSTALL_DIR_SET="${INSTALL_DIR:+yes}"
INSTALL_DIR="${INSTALL_DIR:-./kubernetes-provisioner}"

HELM_VERSION="${HELM_VERSION:-v4.2.0}"
HELMFILE_VERSION="${HELMFILE_VERSION:-1.5.2}"

say()  { printf '\033[34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31m✗  %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
  case "$(uname -s)" in
    Linux)  echo linux ;;
    Darwin) echo darwin ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) die "unsupported OS: $(uname -s). On Windows use WSL or Git Bash." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

bindir() {
  if [ -w "/usr/local/bin" ] 2>/dev/null; then echo /usr/local/bin
  else mkdir -p "$HOME/.local/bin"; echo "$HOME/.local/bin"; fi
}

dl_stdout() { if have curl; then curl -fsSL "$1"; elif have wget; then wget -qO- "$1"; else die "need curl or wget"; fi; }
dl_file()   { if have curl; then curl -fsSL -o "$2" "$1"; elif have wget; then wget -qO "$2" "$1"; else die "need curl or wget"; fi; }

ensure_kubectl() {
  have kubectl && return 0
  dir="$BIN_DIR"; say "installing kubectl -> $dir"
  ver="$(dl_stdout https://dl.k8s.io/release/stable.txt)"
  dl_file "https://dl.k8s.io/release/${ver}/bin/${OS}/${ARCH}/kubectl" "$dir/kubectl"
  chmod +x "$dir/kubectl"
}

ensure_helm() {
  have helm && return 0
  dir="$BIN_DIR"; say "installing helm ${HELM_VERSION} -> $dir"
  dl_file "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" /tmp/helm.tgz
  tar -xzf /tmp/helm.tgz -C /tmp "${OS}-${ARCH}/helm"
  mv "/tmp/${OS}-${ARCH}/helm" "$dir/helm"; chmod +x "$dir/helm"
  rm -rf /tmp/helm.tgz "/tmp/${OS}-${ARCH}"
}

ensure_helmfile() {
  have helmfile && return 0
  dir="$BIN_DIR"; say "installing helmfile ${HELMFILE_VERSION} -> $dir"
  dl_file "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_${OS}_${ARCH}.tar.gz" /tmp/helmfile.tgz
  tar -xzf /tmp/helmfile.tgz -C /tmp helmfile
  mv /tmp/helmfile "$dir/helmfile"; chmod +x "$dir/helmfile"; rm -f /tmp/helmfile.tgz
}

ensure_diff_plugin() {
  # helmfile apply renders diffs through the helm-diff plugin.
  helm plugin list 2>/dev/null | grep -qi '^diff' && return 0
  # `helm plugin install <git url>` clones the plugin, so it needs git.
  have git || { warn "git not found - skipping helm-diff; install git, then: helm plugin install https://github.com/databus23/helm-diff --verify=false"; return 0; }
  say "installing helm-diff plugin"
  # Don't swallow the output - if it fails, the reason (network, git, etc.) is the useful bit.
  helm plugin install https://github.com/databus23/helm-diff --verify=false \
    || warn "could not install helm-diff automatically; run: helm plugin install https://github.com/databus23/helm-diff --verify=false"
}

fetch_repo() {
  dest="$1"
  if [ -d "$dest/.git" ]; then say "updating existing checkout in $dest"; ( cd "$dest" && git pull --quiet ); return; fi
  mkdir -p "$dest"
  if have git; then
    say "cloning $REPO@$REF -> $dest"
    git clone --quiet --depth 1 --branch "$REF" "https://github.com/${REPO}.git" "$dest" 2>/dev/null \
      || git clone --quiet --depth 1 "https://github.com/${REPO}.git" "$dest"
  else
    say "downloading $REPO@$REF tarball -> $dest"
    dl_file "https://github.com/${REPO}/archive/${REF}.tar.gz" "$dest/src.tgz"
    tar -xzf "$dest/src.tgz" -C "$dest" --strip-components=1; rm -f "$dest/src.tgz"
  fi
}

# Domain + Let's Encrypt email come from the end user, not from this repo. Take
# them from the environment, or ask if we have a terminal. They override
# config.yaml.gotmpl when we run helmfile.
resolve_config() {
  if [ -z "${DOMAIN:-}" ] && [ -r /dev/tty ]; then
    printf 'Domain (e.g. example.com): ' > /dev/tty; read -r DOMAIN < /dev/tty
  fi
  if [ -z "${ACME_EMAIL:-}" ] && [ -r /dev/tty ]; then
    printf "Email for Let's Encrypt: " > /dev/tty; read -r ACME_EMAIL < /dev/tty
  fi
  [ -n "${DOMAIN:-}" ]     || die "set DOMAIN (e.g. DOMAIN=example.com), or run in a terminal to be prompted"
  [ -n "${ACME_EMAIL:-}" ] || die "set ACME_EMAIL (e.g. ACME_EMAIL=you@example.com), or run in a terminal to be prompted"
  export DOMAIN ACME_EMAIL

  # Optional: pre-provision the Authentik admin so you can log in straight away,
  # without Authentik's one-time web setup. Skippable - press Enter to skip. The
  # login username is always "akadmin" (Authentik's built-in admin); we only set
  # its password + email. Provide AUTHENTIK_ADMIN_EMAIL / AUTHENTIK_ADMIN_PASSWORD
  # to skip the prompts.
  if [ -z "${AUTHENTIK_ADMIN_PASSWORD:-}" ] && [ -r /dev/tty ]; then
    if [ -z "${AUTHENTIK_ADMIN_EMAIL:-}" ]; then
      printf 'Authentik admin email (Enter to skip admin setup): ' > /dev/tty
      read -r AUTHENTIK_ADMIN_EMAIL < /dev/tty
    fi
    if [ -n "${AUTHENTIK_ADMIN_EMAIL:-}" ]; then
      printf 'Authentik admin password (login user is "akadmin"): ' > /dev/tty
      stty -echo 2>/dev/null < /dev/tty || true
      read -r AUTHENTIK_ADMIN_PASSWORD < /dev/tty
      stty echo 2>/dev/null < /dev/tty || true
      printf '\n' > /dev/tty
    fi
  fi
  AUTHENTIK_ADMIN_EMAIL="${AUTHENTIK_ADMIN_EMAIL:-}"
  AUTHENTIK_ADMIN_PASSWORD="${AUTHENTIK_ADMIN_PASSWORD:-}"
  export AUTHENTIK_ADMIN_EMAIL AUTHENTIK_ADMIN_PASSWORD
}

# Which Python to use for hashing (python3 preferred). Empty if none found.
python_bin() { have python3 && { echo python3; return 0; }; have python && { echo python; return 0; }; return 1; }

# $1 = plaintext password. Prints a Django pbkdf2_sha256 hash. The password is
# passed to Python via the environment (not argv, and not stdin - stdin is the
# script heredoc). The iteration count is encoded in the hash string, so Authentik
# verifies against it; we don't have to match its default.
django_password_hash() {
  py="$(python_bin)" || return 1
  AK_PW="$1" "$py" - <<'PY'
import os, sys, hashlib, base64, secrets, string
pw = os.environ["AK_PW"]
salt = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12))
it = 600000
dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), it)
sys.stdout.write("pbkdf2_sha256$%d$%s$%s" % (it, salt, base64.b64encode(dk).decode()))
PY
}

# If an admin password was given, drop it in a one-time Secret that Authentik reads
# on FIRST BOOT ONLY to set up akadmin. Prefer a locally-computed hash (so only the
# hash reaches the cluster); if no Python is available to hash, fall back to the
# plaintext password rather than skip - it still lands only in the in-cluster Secret,
# never in git or OpenBao. Read only once, so re-runs don't change an existing install.
bootstrap_authentik_admin() {
  [ -n "${AUTHENTIK_ADMIN_PASSWORD:-}" ] || return 0
  # On a brand-new cluster (k3s installed moments ago) the API server may not be
  # accepting requests yet. Authentik reads the bootstrap Secret on FIRST BOOT
  # ONLY, so losing this write means akadmin comes up with no password and nothing
  # ever retries - wait for the API instead of racing it.
  tries=0
  until kubectl get --raw=/readyz >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -ge 30 ] && die "Kubernetes API not reachable after 60s; cannot create the authentik-bootstrap Secret (the akadmin password would silently never apply). Check kubectl connectivity and re-run."
    [ "$tries" -eq 1 ] && say "waiting for the Kubernetes API before creating the authentik-bootstrap Secret..."
    sleep 2
  done
  kubectl create namespace authentik >/dev/null 2>&1 || true
  hash="$(django_password_hash "$AUTHENTIK_ADMIN_PASSWORD" 2>/dev/null || true)"
  if [ -n "$hash" ]; then
    set -- --from-literal=password-hash="$hash"
    method="password hash"
  else
    warn "no python3/python to hash the admin password - storing it in the in-cluster Secret as plaintext."
    set -- --from-literal=password="$AUTHENTIK_ADMIN_PASSWORD"
    method="plaintext password"
  fi
  [ -n "${AUTHENTIK_ADMIN_EMAIL:-}" ] && set -- "$@" --from-literal=email="$AUTHENTIK_ADMIN_EMAIL"
  # Keep stdout quiet but let kubectl's stderr through: a failure here must be
  # loud and abort the install - the user explicitly asked for this admin
  # password, and Authentik will never pick it up after its first boot.
  if kubectl -n authentik create secret generic authentik-bootstrap "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; then
    say "provisioned Authentik admin (akadmin) via $method (one-time secret authentik-bootstrap)"
  else
    die "couldn't create the authentik-bootstrap Secret (see error above). Fix and re-run, or set the password after install with: kubectl -n authentik exec -it deploy/authentik-server -- ak changepassword akadmin"
  fi
}

main() {
  OS="$(detect_os)"; ARCH="$(detect_arch)"
  say "kubernetes-provisioner installer ($OS/$ARCH)"

  # A .env in the current directory can hold all settings (DOMAIN, ACME_EMAIL,
  # GIT_*, BAO_*). config.yaml.gotmpl reads them as environment variables.
  [ -f .env ] && { say "loading .env"; set -a; . ./.env; set +a; }

  # Where we install tools (/usr/local/bin if writable, else ~/.local/bin). Put it
  # on PATH for this process so the tools we install below - and the final
  # `exec helmfile` - resolve even when that dir isn't on the user's PATH yet.
  BIN_DIR="$(bindir)"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) export PATH="$BIN_DIR:$PATH"; PATH_HINT="$BIN_DIR" ;;
  esac

  ensure_kubectl
  ensure_helm
  ensure_helmfile
  ensure_diff_plugin
  [ -n "${PATH_HINT:-}" ] && warn "tools installed to $PATH_HINT - add it to your PATH (e.g. in ~/.profile) to use them in new shells"

  # If we're already inside a checkout of this repo (and INSTALL_DIR wasn't set
  # explicitly), use it as-is instead of cloning a copy of the repo into itself.
  if [ -z "$INSTALL_DIR_SET" ] && [ -f helmfile.yaml.gotmpl ] && [ -d argocd ] && [ -d charts/argocd-root ]; then
    INSTALL_DIR="."
    say "running inside an existing checkout; using it as-is (not cloning)"
  else
    fetch_repo "$INSTALL_DIR"
  fi

  if [ "${NO_RUN:-0}" = "1" ] || [ "$#" -eq 0 ]; then
    say "ready. Bootstrap the cluster (set your domain + email):"
    [ "$INSTALL_DIR" = "." ] || printf '    cd %s\n' "$INSTALL_DIR"
    printf '    DOMAIN=example.com ACME_EMAIL=you@example.com helmfile apply\n'
    exit 0
  fi

  # config.yaml.gotmpl reads DOMAIN / ACME_EMAIL / GIT_* / BAO_* from the environment.
  cd "$INSTALL_DIR"
  resolve_config
  say "running: helmfile $* (domain=$DOMAIN)"
  # On a fresh cluster the Argo CD Application CRD doesn't exist yet, so helmfile
  # can't diff the root app. For `apply`, skip the diff on not-yet-installed
  # releases - Argo CD (which creates that CRD) then installs before the root app.
  case "${1:-}" in
    apply)
      # Drop the one-time Authentik admin Secret in before Argo CD brings
      # Authentik up (it's read on first boot). No-op if no password was given.
      bootstrap_authentik_admin
      exec helmfile "$@" --skip-diff-on-install ;;
    *)     exec helmfile "$@" ;;
  esac
}

main "$@"

#!/usr/bin/env bash
# ConusAI Cloud installer — https://get.conusai.com
#
# POSIX guard: this is a bash script, but `curl … | sh` runs dash on
# Debian/Ubuntu. Everything up to the `set` line below must be POSIX so we
# can hand off to bash transparently instead of dying on `pipefail`.
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash -c 'curl -fsSL https://get.conusai.com/install.sh | bash'
  fi
  echo "error: this installer requires bash. Install it (e.g. apt-get install bash) and re-run." >&2
  exit 1
fi
set -euo pipefail

platform=$(uname -ms)

if [[ ${OS:-} = Windows_NT ]]; then
  echo "Windows is not yet supported. Please use WSL2 or download the binary manually."
  exit 1
fi

# Reset
Color_Off=''

# Regular Colors
Red=''
Green=''
Dim=''
Yellow=''

# Bold
Bold_White=''
Bold_Green=''

if [[ -t 1 ]]; then
    # Reset
    Color_Off='\033[0m'

    # Regular Colors
    Red='\033[0;31m'
    Green='\033[0;32m'
    Dim='\033[0;2m'
    Yellow='\033[0;33m'

    # Bold
    Bold_Green='\033[1;32m'
    Bold_White='\033[1m'
fi

error() {
    echo -e "${Red}error${Color_Off}:" "$@" >&2
    exit 1
}

info() {
    echo -e "${Dim}$@ ${Color_Off}"
}

info_bold() {
    echo -e "${Bold_White}$@ ${Color_Off}"
}

success() {
    echo -e "${Green}$@ ${Color_Off}"
}

warning() {
    echo -e "${Yellow}warning${Color_Off}:" "$@"
}

# Verify a downloaded file against its published `.sha256` sibling asset
# (ADR-020 WS-7 / supplychain-1, supplychain-8). We fail CLOSED: if the
# checksum cannot be fetched or does not match, we refuse to install rather
# than silently running an unverified binary. An explicit, loud opt-out
# (CONUSAI_INSTALL_SKIP_CHECKSUM=1) exists for the rare case a release lacks
# the asset, so users are never hard-blocked — but the default is verified.
verify_checksum() {
    local file="$1" url_sha="$2"
    local sha_file="$file.sha256" expected actual

    if ! curl --fail --silent --location --output "$sha_file" "$url_sha" 2>/dev/null; then
        rm -f "$sha_file"
        if [[ "${CONUSAI_INSTALL_SKIP_CHECKSUM:-}" = "1" ]]; then
            warning "Checksum not found at \"$url_sha\"; skipping verification (CONUSAI_INSTALL_SKIP_CHECKSUM=1)."
            return 0
        fi
        rm -f "$file"
        error "Could not download a checksum from \"$url_sha\" to verify the binary.
Refusing to install an unverified binary. To override (NOT recommended), re-run with
CONUSAI_INSTALL_SKIP_CHECKSUM=1."
    fi

    # Accept both '<hash>' and '<hash>  filename' formats: take the first 64-hex token.
    expected=$(grep -oE '[0-9a-fA-F]{64}' "$sha_file" | head -n 1)
    rm -f "$sha_file"
    if [[ -z "$expected" ]]; then
        rm -f "$file"
        error "Checksum file from \"$url_sha\" did not contain a valid SHA-256 digest."
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        rm -f "$file"
        error "Neither 'sha256sum' nor 'shasum' is available to verify the download."
    fi

    if [[ "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" != "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" ]]; then
        rm -f "$file"
        error "Checksum verification FAILED — the download may be corrupted or tampered with.
  expected: $expected
  actual:   $actual
Aborting installation."
    fi

    success "Checksum verified (sha256)."
}

# Embedded minisign public key — the trust root for release signature
# verification (docs/dual-mode/08-release-signing.md). A same-origin attacker
# can replace both the tarball and its .sha256, so the checksum proves
# integrity but not authenticity; this signature closes that gap. The matching
# secret key exists only in the CI secret store (MINISIGN_SECRET_KEY); the
# public half is also committed at scripts/conusai-release.pub. Rotating the
# key means rotating this constant and that file together.
readonly CONUSAI_MINISIGN_PUBKEY="RWQhgxhPH4i6u72ExVdBYcOzuVwM6nenoMd1nUCdlYj0lwRb/EbttgeI"

# Verify the downloaded file against its published `.minisig` sibling asset.
# Called AFTER verify_checksum(); the checksum path above is untouched.
# Semantics (fixed):
#   - signature MISMATCH  → always fatal, whatever the flags say
#   - signature ABSENT (or minisign not installed)
#                         → fatal only under CONUSAI_INSTALL_REQUIRE_SIG=1,
#                           otherwise warn and continue, so releases published
#                           before signing keep installing
verify_signature() {
    local file="$1" url_sig="$2"

    if ! command -v minisign >/dev/null 2>&1; then
        if [[ "${CONUSAI_INSTALL_REQUIRE_SIG:-}" = "1" ]]; then
            rm -f "$file"
            error "minisign required (CONUSAI_INSTALL_REQUIRE_SIG=1) but not installed."
        fi
        warning "minisign not found — signature not verified (checksum WAS verified)."
        return 0
    fi

    if ! curl --fail --silent --location --output "$file.minisig" "$url_sig" 2>/dev/null; then
        rm -f "$file.minisig"
        if [[ "${CONUSAI_INSTALL_REQUIRE_SIG:-}" = "1" ]]; then
            rm -f "$file"
            error "No signature at \"$url_sig\" (CONUSAI_INSTALL_REQUIRE_SIG=1)."
        fi
        warning "No signature published for this release; checksum verification stands."
        return 0
    fi

    if ! minisign -Vm "$file" -P "$CONUSAI_MINISIGN_PUBKEY" >/dev/null 2>&1; then
        rm -f "$file" "$file.minisig"
        error "SIGNATURE VERIFICATION FAILED — the download may be tampered with.
Refusing to install."
    fi

    rm -f "$file.minisig"
    success "Signature verified (minisign)."
}

command -v curl >/dev/null ||
    error 'curl is required to install conusai'

# Channel selection. Mirrors `conusai upgrade --channel`:
#   stable (default) — track non-prerelease tags only
#   beta             — track the newest tag, prerelease or not, EXCLUDING
#                       nightly builds (a `-nightly.` tag never satisfies beta)
#   nightly          — track only automated nightly builds (`-nightly.` tags),
#                       cut once a day from `main` when it has new commits
#
# CLI-only by design: there is no env-var fallback. A user must pass
# `--channel beta` or `--channel nightly` explicitly to opt into prereleases.
# `bash install.sh` always lands on stable — same contract as `conusai upgrade`.
channel="stable"
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel=*)
            channel="${1#--channel=}"
            shift
            ;;
        --channel)
            shift
            [[ $# -gt 0 ]] || error '--channel requires a value, e.g. --channel beta'
            channel="$1"
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

case "$channel" in
    stable|beta|nightly) ;;
    *)
        error "Unknown channel '$channel'. Supported: stable, beta, nightly"
        ;;
esac

if [[ ${#positional[@]} -gt 1 ]]; then
    error 'Too many arguments. Usage: install.sh [--channel beta|stable] [version]'
fi

case $platform in
'Darwin x86_64')
    target=darwin-amd64
    ;;
'Darwin arm64')
    target=darwin-arm64
    ;;
'Linux aarch64' | 'Linux arm64')
    target=linux-arm64
    ;;
'Linux x86_64' | *)
    target=linux-amd64
    ;;
esac

# Best-effort: make signature verification possible. Non-interactive only —
# never prompt for a sudo password before the wizard section owns the TTY.
if ! command -v minisign >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    if [[ $(id -u) -eq 0 ]]; then
        apt-get install -y -qq minisign >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n apt-get install -y -qq minisign >/dev/null 2>&1 || true
    fi
fi

GITHUB=${GITHUB-"https://github.com"}

github_repo="$GITHUB/conusai/get"

exe_name=conusai

if [[ ${#positional[@]} -eq 0 ]]; then
    info "Fetching latest release on channel: $channel"

    # Channel resolution against GitHub Releases:
    #
    # - stable: GET /releases/latest returns the most recent NON-prerelease
    #   release. This is GitHub's contract — it's exactly what we want.
    #   404 means there are zero stable releases yet; fall through to a
    #   helpful error.
    # - beta: /releases/latest skips betas, so we walk the first page of
    #   /releases (newest-first) and take the first `tag_name` that is NOT a
    #   nightly build (mirrors `conusai upgrade`'s `UpgradeChannel::Beta`,
    #   which excludes `-nightly.` tags so a deliberate beta opt-in never
    #   silently resolves to an automated nightly).
    # - nightly: same page, but take the first `tag_name` that IS a nightly
    #   build (contains `-nightly.`), minted by the "Nightly Release" workflow.
    #
    # Why "first tag_name" (no draft check):
    #   We don't ship draft releases publicly — anything visible on the
    #   API is intended to be installable. Filtering drafts inside a
    #   shell script is brittle (tag_name and draft fields aren't in a
    #   guaranteed order across responses; awk pairing them requires a
    #   real JSON parser). The Rust CLI does check `draft` because it has
    #   serde; the bash installer trusts that the API only returns
    #   shipped releases.
    set +e
    if [[ "$channel" = "stable" ]]; then
        conusai_tag=$(curl --silent "https://api.github.com/repos/conusai/get/releases/latest" |
                    grep '"tag_name":' |
                    head -n 1 |
                    sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null)
    elif [[ "$channel" = "nightly" ]]; then
        # GitHub orders releases newest-first; take the first tag_name that
        # contains the `-nightly.` marker.
        conusai_tag=$(curl --silent "https://api.github.com/repos/conusai/get/releases?per_page=20" |
                    grep -oE '"tag_name": *"[^"]*-nightly\.[^"]*"' |
                    head -n 1 |
                    sed -E 's/.*"([^"]+)"$/\1/' 2>/dev/null)
    else
        # beta: GitHub orders releases newest-first; take the first
        # tag_name that is NOT a nightly build.
        conusai_tag=$(curl --silent "https://api.github.com/repos/conusai/get/releases?per_page=20" |
                    grep '"tag_name":' |
                    grep -v -- '-nightly\.' |
                    head -n 1 |
                    sed -E 's/.*"([^"]+)".*/\1/' 2>/dev/null)
    fi
    set -e

    if [[ -z "$conusai_tag" ]]; then
        echo ""
        error "No releases found on channel '$channel'. Try a specific version:
    curl -fsSL https://raw.githubusercontent.com/conusai/get/main/scripts/install.sh | bash -s -- v0.1.0

Or pick a different channel:
    curl -fsSL https://raw.githubusercontent.com/conusai/get/main/scripts/install.sh | bash -s -- --channel beta

Available versions: https://github.com/conusai/get/releases"
    fi

    info "Latest version on $channel: $conusai_tag"
    conusai_uri=$github_repo/releases/download/$conusai_tag/conusai-$target.tar.gz
else
    # Explicit version pin — channel is irrelevant.
    conusai_uri=$github_repo/releases/download/${positional[0]}/conusai-$target.tar.gz
fi

install_env=CONUSAI_INSTALL
bin_env=\$$install_env/bin

install_dir=${!install_env:-$HOME/.conusai}
bin_dir=$install_dir/bin
exe=$bin_dir/conusai

if [[ ! -d $bin_dir ]]; then
    mkdir -p "$bin_dir" ||
        error "Failed to create install directory \"$bin_dir\""
fi

info "Downloading conusai from $conusai_uri..."

tarball="$install_dir/conusai-$target.tar.gz"

curl --fail --location --progress-bar --output "$tarball" "$conusai_uri" ||
    error "Failed to download conusai from \"$conusai_uri\""

info "Verifying download integrity..."

verify_checksum "$tarball" "$conusai_uri.sha256"

verify_signature "$tarball" "$conusai_uri.minisig"

info "Extracting conusai..."

tar -xzf "$tarball" -C "$bin_dir" ||
    error "Failed to extract conusai"

rm "$tarball" ||
    warning "Failed to remove temporary tarball"

chmod +x "$exe" ||
    error 'Failed to set permissions on conusai executable'

tildify() {
    if [[ $1 = $HOME/* ]]; then
        local replacement=\~/

        echo "${1/$HOME\//$replacement}"
    else
        echo "$1"
    fi
}

success "conusai was installed successfully to $Bold_Green$(tildify "$exe")"

# Root installs (fresh VPS, remote anchor bootstrap) also get the binary on a
# standard PATH — non-interactive SSH never sources ~/.bashrc, so ~/.conusai/bin
# alone leaves later `ssh host conusai …` phases with exit 127.
if [[ $(id -u) -eq 0 ]]; then
    install -m 755 "$exe" /usr/local/bin/conusai
    info "Also installed to /usr/local/bin/conusai (system PATH)."
fi

already_on_path=false
if command -v conusai >/dev/null; then
    # A previous install already put conusai on PATH — skip the shell-config
    # section, but keep going: provisioning and setup below must still run.
    already_on_path=true
fi

refresh_command=''

tilde_bin_dir=$(tildify "$bin_dir")
quoted_install_dir=\"${install_dir//\"/\\\"}\"

if [[ $quoted_install_dir = \"$HOME/* ]]; then
    quoted_install_dir=${quoted_install_dir/$HOME\//\$HOME/}
fi

echo

if [[ $already_on_path = true ]]; then :; else
case $(basename "$SHELL") in
fish)
    commands=(
        "set --export $install_env $quoted_install_dir"
        "set --export PATH $bin_env \$PATH"
    )

    fish_config=$HOME/.config/fish/config.fish
    tilde_fish_config=$(tildify "$fish_config")

    if [[ -w $fish_config ]]; then
        {
            echo -e '\n# conusai'

            for command in "${commands[@]}"; do
                echo "$command"
            done
        } >>"$fish_config"

        info "Added \"$tilde_bin_dir\" to \$PATH in \"$tilde_fish_config\""

        refresh_command="source $tilde_fish_config"
    else
        echo "Manually add the directory to $tilde_fish_config (or similar):"

        for command in "${commands[@]}"; do
            info_bold "  $command"
        done
    fi
    ;;
zsh)
    commands=(
        "export $install_env=$quoted_install_dir"
        "export PATH=\"$bin_env:\$PATH\""
    )

    zsh_config=$HOME/.zshrc
    tilde_zsh_config=$(tildify "$zsh_config")

    if [[ -w $zsh_config ]]; then
        {
            echo -e '\n# conusai'

            for command in "${commands[@]}"; do
                echo "$command"
            done
        } >>"$zsh_config"

        info "Added \"$tilde_bin_dir\" to \$PATH in \"$tilde_zsh_config\""

        refresh_command="exec $SHELL"
    else
        echo "Manually add the directory to $tilde_zsh_config (or similar):"

        for command in "${commands[@]}"; do
            info_bold "  $command"
        done
    fi
    ;;
bash)
    commands=(
        "export $install_env=$quoted_install_dir"
        "export PATH=\"$bin_env:\$PATH\""
    )

    bash_configs=(
        "$HOME/.bash_profile"
        "$HOME/.bashrc"
    )

    if [[ ${XDG_CONFIG_HOME:-} ]]; then
        bash_configs+=(
            "$XDG_CONFIG_HOME/.bash_profile"
            "$XDG_CONFIG_HOME/.bashrc"
            "$XDG_CONFIG_HOME/bash_profile"
            "$XDG_CONFIG_HOME/bashrc"
        )
    fi

    set_manually=true
    for bash_config in "${bash_configs[@]}"; do
        tilde_bash_config=$(tildify "$bash_config")

        if [[ -w $bash_config ]]; then
            {
                echo -e '\n# conusai'

                for command in "${commands[@]}"; do
                    echo "$command"
                done
            } >>"$bash_config"

            info "Added \"$tilde_bin_dir\" to \$PATH in \"$tilde_bash_config\""

            refresh_command="source $bash_config"
            set_manually=false
            break
        fi
    done

    if [[ $set_manually = true ]]; then
        echo "Manually add the directory to $tilde_bash_config (or similar):"

        for command in "${commands[@]}"; do
            info_bold "  $command"
        done
    fi
    ;;
*)
    echo 'Manually add the directory to ~/.bashrc (or similar):'
    info_bold "  export $install_env=$quoted_install_dir"
    info_bold "  export PATH=\"$bin_env:\$PATH\""
    ;;
esac
fi

echo
info "To get started, run:"
echo

if [[ $refresh_command ]]; then
    info_bold "  $refresh_command"
fi

info_bold "  conusai --help"

# ── Hand off to the interactive wizard (rustup pattern) ──────────────
# stdin is the curl pipe → prompts must read the controlling TTY.
# No TTY (CI/containers): NEVER hang — print the recipe and exit 0.

SUDO=""
[[ $(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# Mode B pairing creates a WireGuard interface locally, and the server binds
# :80/:443 — both privileged operations. File capabilities grant exactly those
# two to the binary, so setup and the service run as a regular user (no
# setuid, no running everything as root). Must be re-applied after every copy:
# `install` writes a new inode, which drops file capabilities.
grant_net_caps() {
    local target=$1
    [[ $(id -u) -eq 0 ]] && return 0
    if ! command -v setcap >/dev/null 2>&1 && [[ -n $SUDO ]] && command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get install -y -qq libcap2-bin >/dev/null 2>&1 || true
    fi
    if command -v setcap >/dev/null 2>&1 && [[ -n $SUDO ]]; then
        $SUDO setcap 'cap_net_admin,cap_net_bind_service+ep' "$target" 2>/dev/null ||
            warning "Could not grant network capabilities to $target — Mode B setup will need root:  sudo -E conusai setup --interactive"
    else
        warning "setcap is unavailable — Mode B setup will need root:  sudo -E conusai setup --interactive"
    fi
}

# ── Preflight (warn, never block — the operator knows their machine) ──
preflight() {
    local mem_kb disk_kb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ $mem_kb -gt 0 && $mem_kb -lt 1900000 ]]; then
        warning "Less than 2 GB RAM detected — ConusAI runs, but builds may struggle. 4 GB recommended."
    fi
    disk_kb=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n ${disk_kb:-} && $disk_kb -lt 10485760 ]]; then
        warning "Less than 10 GB free on / — container images and builds need room."
    fi
    for p in 80 443; do
        if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":$p "; then
            warning "Port $p is already in use — another web server? ConusAI's proxy wants 80/443."
        fi
    done
}

docker_cmd=""
resolve_docker() {
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then docker_cmd="docker"; return 0; fi
        if [[ -n $SUDO ]] && $SUDO docker info >/dev/null 2>&1 </dev/tty; then
            docker_cmd="$SUDO docker"; return 0
        fi
        if [[ $(id -u) -eq 0 ]] && docker info >/dev/null 2>&1; then docker_cmd="docker"; return 0; fi
    fi
    return 1
}

ensure_docker() {
    resolve_docker && { success "Docker is ready."; return 0; }
    if ! command -v docker >/dev/null 2>&1; then
        info "Docker not found — installing it (get.docker.com)…"
        if [[ $(id -u) -eq 0 ]]; then
            curl -fsSL https://get.docker.com | sh
        elif [[ -n $SUDO ]]; then
            curl -fsSL https://get.docker.com | $SUDO sh </dev/tty
        else
            error "Docker is required and cannot be installed automatically (no root, no sudo).
Install it, then re-run:  curl -sSL https://get.conusai.com/install.sh | bash"
        fi
    fi
    # Make the docker group effective for future logins/services even though
    # this shell predates it; the service (below) picks it up at start.
    if [[ $(id -u) -ne 0 && -n $SUDO ]]; then
        $SUDO usermod -aG docker "$USER" 2>/dev/null || true
    fi
    resolve_docker || error "Docker is installed but not reachable. Check:  ${SUDO:+$SUDO }docker info"
    success "Docker is ready."
}

provision_postgres() {
    [[ -n "${CONUSAI_DATABASE_URL:-}" ]] && return 0
    local PG_CONTAINER=conusai-postgres PG_IMAGE=timescale/timescaledb-ha:pg18 PG_PORT=5433
    local conf_dir="$HOME/.conusai" PG_PASSWORD
    mkdir -p "$conf_dir"; chmod 700 "$conf_dir"
    if [[ -f "$conf_dir/pg.pass" ]]; then
        PG_PASSWORD=$(cat "$conf_dir/pg.pass")
    else
        PG_PASSWORD=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
        (umask 077; printf '%s' "$PG_PASSWORD" > "$conf_dir/pg.pass")
    fi
    if $docker_cmd ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        info "PostgreSQL container '$PG_CONTAINER' already running."
    elif $docker_cmd ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
        info "Starting existing PostgreSQL container…"
        $docker_cmd start "$PG_CONTAINER" >/dev/null
    else
        info "Provisioning PostgreSQL (TimescaleDB) container…"
        $docker_cmd run -d --name "$PG_CONTAINER" --restart unless-stopped \
            -e POSTGRES_USER=conusai -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_DB=conusai \
            -p "127.0.0.1:${PG_PORT}:5432" \
            -v conusai-pg-data:/home/postgres/pgdata/data \
            "$PG_IMAGE" >/dev/null
    fi
    # Readiness must mean what the app needs: TCP + password auth + the target
    # database answering a real query — and STABLE. timescaledb-ha restarts
    # postgres during first-boot init, so a single socket-level pg_isready can
    # succeed inside the restart window ("0 bytes at EOF" for the next client).
    # Require 3 consecutive TCP-authenticated queries, 2s apart.
    info "Waiting for PostgreSQL to become ready…"
    local ok_streak=0 tries=0
    while [[ $ok_streak -lt 3 ]]; do
        if $docker_cmd exec -e PGPASSWORD="$PG_PASSWORD" "$PG_CONTAINER" \
             psql -h 127.0.0.1 -p 5432 -U conusai -d conusai -tAc 'SELECT 1' >/dev/null 2>&1; then
            ok_streak=$((ok_streak+1))
        else
            ok_streak=0
        fi
        tries=$((tries+1))
        [[ $tries -gt 120 ]] && error "PostgreSQL did not become ready in time. Check: $docker_cmd logs $PG_CONTAINER"
        sleep 2
    done
    success "PostgreSQL is ready (verified over TCP, 3× stable)."
    # The container's POSTGRES_USER is a superuser, and PostgreSQL exempts
    # superusers from row-level security unconditionally — connecting the app
    # as that role would make tenant isolation inert (the server refuses to
    # stay quiet about it). So the app connects as 'conusai_app': LOGIN,
    # NOSUPERUSER, NOBYPASSRLS, owner of everything in the database. The
    # extensions the migrations expect are created here once, with superuser.
    info "Configuring least-privilege application role…"
    if ! printf '%s\n' \
        "SET client_min_messages = error;" \
        "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'conusai_app') THEN CREATE ROLE conusai_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE; END IF; END \$\$;" \
        "ALTER ROLE conusai_app PASSWORD '${PG_PASSWORD}';" \
        "CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA public;" \
        "CREATE EXTENSION IF NOT EXISTS timescaledb_toolkit WITH SCHEMA public;" \
        "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;" \
        "ALTER DATABASE conusai OWNER TO conusai_app;" \
        | $docker_cmd exec -i -e PGPASSWORD="$PG_PASSWORD" "$PG_CONTAINER" \
            psql -h 127.0.0.1 -p 5432 -U conusai -d conusai -q -v ON_ERROR_STOP=1 >/dev/null; then
        error "Failed to configure the application database role. Check: $docker_cmd logs $PG_CONTAINER"
    fi
    export CONUSAI_DATABASE_URL="postgresql://conusai_app:${PG_PASSWORD}@localhost:${PG_PORT}/conusai?sslmode=disable"
    (umask 077; printf 'CONUSAI_DATABASE_URL=%s\n' "$CONUSAI_DATABASE_URL" > "$conf_dir/conusai.env")
    info "Database URL saved to ~/.conusai/conusai.env"
}

install_service() {
    # Make ConusAI a real server: start on boot, restart on failure, survive
    # logout. Skips gracefully when systemd is absent (containers, WSL1).
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        info "systemd not detected — start the server manually:"
        info_bold "  set -a; source ~/.conusai/conusai.env; set +a; conusai serve"
        return 0
    fi
    if [[ $(id -u) -ne 0 && -z $SUDO ]]; then
        info "No root/sudo — start the server manually:"
        info_bold "  set -a; source ~/.conusai/conusai.env; set +a; conusai serve"
        return 0
    fi
    info "Installing systemd service…"
    $SUDO install -m 755 "$exe" /usr/local/bin/conusai
    grant_net_caps /usr/local/bin/conusai
    local svc_user; svc_user=$(id -un)
    local env_file="$HOME/.conusai/conusai.env"
    # Pin the listeners once, in the env file the unit reads (0600 already).
    grep -q '^CONUSAI_ADDRESS='          "$env_file" 2>/dev/null || echo "CONUSAI_ADDRESS=0.0.0.0:80"          >> "$env_file"
    grep -q '^CONUSAI_TLS_ADDRESS='      "$env_file" 2>/dev/null || echo "CONUSAI_TLS_ADDRESS=0.0.0.0:443"      >> "$env_file"
    grep -q '^CONUSAI_CONSOLE_ADDRESS='  "$env_file" 2>/dev/null || echo "CONUSAI_CONSOLE_ADDRESS=127.0.0.1:8081" >> "$env_file"
    grep -q '^CONUSAI_DATA_DIR='         "$env_file" 2>/dev/null || echo "CONUSAI_DATA_DIR=$HOME/.conusai"        >> "$env_file"
    $SUDO tee /etc/systemd/system/conusai.service >/dev/null <<UNIT
[Unit]
Description=ConusAI Cloud application server
Documentation=https://get.conusai.com
After=network-online.target docker.service
Wants=network-online.target docker.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=exec
User=$svc_user
SupplementaryGroups=docker
EnvironmentFile=$env_file
# Relative paths (GeoLite2-City.mmdb, runtime scratch) resolve against the
# data dir, not /.
WorkingDirectory=$HOME/.conusai
# Wait until the database container actually answers — After=docker.service
# only proves the daemon started, and migrations fail hard on a cold DB.
ExecStartPre=/usr/bin/timeout 120 /bin/sh -c 'until docker exec conusai-postgres pg_isready -U conusai -q; do sleep 2; done'
ExecStart=/usr/local/bin/conusai serve
# Binding :80/:443 and managing the Mode B WireGuard tunnel as a non-root
# user. (The binary carries matching file capabilities; ambient is the
# belt-and-braces for a binary replaced without setcap.)
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
# The binary's graceful shutdown listens for SIGINT (not SIGTERM).
KillSignal=SIGINT
KillMode=mixed
TimeoutStopSec=45
TimeoutStartSec=300
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=conusai
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    $SUDO systemctl daemon-reload
    if systemctl is-active --quiet conusai; then
        # Upgrade path: the unit is already running the previous binary;
        # `enable --now` would leave it untouched.
        info "Restarting the running service on the new binary…"
        $SUDO systemctl restart conusai
    else
        $SUDO systemctl enable --now conusai
    fi
    info "Waiting for the server to come up…"
    local i
    for i in $(seq 1 45); do
        if systemctl is-active --quiet conusai; then
            success "ConusAI is running (systemd service 'conusai')."
            local ip; ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
            echo
            info_bold "  Dashboard:  http://${ip:-<server-ip>}/"
            info_bold "  Logs:       journalctl -u conusai -f"
            info_bold "  Manage:     systemctl status|restart|stop conusai"
            return 0
        fi
        sleep 2
    done
    warning "Service installed but not active yet — inspect:  journalctl -u conusai -e"
}

if [[ "${CONUSAI_INSTALL_NO_WIZARD:-}" != "1" ]] && [[ -e /dev/tty ]] \
   && ( : </dev/tty ) 2>/dev/null; then
    echo
    preflight
    ensure_docker
    provision_postgres
    grant_net_caps "$exe"
    info "Launching interactive setup…"
    if "$exe" setup --interactive </dev/tty; then
        install_service
    else
        error "Setup did not complete. Re-run it any time:
  set -a; source ~/.conusai/conusai.env; set +a; conusai setup --interactive"
    fi
else
    echo
    info "No TTY available — skipping interactive setup."
    info_bold "  Run later:   conusai setup --interactive"
    info_bold "  Or headless: conusai setup --help   (env-driven --auto flags)"
    info_bold "  Optional outbound email (headless): CONUSAI_SMTP_PRESET=gmail|ses|scaleway|custom"
    info_bold "      CONUSAI_SMTP_HOST CONUSAI_SMTP_PORT CONUSAI_SMTP_USERNAME CONUSAI_SMTP_PASSWORD"
    info_bold "      CONUSAI_SMTP_ENCRYPTION=starttls|tls|none CONUSAI_SMTP_FROM_ADDRESS CONUSAI_SMTP_SES_REGION"
fi

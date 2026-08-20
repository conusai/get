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

if command -v conusai >/dev/null; then
    echo "Run 'conusai --help' to get started"
    exit
fi

refresh_command=''

tilde_bin_dir=$(tildify "$bin_dir")
quoted_install_dir=\"${install_dir//\"/\\\"}\"

if [[ $quoted_install_dir = \"$HOME/* ]]; then
    quoted_install_dir=${quoted_install_dir/$HOME\//\$HOME/}
fi

echo

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
if [[ "${CONUSAI_INSTALL_NO_WIZARD:-}" != "1" ]] && [[ -e /dev/tty ]] \
   && ( : </dev/tty ) 2>/dev/null; then
    echo
    # ── Auto-provision PostgreSQL when none is configured ────────────
    # `conusai setup` requires a database. Fresh servers have none, so we
    # start a local TimescaleDB container (same image the platform uses),
    # bound to loopback only, with a generated password persisted 0600.
    if [[ -z "${CONUSAI_DATABASE_URL:-}" ]]; then
        if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
            info "Docker is required to auto-provision PostgreSQL (and to run apps)."
            info_bold "  1) curl -fsSL https://get.docker.com | sh"
            info_bold "  2) re-run:  curl -sSL https://get.conusai.com/install.sh | bash"
            info "Or point at an existing database:  CONUSAI_DATABASE_URL=postgresql://… conusai setup --interactive"
            exit 0
        fi
        PG_CONTAINER=conusai-postgres
        PG_IMAGE=timescale/timescaledb-ha:pg18
        PG_PORT=5433
        conf_dir="$HOME/.conusai"; mkdir -p "$conf_dir"; chmod 700 "$conf_dir"
        if [[ -f "$conf_dir/pg.pass" ]]; then
            PG_PASSWORD=$(cat "$conf_dir/pg.pass")
        else
            PG_PASSWORD=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
            (umask 077; printf '%s' "$PG_PASSWORD" > "$conf_dir/pg.pass")
        fi
        if docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
            info "PostgreSQL container '$PG_CONTAINER' already running."
        elif docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
            info "Starting existing PostgreSQL container…"
            docker start "$PG_CONTAINER" >/dev/null
        else
            info "Provisioning PostgreSQL (TimescaleDB) container…"
            docker run -d --name "$PG_CONTAINER" --restart unless-stopped \
                -e POSTGRES_USER=conusai -e POSTGRES_PASSWORD="$PG_PASSWORD" -e POSTGRES_DB=conusai \
                -p "127.0.0.1:${PG_PORT}:5432" \
                -v conusai-pg-data:/home/postgres/pgdata/data \
                "$PG_IMAGE" >/dev/null
        fi
        info "Waiting for PostgreSQL to become ready…"
        pg_ok=false
        for _ in $(seq 1 90); do
            if docker exec "$PG_CONTAINER" pg_isready -U conusai -d conusai >/dev/null 2>&1; then pg_ok=true; break; fi
            sleep 2
        done
        [[ $pg_ok = true ]] || error "PostgreSQL did not become ready in time. Check: docker logs $PG_CONTAINER"
        success "PostgreSQL is ready."
        export CONUSAI_DATABASE_URL="postgresql://conusai:${PG_PASSWORD}@localhost:${PG_PORT}/conusai?sslmode=disable"
        (umask 077; printf 'CONUSAI_DATABASE_URL=%s\n' "$CONUSAI_DATABASE_URL" > "$conf_dir/conusai.env")
        info "Database URL saved to ~/.conusai/conusai.env"
    fi
    info "Launching interactive setup…"
    exec "$exe" setup --interactive </dev/tty
else
    echo
    info "No TTY available — skipping interactive setup."
    info_bold "  Run later:   conusai setup --interactive"
    info_bold "  Or headless: conusai setup --help   (env-driven --auto flags)"
fi

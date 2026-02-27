#!/bin/bash
# =============================================================================
# install.sh — Rootless Automated Deployment of SCIP + MiniZinc + FiberSCIP
# =============================================================================
# Target:  Restricted Linux environments (no sudo, no system writes)
# Base:    $HOME/.local  (XDG-compliant user prefix)
# Deps:    Micromamba → conda-forge packages for build toolchain
# Result:  fscip + minizinc in PATH, 'minizinc --solvers' lists org.scip.fscip
# =============================================================================
set -euo pipefail

# =============================================================================
# Phase 0 — Constants & Directory Layout
# =============================================================================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Use a local directory inside the repo to avoid permission issues in $HOME
LOCAL_PREFIX="${REPO_ROOT}/.local"
MAMBA_ROOT="$LOCAL_PREFIX/micromamba"
MAMBA_BIN="$MAMBA_ROOT/bin/micromamba"
MAMBA_ENV_NAME="scip-build"

SCIP_VERSION="10.0.0"
SCIP_TARBALL="scipoptsuite-${SCIP_VERSION}.tgz"
SCIP_URL="https://www.scipopt.org/download/release/${SCIP_TARBALL}"
SCIP_SRC_DIR="/tmp/scipoptsuite-${SCIP_VERSION}"

MZN_VERSION="2.9.4"
MZN_TARBALL="MiniZincIDE-${MZN_VERSION}-bundle-linux-x86_64.tgz"
MZN_URL="https://github.com/MiniZinc/MiniZincIDE/releases/download/${MZN_VERSION}/${MZN_TARBALL}"
MZN_INSTALL_DIR="$LOCAL_PREFIX/minizinc"

BASHRC_MARKER_START="# >>> fscip-env >>>"
BASHRC_MARKER_END="# <<< fscip-env <<<"

# Colors for status messages (fallback to plain if no tty)
if [ -t 1 ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; NC=''
fi

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
phase() { echo ""; echo -e "${GREEN}========== $* ==========${NC}"; }

# Create directory skeleton
mkdir -p "$LOCAL_PREFIX"/{bin,lib,include,share}

# Ensure MiniZinc user config path is accessible
MZN_USER_CONFIG_DIR="$HOME/.minizinc/solvers"
if [ ! -w "$HOME/.minizinc" ] && [ ! -w "$HOME" ]; then
    # Fallback if HOME is not writable: configure locally 
    # (MiniZinc env var MZN_SOLVER_PATH will handle this)
    MZN_USER_CONFIG_DIR="$LOCAL_PREFIX/minizinc_config"
fi
mkdir -p "$MZN_USER_CONFIG_DIR"

# =============================================================================
# Phase 1 — Install Micromamba (user-space package manager)
# =============================================================================
phase "Phase 1/7 — Micromamba"

if [ -x "$MAMBA_BIN" ]; then
    info "Micromamba already installed at $MAMBA_BIN — skipping."
else
    info "Downloading Micromamba..."
    mkdir -p "$MAMBA_ROOT/bin"
    curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest \
        | tar -xvj -C "$MAMBA_ROOT/bin" --strip-components=1 bin/micromamba
    chmod +x "$MAMBA_BIN"
    info "Micromamba installed at $MAMBA_BIN"
fi

export MAMBA_ROOT_PREFIX="$MAMBA_ROOT"

# =============================================================================
# Phase 2 — Create conda environment with build dependencies
# =============================================================================
phase "Phase 2/7 — Build Dependencies (conda-forge)"

if "$MAMBA_BIN" env list 2>/dev/null | grep -q "$MAMBA_ENV_NAME"; then
    info "Environment '$MAMBA_ENV_NAME' already exists — skipping creation."
else
    info "Creating micromamba environment with build toolchain..."
    "$MAMBA_BIN" create -n "$MAMBA_ENV_NAME" -y -c conda-forge \
        cmake \
        make \
        gmp \
        mpfr \
        boost-cpp \
        tbb \
        tbb-devel \
        zlib \
        readline \
        bison \
        flex
    info "Environment '$MAMBA_ENV_NAME' created."
fi

# Resolve the environment prefix path
MAMBA_ENV_PREFIX="$("$MAMBA_BIN" env list --json 2>/dev/null \
    | python3 -c "import sys,json; envs=json.load(sys.stdin)['envs']; print([e for e in envs if '$MAMBA_ENV_NAME' in e][0])" 2>/dev/null)" \
    || MAMBA_ENV_PREFIX="$MAMBA_ROOT/envs/$MAMBA_ENV_NAME"

info "Environment prefix: $MAMBA_ENV_PREFIX"

# Activate environment paths for this script (without eval "$(micromamba shell hook)")
export PATH="$MAMBA_ENV_PREFIX/bin:$LOCAL_PREFIX/bin:$PATH"
export CMAKE_PREFIX_PATH="$MAMBA_ENV_PREFIX"
export LD_LIBRARY_PATH="$MAMBA_ENV_PREFIX/lib:$LOCAL_PREFIX/lib:${LD_LIBRARY_PATH:-}"

# Fix for "Could not find compiler set in environment variable CC: x86_64-conda-linux-gnu-cc"
# Conda packages often set CC/CXX to cross-compilers that we didn't install.
# We want to use the system compiler (/usr/bin/gcc).
unset CC CXX
export CC="$(command -v gcc)"
export CXX="$(command -v g++)"

# =============================================================================
# Phase 3 — Download & Compile SCIP Optimization Suite
# =============================================================================
phase "Phase 3/7 — SCIP Optimization Suite ${SCIP_VERSION}"

if [ -x "$LOCAL_PREFIX/bin/fscip" ]; then
    info "fscip binary already exists at $LOCAL_PREFIX/bin/fscip — skipping build."
else
    # --- Download ---
    if [ -f "/tmp/${SCIP_TARBALL}" ]; then
        info "Tarball already in /tmp — skipping download."
    else
        info "Downloading SCIP ${SCIP_VERSION} (~300 MB)..."
        wget -q --show-progress -O "/tmp/${SCIP_TARBALL}" "$SCIP_URL" \
            || curl -fSL -o "/tmp/${SCIP_TARBALL}" "$SCIP_URL" \
            || fail "Could not download SCIP tarball. Check network access."
    fi

    # --- Extract ---
    info "Extracting..."
    rm -rf "$SCIP_SRC_DIR"
    tar -xf "/tmp/${SCIP_TARBALL}" -C /tmp

    [ -d "$SCIP_SRC_DIR" ] || fail "Expected directory $SCIP_SRC_DIR not found after extraction."

    # --- Configure ---
    info "Configuring CMake (this detects deps from micromamba env)..."
    mkdir -p "$SCIP_SRC_DIR/build"
    cd "$SCIP_SRC_DIR/build"

    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DAUTOBUILD=on \
        -DTPI=tny \
        -DSYM=snauty \
        -DLPS=spx \
        -DEXACTSOLVE=on \
        -DGCG=off \
        -DCMAKE_INSTALL_PREFIX="$LOCAL_PREFIX" \
        -DCMAKE_PREFIX_PATH="$MAMBA_ENV_PREFIX" \
        || fail "CMake configuration failed."

    # --- Build ---
    NPROC=$(nproc 2>/dev/null || echo 2)
    info "Building with $NPROC parallel jobs (this takes 20-40 min)..."
    make -j"$NPROC" || fail "SCIP build failed."

    # --- Install ---
    info "Installing to $LOCAL_PREFIX..."
    make install || fail "SCIP install failed."

    # --- Locate and install fscip binary ---
    FSCIP_FOUND=""
    for candidate in \
        "$SCIP_SRC_DIR/build/bin/fscip" \
        "$SCIP_SRC_DIR/build/ug/bin/fscip" \
        "$LOCAL_PREFIX/bin/fscip"; do
        if [ -f "$candidate" ]; then
            FSCIP_FOUND="$candidate"
            break
        fi
    done

    if [ -z "$FSCIP_FOUND" ]; then
        warn "fscip binary not found in expected locations. Searching build tree..."
        FSCIP_FOUND="$(find "$SCIP_SRC_DIR/build" -name fscip -type f -executable 2>/dev/null | head -1)"
    fi

    if [ -n "$FSCIP_FOUND" ] && [ "$FSCIP_FOUND" != "$LOCAL_PREFIX/bin/fscip" ]; then
        cp "$FSCIP_FOUND" "$LOCAL_PREFIX/bin/fscip"
        chmod +x "$LOCAL_PREFIX/bin/fscip"
        info "fscip binary installed to $LOCAL_PREFIX/bin/fscip"
    elif [ -x "$LOCAL_PREFIX/bin/fscip" ]; then
        info "fscip already in $LOCAL_PREFIX/bin/ via make install."
    else
        fail "Could not locate fscip binary anywhere in the build tree."
    fi

    # --- Cleanup build tree (save ~2 GB) ---
    info "Cleaning up build sources..."
    rm -rf "$SCIP_SRC_DIR"
    rm -f "/tmp/${SCIP_TARBALL}"
    cd "$REPO_ROOT"
fi

# =============================================================================
# Phase 4 — Download MiniZinc Binary Bundle
# =============================================================================
phase "Phase 4/7 — MiniZinc ${MZN_VERSION}"

if [ -x "$MZN_INSTALL_DIR/bin/minizinc" ]; then
    info "MiniZinc already installed at $MZN_INSTALL_DIR — skipping."
else
    if [ -f "/tmp/${MZN_TARBALL}" ]; then
        info "Tarball already in /tmp — skipping download."
    else
        info "Downloading MiniZinc ${MZN_VERSION} bundle..."
        wget -q --show-progress -O "/tmp/${MZN_TARBALL}" "$MZN_URL" \
            || curl -fSL -o "/tmp/${MZN_TARBALL}" "$MZN_URL" \
            || fail "Could not download MiniZinc bundle."
    fi

    info "Extracting to $MZN_INSTALL_DIR..."
    rm -rf "$MZN_INSTALL_DIR"
    mkdir -p "$MZN_INSTALL_DIR"
    tar -xf "/tmp/${MZN_TARBALL}" -C "$MZN_INSTALL_DIR" --strip-components=1

    rm -f "/tmp/${MZN_TARBALL}"
    info "MiniZinc extracted."
fi

# Create symlinks in $LOCAL_PREFIX/bin for convenience
for bin_name in minizinc fzn-gecode fzn-chuffed findMUS; do
    src="$MZN_INSTALL_DIR/bin/$bin_name"
    dst="$LOCAL_PREFIX/bin/$bin_name"
    if [ -f "$src" ] && [ ! -e "$dst" ]; then
        ln -sf "$src" "$dst"
    fi
done
info "MiniZinc symlinks created in $LOCAL_PREFIX/bin/"

# =============================================================================
# Phase 5 — Register FiberSCIP as MiniZinc Solver
# =============================================================================
phase "Phase 5/7 — Solver Registration"

MSC_FILE="$MZN_USER_CONFIG_DIR/fscip.msc"

# Write the .msc solver config (user-level, no root needed)
cat <<EOF > "$MSC_FILE"
{
  "id": "org.scip.fscip",
  "name": "FiberSCIP (Parallel)",
  "version": "${SCIP_VERSION}",
  "executable": "${REPO_ROOT}/wrapper/fscip-mzn.sh",
  "tags": ["fscip", "cp", "int", "float", "linear", "mzn"],
  "stdFlags": ["-a", "-p", "-s", "-v"],
  "supportsMzn": false,
  "supportsFzn": true,
  "needsSolns2Out": true,
  "isGUIApplication": false,
  "mznlib": "${REPO_ROOT}/mznlib/fscip"
}
EOF

info "Solver config written to $MSC_FILE"

# =============================================================================
# Phase 6 — Inject Environment into ~/.bashrc
# =============================================================================
phase "Phase 6/7 — Shell Environment"

BASHRC="$HOME/.bashrc"

# Remove old block if present (idempotent re-runs)
if grep -qF "$BASHRC_MARKER_START" "$BASHRC" 2>/dev/null; then
    info "Removing previous fscip-env block from ~/.bashrc..."
    # Use a tempfile because sed -i fails if directory permissions are weird
    grep -v -e "$BASHRC_MARKER_START" -e "$BASHRC_MARKER_END" \
         -e "export SCIPOPTDIR=" -e "export MAMBA_ROOT_PREFIX=" \
         -e "export MZN_SOLVER_PATH=" \
         "$BASHRC" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"
fi

info "Appending environment block to ~/.bashrc..."
cat <<EOF >> "$BASHRC"
$BASHRC_MARKER_START
# Rootless SCIP + MiniZinc environment (auto-generated by install.sh)
export SCIPOPTDIR="$LOCAL_PREFIX"
export MAMBA_ROOT_PREFIX="$MAMBA_ROOT"
export PATH="$LOCAL_PREFIX/bin:$MZN_INSTALL_DIR/bin:\$PATH"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/lib:$MZN_INSTALL_DIR/lib:\${LD_LIBRARY_PATH:-}"
export MZN_SOLVER_PATH="$MZN_USER_CONFIG_DIR:\${MZN_SOLVER_PATH:-}"
$BASHRC_MARKER_END
EOF

info "~/.bashrc updated. Run 'source ~/.bashrc' after installation completes."

# =============================================================================
# Phase 7 — Verification
# =============================================================================
phase "Phase 7/7 — Verification"

# Make wrapper executable
chmod +x "$REPO_ROOT/wrapper/fscip-mzn.sh"
chmod +x "$REPO_ROOT/wrapper/fscip-normalize.py" 2>/dev/null || true

ERRORS=0

# Check fscip
if [ -x "$LOCAL_PREFIX/bin/fscip" ]; then
    info "fscip binary ........ OK ($LOCAL_PREFIX/bin/fscip)"
else
    warn "fscip binary ........ MISSING"; ERRORS=$((ERRORS+1))
fi

# Check minizinc
if [ -x "$LOCAL_PREFIX/bin/minizinc" ] || [ -x "$MZN_INSTALL_DIR/bin/minizinc" ]; then
    info "minizinc binary ..... OK"
else
    warn "minizinc binary ..... MISSING"; ERRORS=$((ERRORS+1))
fi

# Check solver registration
if [ -f "$MSC_FILE" ]; then
    info "fscip.msc config .... OK ($MSC_FILE)"
else
    warn "fscip.msc config .... MISSING"; ERRORS=$((ERRORS+1))
fi

# Try listing solvers (needs PATH set for this session)
export PATH="$LOCAL_PREFIX/bin:$MZN_INSTALL_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/lib:$MZN_INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"

if command -v minizinc &>/dev/null; then
    if minizinc --solvers 2>/dev/null | grep -q "org.scip.fscip"; then
        info "Solver discovery .... OK (org.scip.fscip listed)"
    else
        warn "Solver discovery .... FAILED (org.scip.fscip not found in 'minizinc --solvers')"
        warn "  Try: source ~/.bashrc && minizinc --solvers"
        ERRORS=$((ERRORS+1))
    fi
else
    warn "Cannot run 'minizinc' — PATH not yet active. Run: source ~/.bashrc"
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    info "Installation complete. All components verified."
else
    warn "Installation finished with $ERRORS warning(s). Review output above."
fi
info "Next steps:"
info "  1. source ~/.bashrc"
info "  2. minizinc --solvers          # verify org.scip.fscip is listed"
info "  3. minizinc --solver fscip model.mzn   # test with a model"

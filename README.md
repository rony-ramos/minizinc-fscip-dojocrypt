# minizinc-fscip-dojocrypt

Automated **rootless** deployment of the [SCIP Optimization Suite](https://scipopt.org/) (FiberSCIP parallel solver) and [MiniZinc](https://www.minizinc.org/) for restricted Linux environments — no `sudo`, no system writes, no root privileges required.

## Overview

This repository provides a single-command installer that builds and integrates a complete mathematical optimization stack entirely within `$HOME/.local`:

| Component | Version | Purpose |
|---|---|---|
| **SCIP Optimization Suite** | 10.0.0 | Mixed-integer programming solver (compiled from source) |
| **FiberSCIP** (`fscip`) | 10.0.0 | Parallel variant of SCIP using thread-based parallelism |
| **MiniZinc** | 2.9.4 | Constraint modeling language & compiler (pre-built bundle) |
| **Micromamba** | latest | User-space package manager for build dependencies |

After installation, MiniZinc natively discovers FiberSCIP has `org.scip.fscip` — no manual configuration needed.

> **Note on Paths:** This installer places all binaries and libraries inside the repository directory (`.local/`) to avoid permission issues in restricted `$HOME` environments.

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/rony-ramos/minizinc-fscip-dojocrypt.git
cd minizinc-fscip-dojocrypt

# 2. Make scripts executable
chmod +x install.sh wrapper/fscip-mzn.sh

# 3. Run the installer (~30-40 min for SCIP compilation)
./install.sh

# 4. Activate the environment
source ~/.bashrc

# 5. Verify
minizinc --solvers   # Should list org.scip.fscip
```

## Prerequisites

The target system must have:

- **Linux x86_64** (tested on Ubuntu 22.04)
- **GCC/G++** (≥ 11.x)
- **Python 3** (≥ 3.10)
- **wget** or **curl**
- **Internet access** (to download SCIP, MiniZinc, and Micromamba)

> All of these are available by default on DojoCrypt/CLAASP environments.

**Not required:** `sudo`, `apt-get`, `cmake` (installed via Micromamba), or write access to system directories.

## Repository Structure

```
.
├── install.sh                  # Main orchestrator (7-phase rootless installer)
├── wrapper/
│   ├── fscip-mzn.sh            # MiniZinc ↔ FiberSCIP bridge script
│   └── fscip-normalize.py      # Solution output normalizer (FlatZinc parser)
├── mznlib/
│   └── fscip/                  # MiniZinc solver library (36 redefinition files)
│       ├── redefinitions.mzn
│       ├── linear.mzn
│       ├── fzn_circuit.mzn
│       ├── fzn_cumulative.mzn
│       └── ...
├── requirements.txt            # Python dependencies (optional)
├── .gitignore
├── README.md                   # This file
├── ARCHITECTURE.md             # Technical deep-dive
└── TROUBLESHOOTING.md          # Common issues & fixes
```

## Installation Phases

The installer runs 7 idempotent phases. Re-running `./install.sh` safely skips already-completed steps:

| Phase | Description | Time |
|---|---|---|
| 1/7 | **Micromamba** — Downloads user-space package manager | ~10s |
| 2/7 | **Build Dependencies** — Installs cmake, gmp, boost, tbb via conda-forge | ~2 min |
| 3/7 | **SCIP Optimization Suite** — Downloads and compiles from source | ~30 min |
| 4/7 | **MiniZinc** — Downloads pre-built binary bundle | ~30s |
| 5/7 | **Solver Registration** — Writes `fscip.msc` config to `~/.minizinc/solvers/` | instant |
| 6/7 | **Shell Environment** — Injects PATH/LD_LIBRARY_PATH into `~/.bashrc` | instant |
| 7/7 | **Verification** — Checks all binaries and solver discovery | instant |

## Usage

### Basic Solving

```bash
# Solve a MiniZinc model with FiberSCIP
minizinc --solver fscip model.mzn

# Solve with data file
minizinc --solver fscip model.mzn data.dzn

# Parallel solving (4 threads)
minizinc --solver fscip -p 4 model.mzn

# With time limit (10 seconds)
minizinc --solver fscip -t 10000 model.mzn

# Verbose output (solver log on stderr)
minizinc --solver fscip -v model.mzn
```

### Supported Flags

| Flag | Description |
|---|---|
| `-p N` | Number of parallel threads for FiberSCIP |
| `-t ms` | Time limit in milliseconds |
| `-v` | Verbose mode (solver log printed to stderr) |
| `-s` | Statistics (accepted for compatibility) |
| `-a` | All solutions (accepted for compatibility; SCIP returns first optimal) |

### Using Other Bundled Solvers

MiniZinc ships with Gecode and Chuffed:

```bash
minizinc --solver gecode model.mzn
minizinc --solver chuffed model.mzn
```

### Listing Available Solvers

```bash
minizinc --solvers
```

Expected output includes:

```
org.scip.fscip   FiberSCIP (Parallel) 10.0.0
org.gecode.gecode ...
org.chuffed.chuffed ...
```

## File Layout After Installation

```
[Repo Root]
├── .local/
│   ├── bin/
│   │   ├── fscip              # FiberSCIP binary
│   ├── scip               # SCIP interactive shell
│   ├── minizinc → ...     # Symlink to MiniZinc bundle
│   ├── fzn-gecode → ...
│   └── fzn-chuffed → ...
├── lib/
│   ├── libscip.so
│   ├── libsoplex.so
│   └── ...
├── include/                # SCIP headers (for development)
├── minizinc/               # MiniZinc binary bundle
│   ├── bin/
│   ├── lib/
│   └── share/
└── micromamba/             # Micromamba + scip-build environment
    ├── bin/
    └── envs/scip-build/

$HOME/.minizinc/
└── solvers/
    └── fscip.msc           # Solver registration file

$HOME/.bashrc               # Modified with fscip-env block
```

## Uninstallation

To completely remove the installation:

```bash
# 1. Remove installed binaries and libraries
rm -rf $HOME/.local/bin/fscip $HOME/.local/bin/scip
rm -rf $HOME/.local/lib/libscip* $HOME/.local/lib/libsoplex*
rm -rf $HOME/.local/minizinc
rm -rf $HOME/.local/micromamba

# 2. Remove solver configuration
rm -f $HOME/.minizinc/solvers/fscip.msc

# 3. Remove the bashrc block (between the markers)
sed -i '/# >>> fscip-env >>>/,/# <<< fscip-env <<</d' ~/.bashrc

# 4. Reload shell
source ~/.bashrc
```

## License

This integration layer is provided as-is. SCIP Optimization Suite is subject to the [Apache 2.0 License](https://scipopt.org/). MiniZinc is licensed under [MPL 2.0](https://www.minizinc.org/).

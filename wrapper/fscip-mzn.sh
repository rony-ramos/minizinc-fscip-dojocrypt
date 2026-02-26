#!/bin/bash
# =============================================================================
# fscip-mzn.sh — MiniZinc-to-FiberSCIP wrapper
# =============================================================================
# Called by MiniZinc when the user selects the fscip solver.
# Translates MiniZinc CLI flags → fscip arguments, runs the solver,
# and normalizes the output via fscip-normalize.py.
# =============================================================================
set -uo pipefail

# ---- Resolve script directory (for finding fscip-normalize.py) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ---- Locate fscip binary dynamically ----
# Priority: $HOME/.local/bin → PATH → /usr/local/bin (Docker fallback)
FSCIP_BIN=""
if [ -x "$HOME/.local/bin/fscip" ]; then
    FSCIP_BIN="$HOME/.local/bin/fscip"
elif command -v fscip &>/dev/null; then
    FSCIP_BIN="$(command -v fscip)"
elif [ -x "/usr/local/bin/fscip" ]; then
    FSCIP_BIN="/usr/local/bin/fscip"
fi

if [ -z "$FSCIP_BIN" ]; then
    echo "Error: fscip binary not found. Searched:" >&2
    echo "  - \$HOME/.local/bin/fscip" >&2
    echo "  - \$PATH" >&2
    echo "  - /usr/local/bin/fscip" >&2
    echo "Run install.sh first or ensure fscip is in your PATH." >&2
    exit 1
fi

# ---- Default values ----
THREADS=1
VERBOSE=0
SRCPATH=""
PARAMFILE="/tmp/fscip_params_$$.set"
SOLFILE="/tmp/fscip_sol_$$.txt"
LOGFILE="/tmp/fscip_run_log_$$.txt"
TIMELIMIT=""

# ---- Cleanup on exit (includes SOLFILE) ----
cleanup() {
    rm -f "$PARAMFILE" "$SOLFILE" "$LOGFILE"
}
trap cleanup EXIT

# ---- Parse MiniZinc arguments ----
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--parallel)
            THREADS="$2"
            shift 2
            ;;
        -a|--all-solutions)
            # FiberSCIP does not natively enumerate all solutions;
            # flag accepted silently for compatibility.
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -s|--statistics)
            # Accepted for compatibility; stats go to stderr via verbose.
            shift
            ;;
        -t|--time-limit)
            # MiniZinc passes time limit in milliseconds
            TIMELIMIT="$2"
            shift 2
            ;;
        *)
            if echo "$1" | grep -q '\.fzn$'; then
                SRCPATH="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$SRCPATH" ]; then
    echo "Error: No .fzn file provided." >&2
    exit 1
fi

if [ ! -f "$SRCPATH" ]; then
    echo "Error: FlatZinc file not found: $SRCPATH" >&2
    exit 1
fi

# ---- Build parameter file ----
touch "$PARAMFILE"

# If time limit was provided (in ms), convert to seconds for SCIP
if [ -n "$TIMELIMIT" ]; then
    # SCIP uses seconds (float); MiniZinc passes milliseconds (int)
    TL_SEC=$(python3 -c "print(${TIMELIMIT}/1000.0)" 2>/dev/null || echo "")
    if [ -n "$TL_SEC" ]; then
        echo "limits/time = $TL_SEC" >> "$PARAMFILE"
    fi
fi

# ---- Run FiberSCIP ----
"$FSCIP_BIN" "$PARAMFILE" "$SRCPATH" -sth "$THREADS" -fsol "$SOLFILE" -q \
    >> "$LOGFILE" 2>&1 &
FSCIP_PID=$!

if [ "$VERBOSE" -eq 1 ]; then
    tail --pid="$FSCIP_PID" -f "$LOGFILE" >&2 2>/dev/null || true
fi

# Wait for fscip to finish
wait $FSCIP_PID
RET=$?

# ---- Process output ----
if [ -f "$SOLFILE" ] && [ -s "$SOLFILE" ]; then
    # Parse solution and emit MiniZinc-compatible output
    python3 "$SCRIPT_DIR/fscip-normalize.py" "$SOLFILE" "$SRCPATH"
    echo "----------"
    echo "=========="
elif grep -q "problem is infeasible" "$LOGFILE" 2>/dev/null; then
    echo "=====UNSATISFIABLE====="
elif grep -q "problem is unbounded" "$LOGFILE" 2>/dev/null; then
    echo "=====UNBOUNDED====="
elif [ $RET -ne 0 ]; then
    echo "Error: fscip exited with code $RET" >&2
    if [ "$VERBOSE" -eq 1 ] && [ -f "$LOGFILE" ]; then
        cat "$LOGFILE" >&2
    fi
    echo "=====UNKNOWN====="
else
    # Solver ran OK but no solution file — could be infeasible or no solution found
    echo "=====UNKNOWN====="
fi

exit $RET

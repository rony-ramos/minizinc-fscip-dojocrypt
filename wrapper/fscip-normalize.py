#!/usr/bin/env python3
# =============================================================================
# fscip-normalize.py — FiberSCIP solution → MiniZinc output normalizer
# =============================================================================
# Reads a FiberSCIP solution file and the corresponding .fzn model,
# resolves output variables (including aliases and composed arrays),
# and prints them in MiniZinc-compatible format for solns2out.
# =============================================================================
import sys
import re

if len(sys.argv) < 3:
    print("Usage: fscip-normalize.py <solution_file> <fzn_file>", file=sys.stderr)
    sys.exit(1)

sol_file = sys.argv[1]
fzn_file = sys.argv[2]

# Map output variables to their definitions
# definitions[name] = 
#    None (Native, look up directly)
#    List[str] (Composition, look up elements and join)
#    str (Alias, look up target)

output_vars = set()
definitions = {}
array_dims_native = {} # name -> (min, max) for native arrays

# Helper to parse list literal "[a, b, c]"
def parse_list_content(content):
    # content is inside brackets
    # Split by comma
    items = [x.strip() for x in content.split(',')]
    return items

try:
    with open(fzn_file, 'r') as f:
        # Read full content to handle multi-line but split by semicolon
        # FZN statements end with ;
        text = f.read()
        statements = text.split(';')
        
        for stmt in statements:
            stmt = stmt.strip()
            if not stmt: continue
            stmt_clean = stmt.split('%')[0].strip()
            if not stmt_clean: continue
            
            # Check for output annotation
            is_output = ("output_var" in stmt_clean or "output_array" in stmt_clean)
            
            # Extract Name
            # "type : name :: anns = ..."
            # We assume the name is the *last* token before '::' or '=' or ';' (after type colon)
            
            if ':' not in stmt_clean:
                continue # Probably constraint or solve item
                
            # declaration part is before '='
            decl_lhs = stmt_clean.split('=')[0]
            
            # check type colon
            if ':' in decl_lhs:
                pre_ann = decl_lhs.split('::')[0]
                name_part = pre_ann.split(':')[-1].strip()
                
                # Validation
                if not re.match(r'^[a-zA-Z_]\w*$', name_part):
                    continue
                
                name = name_part
                
                if is_output:
                    output_vars.add(name)
                
                # Check for Array Dims (Native)
                if stmt_clean.lower().startswith("array"):
                     m = re.search(r'array\s*\[\s*(\d+)\.\.(\d+)\s*\]', stmt_clean)
                     if m:
                         min_idx, max_idx = int(m.group(1)), int(m.group(2))
                         array_dims_native[name] = (min_idx, max_idx)
                
                # Check for Definition (Assignment)
                if '=' in stmt_clean:
                    # Parse RHS
                    parts = stmt_clean.split('=', 1)
                    rhs = parts[1].strip()
                    rhs = rhs.rstrip(';')
                    
                    if rhs.startswith('['):
                        # List definition: X = [A, B, C]
                        # Remove enclosing brackets
                        m_list = re.match(r'\[(.*)\]', rhs, re.DOTALL)
                        if m_list:
                             content = m_list.group(1)
                             items = parse_list_content(content)
                             definitions[name] = items
                    else:
                        # Alias or Literal: X = Y or X = 1
                        definitions[name] = rhs # Store string

except Exception as e:
    sys.stderr.write(f"Parsing Error: {e}\n")

# Load Solution
sol_map = {} 
# Flattened map: "x" -> "1", "a[1]" -> "5"
# Also support "x" -> {1: 5} naming for native arrays (reusing old logic)
native_arrays_sol = {} 

with open(sol_file, 'r') as f:
    for line in f:
        line = line.strip()
        if not line: continue
        parts = line.split()
        if len(parts) < 2: continue
        key = parts[0]
        val = parts[1]
        
        if key in ["objective", "["]: continue
        if key == "no" and val == "solution": continue
        
        sol_map[key] = val
        
        # Handle array syntax from solver "x[1]"
        m = re.match(r'([^\[]+)\[(.*)\]', key)
        if m:
            base = m.group(1)
            idx = m.group(2)
            if base not in native_arrays_sol: native_arrays_sol[base] = {}
            native_arrays_sol[base][idx] = val

# Helper to resolve value
def resolve(ident, recursion_limit=10):
    if recursion_limit <= 0: return "0"
    
    # Literal check (number)
    if re.match(r'^-?[\d\.]+(e-?\d+)?$', ident):
        return ident
    if ident in ["true", "false"]:
        return ident

    # Check solver direct output
    if ident in sol_map:
        return sol_map[ident]
    
    # Check definition
    if ident in definitions:
        defn = definitions[ident]
        if isinstance(defn, list):
            # Array composition
            # Resolve all children
            vals = [resolve(x, recursion_limit-1) for x in defn]
            return f"[{', '.join(vals)}]"
        else:
            # Alias or literal assignment
            return resolve(defn, recursion_limit-1)
    
    # If native array base
    if ident in native_arrays_sol and ident in array_dims_native:
        # Construct dense array from sparse solver output
        min_v, max_v = array_dims_native[ident]
        vals = []
        for i in range(min_v, max_v+1):
            s_idx = str(i)
            vals.append(native_arrays_sol[ident].get(s_idx, "0"))
        return f"[{', '.join(vals)}]"
        
    return "0" # Default fallback for missing vars

# Output ONLY output_vars, to ensure _declmap matches
# output_vars tracks variables with :: output_var / output_array annotation.
# Objective value (if present) is not printed here — solns2out handles it.

# Sort output vars for deterministic output
for var_name in sorted(output_vars):
    val = resolve(var_name)
    print(f"{var_name} = {val};")


#!/bin/bash

# Script to copy and format contents of specified files/directories to clipboard and save in output.txt
# Supports recursive searching, skipping patterns, and generating a directory tree.

# --- Configuration ---
output_file="$(pwd)/output.txt" # Output file path

# --- Function Definitions ---

# Print usage information
usage() {
    cat << EOF
Usage: $(basename "$0") [options] [targets...]

Copies and formats contents of specified text files specified by targets to the clipboard
and saves the combined output to '$output_file'.

Targets can be specific files, directories, or glob patterns (requires -a).
Options MUST come before targets.

Options:
  -a                     Process recursively. Search within target directories.
                         If non-file/non-directory targets are provided alongside -a,
                         they are treated as glob patterns for filtering files found
                         during the recursive search (e.g., "*.py", "*.txt").
  -s <pattern>           Skip files or directories matching the glob pattern.
                         Use quotes for patterns containing wildcards (*, ?, []).
                         To skip a directory and its contents, use patterns like
                         'dirname' or '*/dirname/*'. Can be used multiple times.
  -h                     Display this help message and exit.

Examples:
  # Options first: Process all *.py recursively from current dir, skip build/
  $(basename "$0") -a -s 'build' -- . "*.py"

  # Process specific file and files directly within dir1 (non-recursive)
  $(basename "$0") file1.txt dir1

  # Process file1.py and recursively search dir1 for *.py files, skipping venv
  $(basename "$0") -a -s 'venv' file1.py dir1 "*.py"

Notes:
  - Requires 'find', 'sort', 'file', and optionally 'tree'.
  - Requires 'xclip' (Linux) or 'pbcopy' (macOS) for clipboard functionality.
  - Quote patterns containing wildcards to prevent shell expansion.
EOF
    exit 1
}

# Function to check if a file is textual (with DEBUG messages)
is_text_file() {
    local file="$1"
    echo "DEBUG: is_text_file checking: [$file]" >&2 # DEBUG

    # Check if file is readable first
    if [ ! -r "$file" ]; then
        echo "DEBUG: is_text_file: Cannot read file '$file'. Skipping." >&2
        return 1
    fi

    # Heuristic: Skip if file is very large (e.g., > 20MB) unless clearly text
    local size_kb_output size_kb
    size_kb_output=$(du -k "$file" 2>/dev/null | cut -f1) # Get size in KB
    # Ensure output is numeric before comparison
    if [[ "$size_kb_output" =~ ^[0-9]+$ ]]; then
        size_kb=$size_kb_output
        local max_size_kb=20480 # 20 MB limit - adjust as needed
        if [[ "$size_kb" -gt "$max_size_kb" ]]; then
            local quick_mime
            quick_mime=$(file -b --mime-type "$file" 2>/dev/null | cut -d'/' -f1)
            # Allow large files ONLY if mime type starts with 'text' or 'inode' (empty)
            if [[ "$quick_mime" != "text" && "$quick_mime" != "inode" ]]; then
                echo "DEBUG: is_text_file: Skipping large file (> ${max_size_kb} KiB): $file (mime prefix: ${quick_mime:-?})" >&2
                return 1
            fi
        fi
    fi # End size check

    # Use file command to determine mime type
    local mime_type
    mime_type=$(file -b --mime-type "$file" 2>/dev/null)
    echo "DEBUG: is_text_file: MIME type for [$file] is: [$mime_type]" >&2 # DEBUG

    # Allow common text types, json, xml, scripts, and importantly empty files
    if [[ "$mime_type" == text/* || \
          "$mime_type" == application/json || \
          "$mime_type" == application/xml || \
          "$mime_type" == application/javascript || \
          "$mime_type" == application/x-sh || \
          "$mime_type" == application/x-python || \
          "$mime_type" == application/x-perl || \
          "$mime_type" == application/x-executable || \
          "$mime_type" == inode/x-empty ]] || \
       # Heuristic: check for shebang if file command gives generic octet-stream type
       ( [[ "$mime_type" == "application/octet-stream" ]] && head -n 1 "$file" 2>/dev/null | grep -q '^#!' ) || \
       # Allow empty files explicitly if they exist
       ( [ ! -s "$file" ] && [ -e "$file" ] ); then
        echo "DEBUG: is_text_file: PASSED check for [$file]" >&2 # DEBUG
        return 0 # It's likely text or empty
    else
        echo "DEBUG: is_text_file: FAILED check for [$file]. Skipping non-text file." >&2
        return 1 # Not text
    fi
}


# --- Variable Initialization ---
all_flag=false
skip_patterns=()
targets=() # Will hold arguments *after* options are parsed
clipboard_tool=""
tree_output=""
processed_file_paths=() # Store full real paths of files successfully processed to avoid duplicates
count=1
all_formatted_output=""

# --- Argument Parsing (Options FIRST) ---
while getopts "as:h" opt; do
    case "$opt" in
        a) all_flag=true ;;
        s) skip_patterns+=("$OPTARG") ;;
        h) usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;; # Handle invalid options
        :) echo "Option -$OPTARG requires an argument." >&2; usage ;; # Handle missing option arg
    esac
done
shift $((OPTIND - 1)) # Remove processed options and their arguments

# Remaining arguments are targets
targets=("$@")

# --- Clipboard Tool Detection ---
if command -v xclip >/dev/null 2>&1; then
    clipboard_tool="xclip -selection clipboard" # Be explicit for xclip
elif command -v pbcopy >/dev/null 2>&1; then
    clipboard_tool="pbcopy"
else
    echo "Warning: No clipboard tool (xclip or pbcopy) found. Output will only be saved to '$output_file'." >&2
fi

# --- Target Classification ---
specific_files=()
search_dirs=()
name_patterns=() # Patterns like "*.py" used for filtering find results

for target in "${targets[@]}"; do
    if [ -f "$target" ]; then
        specific_files+=("$target")
    elif [ -d "$target" ]; then
        search_dirs+=("$target")
    else
        # Treat non-file/non-dir targets as potential name patterns
        name_patterns+=("$target")
    fi
done

# If no targets specified at all, default to current directory search
if [ ${#targets[@]} -eq 0 ]; then
    search_dirs+=(".")
fi

# If targets were given but *no search dirs* were identified among them,
# and -a *is* set, then default search dir to "."
if $all_flag && [ ${#search_dirs[@]} -eq 0 ] && [ ${#specific_files[@]} -eq 0 ] && [ ${#name_patterns[@]} -gt 0 ]; then
   echo "Info: No search directory specified with -a and patterns. Defaulting search to current directory '.'." >&2
   search_dirs+=(".")
fi

# If no search directories AND no specific files, but patterns exist without -a, warn.
if [ ${#search_dirs[@]} -eq 0 ] && [ ${#specific_files[@]} -eq 0 ] && [ ${#name_patterns[@]} -gt 0 ] && ! $all_flag; then
    echo "Warning: Name patterns ('${name_patterns[*]}') provided without -a flag and no directories/files specified. Nothing to search." >&2
fi

# --- Generate Directory Tree (Optional) ---
# Determine dirs to show in tree: use explicit search_dirs if available, else "." if implied/defaulted
tree_target_dirs_for_display=()
if [ ${#search_dirs[@]} -gt 0 ]; then
    tree_target_dirs_for_display=("${search_dirs[@]}")
elif [ ${#targets[@]} -eq 0 ]; then # If no targets were ever given, tree "."
    tree_target_dirs_for_display=(".")
fi

if [ ${#tree_target_dirs_for_display[@]} -gt 0 ]; then
    if command -v tree >/dev/null 2>&1; then
        echo "Generating directory tree structure..." >&2
        tree_output="Directory Structure:\n"
        tree_note="Based on: ${tree_target_dirs_for_display[*]}. Skipped items might not appear if filtered by 'tree -I'."
        tree_output+="$tree_note\n\n"

        tree_cmd=("tree" "-L" "3") # Limit depth for sanity, adjust if needed
        # Add skip patterns to tree's ignore list
        for pattern in "${skip_patterns[@]}"; do
            tree_cmd+=("-I" "$pattern")
        done

        # Run tree on each targeted directory
        for dir in "${tree_target_dirs_for_display[@]}"; do
            should_skip_dir=false
            base_dir=$(basename "$dir")
            full_dir=$(realpath "$dir" 2>/dev/null || echo "$dir")
            for pattern in "${skip_patterns[@]}"; do
                shopt -s extglob # Enable extended globbing for this check
                if [[ "$base_dir" == $pattern ]] || [[ "$full_dir" == $pattern ]] || [[ "$dir" == $pattern ]]; then
                     shopt -u extglob # Disable extended globbing
                     should_skip_dir=true
                     tree_output+="Tree for '$dir': (Skipped based on pattern '$pattern')\n\n"
                     break
                fi
                shopt -u extglob # Disable extended globbing
            done

            if ! $should_skip_dir && [ -d "$dir" ]; then
                tree_output+="Tree for '$dir':\n"
                tree_result=$( { "${tree_cmd[@]}" "$dir"; } 2>&1 )
                if [ $? -eq 0 ]; then
                    tree_output+="$tree_result\n\n"
                else
                    tree_output+="  (Could not generate tree for '$dir' - possibly invalid or permissions issue)\n\n"
                fi
            elif ! $should_skip_dir; then
                 if [ "$dir" != "." ]; then
                     tree_output+="Tree for '$dir': (Not a directory)\n\n"
                 fi
            fi
        done
    else
        echo "Warning: 'tree' command not found. Skipping directory structure generation. (Install with 'apt install tree' or 'brew install tree')" >&2
    fi
fi

# --- Function to Process a Single File ---
process_file() {
    local file="$1"
    local abs_file
    abs_file=$(realpath -s "$file" 2>/dev/null) || abs_file="$file" # Fallback if realpath fails
    if [ -z "$abs_file" ]; then
       echo "Warning: Could not resolve path for '$file'. Skipping." >&2
       return
    fi

    # Skip Check 1: Already processed?
    if [[ " ${processed_file_paths[@]} " =~ " $abs_file " ]]; then
        return # Skip duplicate
    fi

    # Skip Check 2: Matches skip pattern? (Now handled by find, but keep as safeguard?)
    # Consider removing this check if find logic is deemed reliable
    local base_file=$(basename "$file")
    for pattern in "${skip_patterns[@]}"; do
        shopt -s extglob
        if [[ "$base_file" == $pattern ]] || [[ "$file" == $pattern ]] || [[ "$abs_file" == $pattern ]]; then
            shopt -u extglob
            # echo "DEBUG: process_file skipping [$file] due to skip pattern [$pattern]" >&2
            return
        fi
        shopt -u extglob
    done

    # Skip Check 3: Is it text? (Uses the function with DEBUG messages)
    if ! is_text_file "$file"; then
        return # Skip non-text files
    fi

    # --- Process the file ---
    processed_file_paths+=("$abs_file") # Add full path to avoid duplicates

    local file_content
    if [ ! -f "$file" ]; then
        echo "Warning: File disappeared before processing: $file" >&2
        return
    fi
    file_content=$(cat "$file" 2>/dev/null) # Handle potential read errors during cat
    local read_error=$?
    local relative_path="${file#./}" # Clean ./ prefix for display

    all_formatted_output+="\n" # Add newline separator before each file block

    if [ $read_error -ne 0 ]; then
        formatted_output=$(printf "%d. %s:\n(Error reading file content)\n" "$count" "$relative_path")
    elif [ ! -s "$file" ] && [ -e "$file" ]; then # Check -e too for empty files
        # File exists but is empty
        formatted_output=$(printf "%d. %s:\n(empty file)\n" "$count" "$relative_path")
    else
        formatted_output=$(printf "%d. %s:\n%s\n" "$count" "$relative_path" "$file_content")
    fi

    all_formatted_output+="$formatted_output"
    count=$((count + 1))
}


# --- Main Processing ---

# 1. Process specific files provided directly *first*
processed_specific_count=0
if [ ${#specific_files[@]} -gt 0 ]; then
    echo "Processing explicitly specified files..." >&2
    for file in "${specific_files[@]}"; do
         should_skip_specific=false
         base_specific=$(basename "$file")
         abs_specific=$(realpath -s "$file" 2>/dev/null || echo "$file")
         for pattern in "${skip_patterns[@]}"; do
            shopt -s extglob
             if [[ "$base_specific" == $pattern ]] || [[ "$file" == $pattern ]] || [[ "$abs_specific" == $pattern ]]; then
                 shopt -u extglob
                 echo "Skipping specified file due to pattern '$pattern': $file" >&2
                 should_skip_specific=true
                 break
             fi
            shopt -u extglob
         done

         if ! $should_skip_specific; then
             process_file "$file"
             processed_specific_count=$((processed_specific_count + 1))
         fi
    done
    echo "Processed $processed_specific_count specific file(s)." >&2
fi

# 2. Process files found via find in search directories
if [ ${#search_dirs[@]} -gt 0 ]; then
    echo "Searching in directories: ${search_dirs[*]}" >&2
    find_cmd=("find")
    find_cmd+=("${search_dirs[@]}") # Add search paths

    # Find options/filters
    find_options=()

    # --- CORRECTED Skip/Prune Logic ---
    # Part 1: Prune directories matching skip patterns
    if [ ${#skip_patterns[@]} -gt 0 ]; then
        find_options+=("(") # Start outer prune group (quote/escape for shell)
        first_skip=true
        for pattern in "${skip_patterns[@]}"; do
            if [ "$first_skip" = false ]; then find_options+=("-o"); fi
            # Add sub-group for this pattern: ( ( -path P -o -name P ) -a -type d )
            find_options+=("(") # Start inner pattern group
            find_options+=("(") # Start path/name group
            find_options+=("-path" "$pattern")
            find_options+=("-o" "-name" "$pattern")
            find_options+=(")") # End path/name group
            find_options+=("-a" "-type" "d") # Use -a for AND with type directory
            find_options+=(")") # End inner pattern group
            first_skip=false
        done
        find_options+=(")") # End outer prune group
        find_options+=("-prune") # Prune matching directories
        find_options+=("-o") # OR (process if not pruned)
    fi
    # --- End Part 1 ---

    # --- Start of main selection logic (after potential prune) ---
    # Need parentheses if pruning is active, to group subsequent conditions
    if [ ${#skip_patterns[@]} -gt 0 ]; then find_options+=("("); fi # Start main selection group

    # Add -maxdepth 1 ONLY if -a (recursive) is NOT set
    if [ "$all_flag" = false ]; then
        find_options+=("-maxdepth" "1")
    fi

    # Add name pattern filtering *if* patterns were provided
    if [ ${#name_patterns[@]} -gt 0 ]; then
        if [ ${#name_patterns[@]} -eq 1 ]; then
            find_options+=("-name" "${name_patterns[0]}")
        else
            # Multiple patterns: group with -o
            find_options+=("(") # Start name pattern group
            first_name=true
            for pattern in "${name_patterns[@]}"; do
                if [ "$first_name" = false ]; then find_options+=("-o"); fi
                find_options+=("-name" "$pattern")
                first_name=false
            done
            find_options+=(")") # End name pattern group
        fi
    fi

    # Always require -type f (must be a file)
    find_options+=("-type" "f")

    # Part 2: Filter out files matching skip patterns using -not
    if [ ${#skip_patterns[@]} -gt 0 ]; then
        find_options+=("-not" "(") # Start file skip group
        first_skip=true
        for pattern in "${skip_patterns[@]}"; do
            if [ "$first_skip" = false ]; then find_options+=("-o"); fi
             # Add sub-group for this pattern: ( -path P -o -name P )
            find_options+=("(") # Start inner path/name group
            find_options+=("-path" "$pattern")
            find_options+=("-o" "-name" "$pattern")
            find_options+=(")") # End inner path/name group
            first_skip=false
        done
        find_options+=(")") # End file skip group
    fi
    # --- End Part 2 ---

    # --- End of main selection logic ---
    # Close parentheses if pruning is active
    if [ ${#skip_patterns[@]} -gt 0 ]; then find_options+=(")"); fi # End main selection group

    # Always print null-delimited
    find_options+=("-print0")

    # Improved Debugging Output using printf %q for clarity
    printf "Debug: find command arguments:\n" >&2
    printf "  %q\n" "${find_cmd[@]}" "${find_options[@]}" >&2

    # Execute find and process results with added DEBUG
    echo "DEBUG: Starting find execution and while loop..." >&2 # DEBUG
    while IFS= read -r -d $'\0' file; do
        echo "DEBUG: while loop received file: [$file]" >&2 # DEBUG
        process_file "$file" # This function now calls is_text_file which also has DEBUG prints
    done < <( "${find_cmd[@]}" "${find_options[@]}" 2>/dev/null | sort -z ) # Sort results, handle errors quietly
    echo "DEBUG: Finished while loop." >&2 # DEBUG

else
     echo "No search directories specified or implied for find." >&2
fi


# --- Final Output ---
final_count=$((count - 1))
echo "Processed $final_count total text file(s)." >&2

# Combine tree (if generated) and file contents
combined_output=$(printf "%s%s" "$tree_output" "${all_formatted_output#\\n}")

# Check if output is effectively empty (only contains tree or nothing)
output_check="${combined_output//[[:space:]]/}"
if [ -z "$output_check" ] && [ ! -f "$output_file" ]; then
    echo "No text files processed or found. Output file not created." >&2
elif [ -z "$output_check" ]; then
     echo "No text files processed or found. Clearing existing output file." >&2
     : > "$output_file"
else
    echo -n "$combined_output" > "$output_file"
    echo "Combined output saved to: $output_file"
fi


# Copy to clipboard if available (with fixed logic and debug)
if [ -n "$clipboard_tool" ]; then
    echo "DEBUG: Attempting to copy to clipboard using: [$clipboard_tool]" >&2 # DEBUG
    if [ -s "$output_file" ]; then
       if [[ "$clipboard_tool" == "xclip -selection clipboard" ]]; then
           echo "DEBUG: Using < redirection for xclip" >&2
           "$clipboard_tool" -i < "$output_file"
       else
           echo "DEBUG: Using pipe for $clipboard_tool" >&2
            cat "$output_file" | $clipboard_tool
       fi
       clipboard_exit_status=$?
       if [ $clipboard_exit_status -eq 0 ]; then
            echo "Output copied to clipboard successfully."
       else
            echo "Warning: Clipboard command exited with status $clipboard_exit_status. Copy may have failed." >&2
       fi
    elif [ -f "$output_file" ]; then
         echo "Output file '$output_file' is empty. Nothing copied to clipboard." >&2
    fi
fi

echo "DEBUG: Script execution finished." >&2 # DEBUG
exit 0

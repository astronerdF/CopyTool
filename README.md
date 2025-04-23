
This script helps you grab the text content from multiple files and put it all into one place: a file called `output.txt` and your copy/paste clipboard.

**1. The Basics**

*   **Copy specific files:**
    ```bash
    ./copyFiles.sh file1.txt file2.js some_config.yaml
    ```
*   **Copy files in a directory (but NOT inside subfolders):**
    ```bash
    ./copyFiles.sh my_scripts/
    ```
*   **Combine files and directories:**
    ```bash
    ./copyFiles.sh README.md my_scripts/ other_code.py
    ```

**2. Going Deeper (Recursive Search with `-a`)**

*   If you want to search inside directories *and their subdirectories*, use the `-a` flag **before** listing your targets.
*   You can also specify a pattern (like `"*.py"`) to only grab certain types of files recursively. **Remember to put quotes around patterns!**
    ```bash
    # Copy ALL .py files recursively starting from the current folder (.)
    ./copyFiles.sh -a . "*.py"

    # Copy ALL .txt files recursively starting from the 'docs' folder
    ./copyFiles.sh -a docs/ "*.txt"
    ```

**3. Skipping Things (with `-s`)**

*   If you want to exclude certain files or entire folders, use the `-s` flag followed by a pattern. Put `-s` **before** your targets. You can use `-s` multiple times.
    ```bash
    # Copy all .py files recursively, but SKIP any file ending in _test.py
    ./copyFiles.sh -a -s '*_test.py' . "*.py"

    # Copy all .js files recursively, but SKIP the entire 'node_modules' folder
    # and also skip any file named 'config.js' anywhere
    ./copyFiles.sh -a -s 'node_modules' -s 'config.js' . "*.js"
    ```

**4. The Most Important Rule: Options First!**

*   Always put flags like `-a` and `-s <pattern>` **BEFORE** you list the files, directories, or patterns you want to include.

    *   **Correct:** `./copyFiles.sh -a -s 'build/' . "*.c"`
    *   **Incorrect:** `./copyFiles.sh . "*.c" -a -s 'build/'`

**5. Where Does the Output Go?**

*   A file named `output.txt` will be created (or overwritten) in the same directory where you run the script.
*   The same content will be copied to your clipboard (if `xclip` or `pbcopy` is installed).

**6. Optional: See the Structure (`tree`)**

*   If you have the `tree` command installed (you might need to install it yourself, e.g., `sudo apt install tree`), the script will print a simple map of the directories it's looking in at the beginning of `output.txt`. This helps visualize what's being included/excluded.

That's it! Experiment with these options to grab exactly the code or text you need.

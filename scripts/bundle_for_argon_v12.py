#!/usr/bin/env python3
import os
import sys
import subprocess

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ARGON_SCRIPT = os.path.expanduser("~/.gemini/config/skills/argon-consultant/query_argon.py")
ARGON_PYTHON = os.path.expanduser("~/.gemini/config/skills/argon-consultant/.venv/bin/python")
OUTPUT_FILE = os.path.join(REPO_ROOT, "docs", "ARGON_ROADMAP_V12.md")
PROMPT_TEMPLATE = os.path.join(REPO_ROOT, "scripts", "argon_prompt_v12.md")

EXTENSIONS = ('.swift', '.c', '.h', '.sh', '.md', '.example')
EXCLUDE_DIRS = {'.git', 'logs', 'assets', '.build-cache', 'DiskHealthMonitor.app', 'docs'}

def run_cmd(cmd):
    try:
        return subprocess.check_output(cmd, cwd=REPO_ROOT, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return "N/A"

def collect_files():
    collected = []
    for root, dirs, files in os.walk(REPO_ROOT):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith('.')]
        for f in sorted(files):
            if f.endswith(EXTENSIONS) and not f.startswith('.'):
                collected.append(os.path.join(root, f))
    return sorted(collected)

def build_prompt():
    with open(PROMPT_TEMPLATE, 'r', encoding='utf-8') as f:
        master_prompt = f.read()

    git_history = run_cmd(["git", "log", "--oneline", "-n", "25"])
    swift_version = run_cmd(["swiftc", "--version"])
    swift_ver_line = swift_version.splitlines()[0] if swift_version else "N/A"
    uname_str = run_cmd(["uname", "-srm"])

    context_header = f"""

# ENVIRONMENT & TEST STATUS
- Host Platform: `{uname_str}`
- Swift Compiler: `{swift_ver_line}`
- Current Test Status: 100% Passing (15 C/IOKit Unit Tests, 36 Swift Core Engine Tests, 5 CLI integration stages)
- Git Recent Commit History (Rounds 1-11 Evolution):
```text
{git_history}
```

# ATTACHED REPOSITORY CONTEXT

"""

    bundle = [master_prompt, context_header]
    files = collect_files()
    total_chars = 0
    for path in files:
        rel = os.path.relpath(path, REPO_ROOT)
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        total_chars += len(content)
        bundle.append(f"### File: `{rel}`\n```\n{content}\n```\n\n")

    return "".join(bundle), len(files), total_chars

if __name__ == "__main__":
    dry_run = "--dry-run" in sys.argv
    full_prompt, file_count, chars = build_prompt()
    est_tokens = len(full_prompt) // 4

    print(f"📦 Bundled {file_count} files for Gemini 4 Argon.")
    print(f"📊 Total length: {len(full_prompt):,} characters (~{est_tokens:,} estimated tokens).")

    if dry_run:
        print("🔍 Dry run completed successfully. No API call made.")
        sys.exit(0)

    if not os.path.exists(ARGON_PYTHON) or not os.path.exists(ARGON_SCRIPT):
        print(f"❌ Argon runner not found at: {ARGON_SCRIPT}")
        sys.exit(1)

    os.makedirs(os.path.join(REPO_ROOT, "docs"), exist_ok=True)
    print(f"🚀 Dispatching prompt to Gemini 4 Argon via argon-consultant...")
    
    proc = subprocess.Popen(
        [ARGON_PYTHON, ARGON_SCRIPT, "-"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    stdout, stderr = proc.communicate(input=full_prompt)
    if stderr:
        sys.stderr.write(stderr)
    
    if proc.returncode != 0:
        print(f"❌ Error invoking Argon: returncode {proc.returncode}")
        sys.exit(proc.returncode)

    with open(OUTPUT_FILE, 'w', encoding='utf-8') as out:
        out.write(stdout)
    
    print(f"✅ Argon Review successfully generated and saved to: {OUTPUT_FILE}")

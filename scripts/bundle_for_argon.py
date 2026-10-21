#!/usr/bin/env python3
import os
import sys
import subprocess

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ARGON_SCRIPT = os.path.expanduser("~/.gemini/config/skills/argon-consultant/query_argon.py")
ARGON_PYTHON = os.path.expanduser("~/.gemini/config/skills/argon-consultant/.venv/bin/python")
OUTPUT_FILE = os.path.join(REPO_ROOT, "docs", "ARGON_ROADMAP.md")

EXTENSIONS = ('.swift', '.c', '.h', '.sh', '.md', '.example')
EXCLUDE_DIRS = {'.git', 'logs', 'assets', '.build-cache', 'DiskHealthMonitor.app', 'docs'}

def collect_files():
    collected = []
    for root, dirs, files in os.walk(REPO_ROOT):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith('.')]
        for f in sorted(files):
            if f.endswith(EXTENSIONS) and not f.startswith('.'):
                collected.append(os.path.join(root, f))
    return sorted(collected)

def build_prompt(prompt_template_path):
    with open(prompt_template_path, 'r', encoding='utf-8') as f:
        master_prompt = f.read()

    bundle = [master_prompt, "\n\n# ATTACHED REPOSITORY CONTEXT\n\n"]
    files = collect_files()
    print(f"📦 Bundling {len(files)} files for Gemini 4 Argon...")
    for path in files:
        rel = os.path.relpath(path, REPO_ROOT)
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            content = f.read()
        bundle.append(f"### File: `{rel}`\n```\n{content}\n```\n\n")

    return "".join(bundle)

if __name__ == "__main__":
    prompt_file = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "scripts", "argon_prompt.md")
    os.makedirs(os.path.join(REPO_ROOT, "docs"), exist_ok=True)
    full_prompt = build_prompt(prompt_file)
    print(f"🚀 Sending query to Gemini 4 Argon ({len(full_prompt):,} characters)...")
    
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
    
    print(f"✅ Argon Roadmap successfully generated and saved to: {OUTPUT_FILE}")

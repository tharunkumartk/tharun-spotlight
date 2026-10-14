"""Compile and run the Linux-testable sources in a Swift container on Modal."""
import modal

image = (
    modal.Image.from_registry("swift:6.1-noble", add_python="3.12")
    .add_local_dir("/home/ubuntu/FastLauncher", "/work", ignore=["build"])
)
app = modal.App("fastlauncher-check", image=image)

@app.function(timeout=600)
def check():
    import subprocess
    cmd = (
        "cd /work && swiftc -swift-version 5 Sources/Calc.swift Sources/Fuzzy.swift Sources/Apps.swift "
        "Sources/FSearchClient.swift Tests/main.swift -o /tmp/t 2>&1 && chmod +x /work/Tests/fake_fsearch.py && /tmp/t /work/Tests/fake_fsearch.py 2>&1"
    )
    r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

@app.local_entrypoint()
def main():
    code, out = check.remote()
    print(out)
    print("exit", code)

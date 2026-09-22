import os
import pathlib
import shutil
import subprocess
import sys

simulator, bundle, source = sys.argv[1:]
container = pathlib.Path(subprocess.check_output(
    ['xcrun', 'simctl', 'get_app_container', simulator, bundle, 'data'], text=True).strip())
destination = container / 'Documents' / 'seed.jsonl'
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source, destination)

print(f'Importing seed data from {source}', flush=True)
completed = False
with subprocess.Popen(
    ['xcrun', 'simctl', 'launch', '--console-pty', simulator, bundle, '--seed'],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    env={**os.environ, 'SIMCTL_CHILD_LLVM_PROFILE_FILE': str(container / 'tmp' / 'seed-%p.profraw')},
) as process:
    for line in process.stdout:
        print(line, end='', flush=True)
        if line.startswith('SUNOH_SEED_OK '):
            completed = True
    result = process.wait()

if result != 0 or not completed:
    sys.exit('Seed import failed. See the app output above; completed activities are preserved for retry.')

# The Debug import process exits after committing. Reopen without the seed flag.
subprocess.run(['xcrun', 'simctl', 'launch', simulator, bundle], check=True)

import os
import subprocess
import sys

simulator, bundle = sys.argv[1:]
print(f'Removing all activities from {bundle} on simulator {simulator}', flush=True)
completed = False
with subprocess.Popen(
    ['xcrun', 'simctl', 'launch', '--console-pty', simulator, bundle, '--clean'],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    env={**os.environ, 'SIMCTL_CHILD_LLVM_PROFILE_FILE': '/tmp/sunoh-clean-%p.profraw'},
) as process:
    for line in process.stdout:
        print(line, end='', flush=True)
        if line.startswith('SUNOH_CLEAN_OK '):
            completed = True
    result = process.wait()

if result != 0 or not completed:
    sys.exit('Activity cleanup failed. See the app output above.')

subprocess.run(['xcrun', 'simctl', 'launch', simulator, bundle], check=True)

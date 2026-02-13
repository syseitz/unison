#!/usr/bin/env python3
"""Quick test for lowmemory mode correctness and performance."""
import os, subprocess, time, sys

base = '/tmp/ubench_test'
src = os.path.join(base, 'src')
dst = os.path.join(base, 'dst')

# Cleanup
subprocess.run(['rm', '-rf', base], check=False)
os.makedirs(os.path.join(src, 'd0'), exist_ok=True)
os.makedirs(dst, exist_ok=True)

# Create 50 test files
for i in range(2):
    with open(os.path.join(src, 'd0', f'f{i:04d}.txt'), 'w') as f:
        f.write(f'content_{i}\n')

# Remove old archives
home = os.path.expanduser('~')
unison_dir = os.path.join(home, '.unison')
os.makedirs(unison_dir, exist_ok=True)

def clean_archives():
    for f in os.listdir(unison_dir):
        if f.startswith('ar') or f.startswith('fp') or f.startswith('sq'):
            try:
                os.remove(os.path.join(unison_dir, f))
            except Exception:
                pass

clean_archives()

unison = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       '_build', 'default', 'src', 'linktext.exe')
common = [unison, src, dst, '-batch', '-auto', '-times', '-fastcheck', 'true',
          '-confirmbigdel=false', '-dumbtty', '-lowmemory']

def run_sync(label):
    print(f'\n=== {label} ===')
    t0 = time.time()
    r = subprocess.run(common, capture_output=True, text=True)
    t1 = time.time()
    print(f'Time: {t1-t0:.3f}s  Return code: {r.returncode}')
    out = r.stdout + r.stderr
    # Print lines with timing info or important status
    for line in out.split('\n'):
        if any(k in line for k in ['TIMING', 'SCAN_TIMING', 'FPCACHE', 'Nothing',
                                     'new file', 'changed', 'replicas', 'Synchronization',
                                     'Error', 'Fatal', 'lowmemory', 'buildUpdate',
                                     'NEW_FILE_DEBUG', 'DB_LOAD_DEBUG', 'FIND_DEBUG',
                                     'LOAD_LM_DEBUG', 'LOAD_ARCH_DEBUG',
                                     'LM_LOADED_DEBUG', 'SET_ARCH_DEBUG',
                                     'LM_BLOCK_DEBUG', 'COMMIT_DB_DEBUG',
                                     'STORE_DEBUG', 'REPLACE_ARCH_DEBUG',
                                     'MARKEQUAL_DEBUG', 'MARKEQUAL_ITEM']):
            print(f'  {line}')

run_sync('Initial Sync (lowmemory)')
run_sync('SS1 (lowmemory)')
run_sync('SS2 (lowmemory)')

# Now test normal mode for comparison
subprocess.run(['rm', '-rf', dst], check=False)
os.makedirs(dst, exist_ok=True)
clean_archives()

common_normal = [unison, src, dst, '-batch', '-auto', '-times', '-fastcheck', 'true',
                 '-confirmbigdel=false', '-dumbtty']

def run_sync_normal(label):
    print(f'\n=== {label} ===')
    t0 = time.time()
    r = subprocess.run(common_normal, capture_output=True, text=True)
    t1 = time.time()
    print(f'Time: {t1-t0:.3f}s  Return code: {r.returncode}')
    out = r.stdout + r.stderr
    for line in out.split('\n'):
        if any(k in line for k in ['TIMING', 'SCAN_TIMING', 'FPCACHE', 'Nothing',
                                     'new file', 'changed', 'replicas', 'Synchronization',
                                     'Error', 'Fatal']):
            print(f'  {line}')

run_sync_normal('Initial Sync (normal)')
run_sync_normal('SS1 (normal)')
run_sync_normal('SS2 (normal)')

# Cleanup
subprocess.run(['rm', '-rf', base], check=False)

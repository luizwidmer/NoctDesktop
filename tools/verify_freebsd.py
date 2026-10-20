#!/usr/bin/env python3
"""Checks for a configured, unlocked synthetic guest. Never creates a vault.

Run the browser benchmark before `storage`; output contains local paths and
belongs in ignored evidence/. This is bounded evidence, not OS certification.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"src"))
from freebsd_vm import FreeBSDWorkspace

GUEST = r'''
import json,os,tempfile,subprocess
from pathlib import Path
h=Path.home();w=h/'Workspace';b=w/'Applications/browser'
with tempfile.NamedTemporaryFile() as f:
    f.write(b'NOCT_SYNTHETIC_TEMP');f.flush();temporary=f.name
    assert Path(temporary).is_relative_to(h/'.tmp')
cookie=b/'Data/cookies.sqlite'
cookies=json.loads(subprocess.check_output(['/usr/local/bin/sqlite3','-readonly','-json',str(cookie),
    "SELECT value FROM moz_cookies WHERE name='noct-canary'"]) or b'[]')
assert {'value':'NOCT_SYNTHETIC_20261020'} in cookies
download=w/'Downloads/noct-test.bin'
assert download.stat().st_size==8388608
apps=json.loads((h/'.config/noct/apps.json').read_text()) if (h/'.config/noct/apps.json').exists() else []
profiles={}
for app in [{'id':'browser'},*apps]:
    root=w/'Applications'/app['id']
    profiles[app['id']]={d:sum(1 for p in (root/d).rglob('*') if p.is_file()) for d in ['Data','Cache','Preferences','Temp']}
    prefs=root/'Preferences/settings.json'
    if prefs.exists():profiles[app['id']]['settings']=json.loads(prefs.read_text())
assert profiles['browser']['Data']>0 and profiles['browser']['Cache']>0
print(json.dumps({'uid':os.getuid(),'temporary_path':temporary,'cookie_persisted':True,'download_bytes':download.stat().st_size,
  'profile_file_counts':profiles,'installed_apps':len(apps),'folder_persisted':(w/'Documents/Persistence Check').is_dir(),
  'layout':json.loads((h/'.config/noct/desktop.json').read_text()) if (h/'.config/noct/desktop.json').exists() else {}},indent=2))
'''


def writable_files(w):
    pids=list(w.vm_processes())+list(w.gpu_processes())
    if not pids:raise RuntimeError('Start the configured guest first')
    raw=subprocess.check_output(['/usr/sbin/lsof','-nP','-p',','.join(map(str,pids)),'-Fpfant'])
    rows=[];current={};pid=None
    for line in raw.decode(errors='replace').splitlines():
        if line.startswith('p'):pid=int(line[1:])
        if line.startswith('f'):
            if current:rows.append(current)
            current={'pid':pid,'fd':line[1:]}
        if line.startswith('a'):current['access']=line[1:]
        if line.startswith('t'):current['type']=line[1:]
        if line.startswith('n'):current['name']=line[1:]
    if current:rows.append(current)
    writes=[r for r in rows if r.get('access') in ['w','u'] and r.get('type') in ['REG','DIR']]
    outside=[r for r in writes if not Path(r['name']).is_relative_to(w.vm)]
    return {'open_writable_files':writes,'outside_vault':outside,'passed':not outside}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--workspace',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('action',choices=['storage','gpu'])
    a=p.parse_args();w=FreeBSDWorkspace(a.workspace);w.require_mounted()
    if a.action=='gpu':
        r=w.ssh("su -l noct -c '/usr/local/bin/python3.12 /opt/noct/noct_gpu.py'",timeout=30)
        result={'guest_gpu':json.loads(r.stdout),'host_runtime':writable_files(w)}
    else:
        command='export TMPDIR=/home/noct/.tmp XDG_RUNTIME_DIR=/home/noct/.run; /usr/local/bin/python3.12 -c '+shlex.quote(GUEST)
        r=w.ssh('su -l noct -c '+shlex.quote(command))
        result={'guest_storage':json.loads(r.stdout),'host_runtime':writable_files(w),
                'guest_mounts_swap':w.ssh('mount -p; swapinfo -k').stdout.decode()}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'saved':str(a.output),'host_writable_files_confined':result['host_runtime']['passed']}))
    return 0 if result['host_runtime']['passed'] else 1


if __name__=='__main__':raise SystemExit(main())

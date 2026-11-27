#!/usr/bin/env python3
"""Filter only generic Darwin source adaptation. Do not enable a foreign GPU service."""
import argparse,pathlib,re,shutil,subprocess
P=pathlib.Path

def filter_generic(text):
    # git-format/unified sections from the pinned existing repository's Mesa patch.
    blocks=re.split(r'(?m)(?=^--- a/)',text)
    out=[]
    for b in blocks:
        if not b.startswith('--- a/'):continue
        name=b.splitlines()[0].split()[1][2:]
        if '/a6xx/' in name or name.endswith('/freedreno_batch.h'):continue
        # Omit localized diff directory listings, not patch content.
        out.append('\n'.join(l for l in b.splitlines() if not l.startswith(('Только в ','Only in ')))+'\n')
    if not out:raise ValueError('no generic source patch sections')
    return ''.join(out)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--repo',required=True,type=P);ap.add_argument('--source',required=True,type=P);a=ap.parse_args()
    src=a.source;old=a.repo/'userland/mesa';here=P(__file__).parent
    if not (src/'src/gallium/drivers/freedreno/a5xx').is_dir():raise SystemExit('A5xx source missing')
    # Reuse only source-level Darwin build/ABI adaptation already in this repo.
    # There is no A509 GEM/submit service yet: fail closed at runtime rather
    # than accidentally talking to the existing A610 RedwoodGPU service.
    d=src/'src/redwood-drm';shutil.copytree(old/'redwood-drm',d)
    p=d/'redwood_drm.c';s=p.read_text()
    anchor='#define REDWOOD_GPU_SERVICE     "RedwoodGPU"'
    if s.count(anchor)!=1:raise ValueError('unexpected transport source')
    s=s.replace(anchor,'#define REDWOOD_GPU_SERVICE     "WhyredA509RenderService"')
    s=s.replace('#include <IOKit/IOKitLib.h>','#include "iokit_compat.h"')
    p.write_text(s);shutil.copy2(here/'iokit_compat.h',d/'iokit_compat.h')
    p=src/'.whyred-darwin-generic.patch';p.write_text(filter_generic((old/'freedreno-darwin.patch').read_text()))
    for patch in [p,old/'osmesa-es-profile.patch']:
        subprocess.run(['patch','--dry-run','--batch','--forward','-p1','-i',str(patch.resolve())],cwd=src,check=True)
        subprocess.run(['patch','--batch','--forward','-p1','-i',str(patch.resolve())],cwd=src,check=True)
    (src/'.whyred-source-prepared').write_text('Mesa 25.0.7, A509 transport intentionally not published\n')
    print('MESA_A5XX_SOURCE_PREPARED (not runtime GPU acceleration)')
if __name__=='__main__':main()

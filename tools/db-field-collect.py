import subprocess, collections, glob, os, json
RANGES=[(0x137000,0x137400),(0x020000,0x020300),(0x00e100,0x00e300),(0x00e9e0,0x00e9e4),(0x13b000,0x13f000)]
inr=lambda a: any(lo<=a<hi for lo,hi in RANGES)
vals=collections.defaultdict(collections.Counter); chips=collections.defaultdict(set); reads=collections.Counter()
for chipdir in ['nvc0','nvc1','nvc3','nvc4','nvc8','nvce','nvcf','nvd7','nvd9']:
    for f in glob.glob(f'{chipdir}/*/**/*.xz', recursive=True):
        b=os.path.basename(f)
        if 'mmiotrace' not in b and 'downclock' not in b: continue
        p=subprocess.Popen(['xz','-dc',f],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
        bar0=None
        for raw in p.stdout:
            if bar0 is None:
                if raw.startswith(b'MAP '):
                    q=raw.split()
                    if len(q)>=6 and q[5]==b'0x1000000': bar0=int(q[3],16)
                continue
            if raw[:2] not in (b'W ',b'R '): continue
            q=raw.split()
            if len(q)<6: continue
            try: a=int(q[4],16)-bar0; v=int(q[5],16)
            except ValueError: continue
            if not inr(a): continue
            if raw[:1]==b'W': vals[a][v]+=1; chips[a].add(chipdir)
            else: reads[a]+=1
        p.kill()
out={hex(a):{'vals':{hex(v):c for v,c in vals[a].most_common()}, 'chips':sorted(chips[a]), 'reads':reads[a]} for a in sorted(vals)}
json.dump(out, open('fermi_writes.json','w'), indent=0)
print(len(out), 'регистров с записями')
for a in sorted(vals): print(hex(a), len(vals[a]), 'разных значений', sum(vals[a].values()), 'записей', ','.join(sorted(chips[a])))

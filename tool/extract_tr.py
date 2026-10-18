import re,sys,json
# Extracts the English keys passed to tr('...') (handles \' escapes, adjacent literals, and r'' not used).
lit = r"'(?:[^'\\]|\\.)*'"
pat = re.compile(r"\btr\(\s*((?:" + lit + r"\s*)+)")
keys=[]
for f in sys.argv[1:]:
    s=open(f).read()
    for m in pat.finditer(s):
        parts=re.findall(lit, m.group(1))
        k=''.join(p[1:-1].replace("\\'","'").replace('\\\\','\\') for p in parts)
        if k not in keys: keys.append(k)
print(json.dumps(keys,ensure_ascii=False,indent=1))

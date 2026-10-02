import glob
import json
import socket
import struct
import sys

s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
socks=sorted(glob.glob('/run/user/1000/i3/ipc-socket.*'))
assert socks, 'no i3 socket found'
s.connect(socks[-1])
# i3 4.2x wire protocol: magic "i3-ipc" (6B) + size (u32) + type (u32), LE
s.sendall(b'i3-ipc'+struct.pack('<II',0,4))   # GET_TREE, size=0
hdr=s.recv(14)
size=struct.unpack('<I',hdr[6:10])[0]
data=b''
while len(data)<size: data+=s.recv(size-len(data))
tree=json.loads(data)
def _unwrap(x,depth=0):
    while isinstance(x,str):
        x=json.loads(x); depth+=1
        print("extra load",depth, file=sys.stderr)
    return x
tree=_unwrap(tree)
def walk(n,d=0):
    t=n.get('type','?')
    extra=''
    if t=='workspace': extra=f" layout={n.get('layout')} focused={n.get('focused')} name={n.get('name')!r}"
    if t=='con': extra=f" layout={n.get('layout')}"
    if n.get('window') is not None: extra=f" win={n['window']} class={n.get('class')} title={n.get('name','')[:36]!r} layout={n.get('layout')} focused={n.get('focused')}"
    print('  '*d+f"{t}"+extra)
    for c in n.get('nodes',[]): walk(c,d+1)
print("type:",type(tree), file=sys.stderr)
if isinstance(tree,dict): print("keys:",list(tree.keys()), file=sys.stderr)
if isinstance(tree,list): print("item0:",type(tree[0]), file=sys.stderr)
items = tree if isinstance(tree,list) else [tree]
for w in items: walk(w)

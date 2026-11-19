import struct, sys

class BitErr(Exception): pass

class Bits:
    def __init__(s, data):
        s.d=data; s.p=0; s.buf=0; s.n=0
    def ensure(s,k):
        while s.n<k:
            if s.p+1<len(s.d)+1:
                w = s.d[s.p]|(s.d[s.p+1]<<8) if s.p+1<len(s.d) else 0
            s.p+=2
            s.buf=(s.buf<<16)|w; s.n+=16
    def peek(s,k):
        s.ensure(k); return (s.buf>>(s.n-k))&((1<<k)-1)
    def read(s,k):
        if k==0: return 0
        v=s.peek(k); s.n-=k; s.buf&=(1<<s.n)-1; return v
    def align(s):
        s.n -= s.n%16 if False else 0

def build_table(lens):
    # canonical huffman; returns dict (len,code)->sym via decode function
    maxl=max(lens) if lens else 0
    codes={}
    code=0
    for l in range(1,17):
        for sym,ll in enumerate(lens):
            if ll==l:
                codes[(l,code)]=sym; code+=1
        code<<=1
    return codes

def hdec(b,codes,lens):
    code=0
    for l in range(1,17):
        code=(code<<1)|b.read(1)
        s=codes.get((l,code))
        if s is not None: return s
    raise BitErr("bad huff")

def read_lens(b, lens, first, last):
    pre=[b.read(4) for _ in range(20)]
    pc=build_table(pre)
    i=first
    while i<last:
        z=hdec(b,pc,pre)
        if z==17:
            n=b.read(4)+4
            for _ in range(n): lens[i]=0; i+=1
        elif z==18:
            n=b.read(5)+20
            for _ in range(n): lens[i]=0; i+=1
        elif z==19:
            n=b.read(1)+4
            z2=hdec(b,pc,pre)
            v=(lens[i]-z2)%17
            for _ in range(n): lens[i]=v; i+=1
        else:
            lens[i]=(lens[i]-z)%17; i+=1

def decode(data, window_bits, outsize, verbose=False):
    slots={15:30,16:32,17:34,18:36,19:38,20:42,21:50}[window_bits]
    # position base/extra
    extra=[0]*51; base=[0]*52
    j=0
    for i in range(0,50,2):
        extra[i]=j; extra[i+1]=j
        if i!=0 and j<17: j+=1
    # libmspack: 
    extra=[]; base=[]
    pos=0; 
    for i in range(51):
        e = 0 if i<4 else (17 if i>=36 else (i-2)>>1)
        extra.append(e); base.append(pos); pos+=1<<e
    main_n=256+slots*8
    main=[0]*main_n; length=[0]*249
    R=[1,1,1]
    out=bytearray()
    ptr=0; first=True; blk_rem=0; btype=0; aligned_lens=[0]*8
    frame=0
    while len(out)<outsize:
        # frame header
        if data[ptr]==0xFF:
            usz=(data[ptr+1]<<8)|data[ptr+2]; csz=(data[ptr+3]<<8)|data[ptr+4]; ptr+=5
        else:
            usz=32768; csz=(data[ptr]<<8)|data[ptr+1]; ptr+=2
        chunk=data[ptr:ptr+csz]; ptr+=csz
        b=Bits(chunk)
        if first:
            first=False
            if b.read(1): 
                b.read(16); b.read(16)
        target=len(out)+usz if True else 0
        fstart=len(out)
        target=fstart+usz
        while len(out)<target:
            if blk_rem==0:
                btype=b.read(3); blk_rem=(b.read(16)<<8)|b.read(8)
                if verbose: print("block",btype,blk_rem)
                if btype in (1,2):
                    if btype==2:
                        aligned_lens=[b.read(3) for _ in range(8)]
                        ac=build_table(aligned_lens)
                    read_lens(b,main,0,256); read_lens(b,main,256,main_n)
                    mc=build_table(main)
                    read_lens(b,length,0,249); lc=build_table(length)
                elif btype==3:
                    # align, read R
                    if b.n%16 : b.read(b.n%16)
                    # after aligning, remaining buffered bits are whole words
                    R=[]
                    for _ in range(3):
                        lo=b.read(16); hi=b.read(16); R.append(lo|(hi<<16))
                    blk_rem_unc=blk_rem
                else: raise BitErr("btype %d"%btype)
            if btype==3:
                # raw bytes
                n=min(blk_rem, target-len(out)) if True else 0
                for _ in range(n):
                    if not getattr(b,'q',None):
                        w=b.read(16); b.q=[w&0xFF,w>>8]
                    out.append(b.q.pop(0))
                blk_rem-=n
                if blk_rem==0 and (blk_rem_unc&1): b.q=[]; b.read(16) if b.n>=16 else None
                continue
            m=hdec(b,mc,main)
            if m<256:
                out.append(m); blk_rem-=1; continue
            m-=256
            ml=m&7; slot=m>>3
            if ml==7: ml+=hdec(b,lc,length)
            ml+=2
            if slot==0: off=R[0]
            elif slot==1: off=R[1]; R[1]=R[0]; R[0]=off
            elif slot==2: off=R[2]; R[2]=R[0]; R[0]=off
            else:
                e=extra[slot]
                if btype==2 and e>=3:
                    v=0
                    if e>3: v=b.read(e-3)<<3
                    a=hdec(b,ac,aligned_lens)
                    v+=a
                else: v=b.read(e)
                off=base[slot]-2+v
                R[2]=R[1]; R[1]=R[0]; R[0]=off
            if off>len(out): raise BitErr("offset %d > pos %d"%(off,len(out)))
            for _ in range(ml):
                out.append(out[-off])
            blk_rem-=ml
        # frame end: align to 16
        if b.n%16: b.read(b.n%16)
        frame+=1
    return bytes(out[:outsize])

if __name__=="__main__":
    d=open(sys.argv[1],'rb').read()
    payload=d[20:]
    for wb in range(15,22):
        try:
            o=decode(payload,wb,135168)
            print("window",wb,"OK",len(o)); open('/tmp/xtd_w%d.bin'%wb,'wb').write(o)
        except Exception as e:
            print("window",wb,"fail",type(e).__name__,e)

import struct, zlib, sys
from tile import tile_blocks, swap16

PC_VIRT=0x50000000; PC_PHYS=0x60000000
XBOX_DICT_VTABLE = bytes.fromhex('0c836100')   # stored as-is (not byte swapped), taken from sample
XBOX_TEX_VTABLE  = bytes.fromhex('9c1a6300')
FMT = {b'DXT1':(18,8), b'DXT3':(19,16), b'DXT5':(20,16)}

def seg_size(flags):
    def one(v): return (v & 0x7FF) << (((v>>11)&0xF)+8)
    return one(flags & 0x7FFF), one((flags>>15)&0x7FFF)

def enc_size(need):
    need=max(4096,-(-need//4096)*4096)
    for shift in range(15,-1,-1):
        unit=1<<(shift+8); m=-(-need//unit)
        if 16<=m<=0x7FF: return (m|(shift<<11)), m*unit
    raise ValueError("too big")

def parse_wtd(raw):
    magic,ver,flags=struct.unpack('<III',raw[:12])
    assert raw[:4]==b'RSC\x05' and ver==8, "not a PC RSC5 v8 file"
    vs,ps=seg_size(flags)
    body=zlib.decompress(raw[12:])
    assert len(body)==vs+ps, (len(body),vs,ps)
    v=body[:vs]; p=body[vs:]
    u32=lambda b,o: struct.unpack_from('<I',b,o)[0]
    u16=lambda b,o: struct.unpack_from('<H',b,o)[0]
    def vptr(x): assert x>>28==5; return x & 0x0FFFFFFF
    hashp=vptr(u32(v,0x10)); cnt=u16(v,0x14)
    texp=vptr(u32(v,0x18)); cnt2=u16(v,0x1C)
    assert cnt==cnt2
    hashes=[u32(v,hashp+4*i) for i in range(cnt)]
    texs=[]
    for i in range(cnt):
        T=vptr(u32(v,texp+4*i))
        nameo=vptr(u32(v,T+0x14)); name=v[nameo:v.index(b'\0',nameo)]
        w,h=u16(v,T+0x1C),u16(v,T+0x1E)
        fcc=bytes(v[T+0x20:T+0x24]); levels=v[T+0x27]
        floats=v[T+0x28:T+0x40]
        pp=u32(v,T+0x48); assert pp>>28==6; poff=pp&0x0FFFFFFF
        u16a,u16b=u16(v,T+0x08),u16(v,T+0x0A)
        texs.append(dict(name=name,w=w,h=h,fcc=fcc,levels=levels,floats=floats,poff=poff,a=u16a,b=u16b))
    return hashes,texs,p

def build_xtd_body(hashes,texs,pcphys):
    v=bytearray(b'\xcd'*0)  # build virtual
    def align(n,a): return (n+a-1)//a*a
    N=len(texs)
    off=0x230
    tex_off=[off+0x80*i for i in range(N)]
    off+=0x80*N
    name_off=[]
    for t in texs:
        name_off.append(off); off+=align(len(t['name'])+1,16)
    hash_off=off; off+=align(4*N,16)
    texarr_off=off; off+=align(4*N,16)
    vsz_need=off
    vflags,vsz=enc_size(vsz_need)
    # physical
    phys=bytearray(); poffs=[]; info=[]
    for t in texs:
        if t['fcc'] not in FMT: raise ValueError("unsupported format %r"%t['fcc'])
        gfmt,bsz=FMT[t['fcc']]
        bw=max(1,(t['w']+3)//4); bh=max(1,(t['h']+3)//4)
        src=pcphys[t['poff']:t['poff']+bw*bh*bsz]
        assert len(src)==bw*bh*bsz, "truncated pixel data"
        data=swap16(tile_blocks(src,bw,bh,bsz))
        poffs.append(len(phys)); phys+=data
        phys+=b'\x00'*(align(len(phys),4096)-len(phys))
        info.append((gfmt,(bw+31)//32*32))
    pflags,psz=enc_size(len(phys))
    phys+=b'\x00'*(psz-len(phys))
    V=bytearray(b'\xcd'*vsz)
    P=lambda fmt,o,*a: struct.pack_into('>'+fmt,V,o,*a)
    V[0:4]=XBOX_DICT_VTABLE
    P('I',4,PC_VIRT+0x20); P('I',8,0); P('I',0xC,1)
    P('I',0x10,PC_VIRT+hash_off); P('HH',0x14,N,N)
    P('I',0x18,PC_VIRT+texarr_off); P('HH',0x1C,N,N)
    P('I',0x20,0)
    for i,t in enumerate(texs):
        T=tex_off[i]; D=T+0x40
        V[T:T+0x40]=b'\xcd'*0x40
        V[T:T+4]=XBOX_TEX_VTABLE
        P('I',T+4,0); P('HH',T+8,t['a'],t['b']); P('II',T+0xC,0,0)
        P('I',T+0x14,PC_VIRT+name_off[i]); P('I',T+0x18,PC_VIRT+D)
        P('HH',T+0x1C,t['w'],t['h']); V[T+0x20:T+0x24]=bytes([0,0,0,1])
        fl=struct.unpack('<5f',t['floats']) if False else struct.unpack('<6f',t['floats'][:24]) if False else None
        f=t['floats']  # 20 bytes?? we need 3+3 floats = 24 bytes
        V[T+0x24:T+0x3C]=b''.join(struct.pack('>f',x) for x in struct.unpack('<6f',t['floats']))
        gfmt,alignedw=info[i]
        pitch=alignedw*4//32
        ptr=PC_PHYS+poffs[i]
        V[D:D+0x40]=b'\xcd'*0x40
        P('I',D+0x00,0x00200003); P('I',D+4,1)
        P('IIII',D+8,0,0,0,0xFFFF0000); P('I',D+0x18,0xFFFF0000)
        P('I',D+0x1C,(1<<31)|(pitch<<22)|2)
        P('I',D+0x20,(ptr&0xFFFFF000)|(1<<6)|gfmt)
        P('I',D+0x24,(t['w']-1)|((t['h']-1)<<13))
        P('I',D+0x28,0x0D10); P('I',D+0x2C,0); P('I',D+0x30,0x200)
        V[name_off[i]:name_off[i]+len(t['name'])+1]=t['name']+b'\0'
        P('I',texarr_off+4*i,PC_VIRT+T)
        P('I',hash_off+4*i,hashes[i])
    return bytes(V),bytes(phys),(vflags|(pflags<<15)|0xC0000000)

# ---- LZX "stored" encoder in Xbox frame format
def lzx_stored(data):
    out=bytearray(); FR=32768; n=len(data)
    frames=[]
    # bitstream pieces for first frame: E8 bit(0) + type(3)=3 + size(24) -> 28 bits, pad to 32
    hdr=(0<<31)|(3<<28)|(n<<4)
    first=struct.pack('<HH',(hdr>>16)&0xFFFF,hdr&0xFFFF)
    first+=struct.pack('<III',1,1,1)
    for fi in range(0,n,FR):
        chunk=data[fi:fi+FR]
        payload=(first if fi==0 else b'')+chunk
        if fi+FR>=n and (n&1): payload+=b'\0'   # pad odd-size raw block
        if len(chunk)==FR:
            out+=struct.pack('>H',len(payload))+payload
        else:
            out+=b'\xff'+struct.pack('>HH',len(chunk),len(payload))+payload
    return bytes(out)

def convert(wtd_bytes):
    h,t,p=parse_wtd(wtd_bytes)
    V,P,flags=build_xtd_body(h,t,p)
    body=lzx_stored(V+P)
    return b'RSC\x05'+struct.pack('<II',7,flags)+struct.pack('>II',0x0FF512EF,len(body))+body

if __name__=="__main__":
    out=convert(open(sys.argv[1],'rb').read()); open(sys.argv[2],'wb').write(out); print(len(out))

"""Rebuild Hermi cursor masters, multi-size CUR/ANI and hand-tuned tiny icons.
Run: py -3 -B assets/tools/make_cursors.py
Only Pillow and the standard library are required. Coordinates use a 32px grid.
"""
from pathlib import Path
import io, json, math, struct
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'cursors' / 'src'
SRC.mkdir(parents=True, exist_ok=True)
SIZES = [32,48,64,96,128]
T,C,I,S,G,Y = '#C96442','#FAF9F5','#3D3929','#F0EEE6','#7A9A6B','#FFE7B8'

class Art:
    """Hand-drawn vector coordinates, rasterized at 8x with Pillow."""
    def __init__(self):
        self.im=Image.new('RGBA',(256,256)); self.d=ImageDraw.Draw(self.im)
        self.shadow=Image.new('RGBA',(256,256));self.sd=ImageDraw.Draw(self.shadow)
    def pts(self,p): return [(round(x*8),round(y*8)) for x,y in p]
    def poly(self,p,fill=T,outline=True):
        p=self.pts(p)
        if outline:
            q=[(x+5,y+7) for x,y in p];self.sd.polygon(q,fill=I);self.sd.line(q+[q[0]],fill=I,width=24,joint='curve')
            self.d.polygon(p,fill=fill);self.d.line(p+[p[0]],fill=C,width=16,joint='curve')
        else:self.d.polygon(p,fill=fill)
    def ellipse(self,b,fill=T,outline=True):
        b=tuple(round(x*8) for x in b)
        if outline:
            self.sd.ellipse(tuple(x+6 for x in b),outline=I,width=24);self.d.ellipse(b,fill=fill,outline=C,width=16)
        else:self.d.ellipse(b,fill=fill)
    def line(self,p,fill=T,width=2,outline=True):
        p=self.pts(p)
        if outline:
            self.sd.line([(x+5,y+7) for x,y in p],fill=I,width=round((width+6)*8),joint='curve')
            self.d.line(p,fill=C,width=round((width+4)*8),joint='curve')
        self.d.line(p,fill=fill,width=round(width*8),joint='curve')
    def save(self,name):
        self.im=Image.alpha_composite(self.shadow.filter(ImageFilter.GaussianBlur(4)),self.im)
        self.im.save(SRC/(name+'.png'));return self.im

def arrow(a):
    a.poly([(0,0),(2,25),(8,20),(13,29),(17,27),(12,18),(21,17),(17,12),(14,13)])

def hermi(a,x=16,y=17,k=1,phase=0,frame=None):
    """Tiny hand-drawn icon uses the approved mascot's silhouette and palette."""
    def e(b,c,ol=False):a.ellipse([x+b[0]*k,y+b[1]*k,x+b[2]*k,y+b[3]*k],c,ol)
    def p(q,c,ol=False):a.poly([(x+u*k,y+v*k) for u,v in q],c,ol)
    animated=frame is not None
    bob=2*math.sin(phase)/k if animated else math.sin(phase)*.55
    for j in range(4):
        dx=-7+j*4
        if animated:
            lifted=((frame//3)%2)==(0 if j<2 else 1)
            dy=(-2 if lifted else 1)/k;swing=(-1.5 if lifted else 1.5)/k
        else:dy=math.sin(phase+j*math.pi);swing=0
        e((dx+swing,5+dy,dx+3+swing,9+dy),T)
    p([(-8,-5+bob),(-8,5),(8,5),(8,-5+bob)],S,True)
    p([(-10,-4+bob),(0,-12+bob),(10,-4+bob)],T,True)
    p([(4,-9+bob),(4,-14+bob),(7,-14+bob),(7,-6+bob)],S)
    e((-2,-7+bob,3,-2+bob),Y)
    e((-1,-14+bob,2,-11+bob),G)
    e((-7,0,7,9),'#D97757' if animated else T)
    for dx in [-4,4]:
        e((dx-1,-3,dx+1,3),T)
        if animated and frame in [9,10]:
            a.line([(x+(dx-1.7)*k,y-2*k),(x+(dx+1.7)*k,y-2*k)],I,.9/k,False)
        else:
            e((dx-2,-4,dx+2,0),C);e((dx-1,-3.6,dx+1,-.5),I)
            e((dx-.6,-3.3,dx+.1,-2.5),C)
    e((-11,3,-5,8),T);e((5,2,12,9),T)
    a.line([(x-1.5*k,y+5*k),(x,y+6*k),(x+1.5*k,y+5*k)],I,.45*k,False)
    if animated:
        progress=frame/12
        # Puff rises four actual32px pixels and fades, including in working.
        cx=x+5.5*k+math.sin(phase)*.6;cy=y+(-15+bob)*k-progress*4
        radius=1+progress*.8;opacity=round(255*(1-progress))
        a.ellipse((cx-radius,cy-radius,cx+radius,cy+radius),(250,249,245,opacity),False)
    else:
        smoke_x=math.cos(phase)*1.2;smoke_y=math.sin(phase)*.8
        e((5+smoke_x,-18+bob+smoke_y,7+smoke_x,-16+bob+smoke_y),C)

def double(a,angle):
    pts=[(-13,0),(-7,-6),(-7,-2),(7,-2),(7,-6),(13,0),(7,6),(7,2),(-7,2),(-7,6)]
    r=math.radians(angle)
    a.poly([(16+x*math.cos(r)-y*math.sin(r),16+x*math.sin(r)+y*math.cos(r)) for x,y in pts])

ROLES={'Arrow':'arrow.cur','Help':'help.cur','AppStarting':'working.ani','Wait':'busy.ani','Crosshair':'precision.cur','IBeam':'text.cur','NWPen':'pen.cur','No':'unavailable.cur','SizeNS':'size-ns.cur','SizeWE':'size-we.cur','SizeNWSE':'size-nwse.cur','SizeNESW':'size-nesw.cur','SizeAll':'move.cur','UpArrow':'alternate.cur','Hand':'link.cur','Pin':'pin.cur','Person':'person.cur'}
HOT={'arrow':(0,0),'help':(0,0),'working':(0,0),'busy':(16,16),'precision':(16,16),'text':(16,16),'pen':(3,29),'unavailable':(16,16),'size-ns':(16,16),'size-we':(16,16),'size-nwse':(16,16),'size-nesw':(16,16),'move':(16,16),'alternate':(16,1),'link':(4,3),'pin':(0,0),'person':(0,0)}

def master(name,frame=0):
    a=Art();phase=frame*math.tau/12
    if name in ['arrow','help','working','pin','person']:arrow(a)
    if name=='help':
        a.ellipse((16,2,30,16),C);a.line([(21,6),(24,5),(26,7),(23,10)],T,1.4,False);a.ellipse((22,12,24,14),T,False)
    elif name=='working':hermi(a,24,22,.58,phase,frame)
    elif name=='busy':hermi(a,16,20,1,phase,frame)
    elif name=='precision':
        for p in [[(16,3),(16,11)],[(16,21),(16,29)],[(3,16),(11,16)],[(21,16),(29,16)]]:a.line(p,width=1)
        a.ellipse((13,13,19,19))
    elif name=='text':
        a.line([(16,3),(16,29)],width=1.5)
        a.line([(11,3),(21,3)],width=1.5);a.line([(11,29),(21,29)],width=1.5)
    elif name=='pen':
        a.poly([(3,29),(6,20),(23,3),(29,9),(12,26)]);a.poly([(3,29),(6,20),(12,26)],Y,False);a.ellipse((2,28,4,30),I,False)
    elif name=='unavailable':
        a.line([(25,22),(29,26),(27,29)],width=2);a.ellipse((25,27,30,31),T)
        a.ellipse((4,3,28,27));a.ellipse((9,8,23,22),'#00000000',False);a.line([(8,7),(24,23)],width=3)
    elif name.startswith('size-'):double(a,{'size-ns':90,'size-we':0,'size-nwse':45,'size-nesw':-45}[name])
    elif name=='move':
        a.poly([(16,2),(22,8),(18,8),(18,14),(24,14),(24,10),(30,16),(24,22),(24,18),(18,18),(18,24),(22,24),(16,30),(10,24),(14,24),(14,18),(8,18),(8,22),(2,16),(8,10),(8,14),(14,14),(14,8),(10,8)])
    elif name=='alternate':a.poly([(16,1),(25,11),(20,11),(20,29),(12,29),(12,11),(7,11)])
    elif name=='link':
        # Open pincer pointing up-left; a long upper jaw and shorter lower jaw.
        a.poly([(4,3),(10,4),(18,7),(23,12),(26,19),(25,25),(20,29),(14,28),(10,25),(8,22),(6,18),(3,14),(7,14),(11,16),(15,21),(18,21),(19,18),(18,15),(14,12),(9,10),(5,8)])
        a.line([(9,6),(14,8)],C,1,False)
    elif name=='pin':
        a.poly([(23,29),(16,18),(16,10),(23,4),(30,10),(30,18)]);a.poly([(18,12),(23,8),(28,12)],C,False);a.ellipse((21,13,25,17),Y,False)
    elif name=='person':hermi(a,25,24,.5)
    a.save(f'{name}-{frame:02}' if name in ['busy','working'] else name)
    return a.im

# Windows' own arrow fills about 59% of its cell; a drawing that fills the whole cell reads 1.7x too big.
CURSOR_SCALE=0.62

def shrink(im,hot):
    # Scale about the hotspot so the click point stays exactly where it was.
    k=im.width/32;s=CURSOR_SCALE
    small=im.resize((round(im.width*s),round(im.height*s)),Image.Resampling.LANCZOS)
    out=Image.new('RGBA',im.size,(0,0,0,0))
    out.alpha_composite(small,(round(hot[0]*k*(1-s)),round(hot[1]*k*(1-s))))
    return out

def cur(im,hot):
    im=shrink(im,hot)
    blobs=[];entries=[];offset=6+16*len(SIZES)
    for n in SIZES:
        tile=im.resize((n,n),Image.Resampling.LANCZOS)
        b=io.BytesIO();tile.save(b,format='BMP');dib=bytearray(b.getvalue()[14:])
        struct.pack_into('<i',dib,8,n*2)
        stride=((n+31)//32)*4;mask=bytearray(stride*n);alpha=tile.getchannel('A')
        for y in range(n):
            for x in range(n):
                if alpha.getpixel((x,y))<128:mask[(n-1-y)*stride+x//8]|=1<<(7-x%8)
        blob=bytes(dib)+bytes(mask)
        hx=round(hot[0]*n/32);hy=round(hot[1]*n/32)
        entries.append(struct.pack('<BBBBHHII',n,n,0,0,hx,hy,len(blob),offset));blobs.append(blob);offset+=len(blob)
    return struct.pack('<HHH',0,2,len(SIZES))+b''.join(entries)+b''.join(blobs)

def chunk(name,data):return name+struct.pack('<I',len(data))+data+(b'\0' if len(data)%2 else b'')
def ani(frames):
    # Windows uses 1/60-second jiffies: 60 steps repeat 12 frames five times.
    # [5,5,4,5,5] yields an exact average 80ms with native quantization.
    rates=[5,5,4,5,5]*12;seq=[i%12 for i in range(60)]
    head=struct.pack('<9I',36,12,60,0,0,32,1,5,3)
    body=chunk(b'anih',head)+chunk(b'rate',struct.pack('<60I',*rates))+chunk(b'seq ',struct.pack('<60I',*seq))
    body+=chunk(b'LIST',b'fram'+b''.join(chunk(b'icon',f) for f in frames))
    return b'RIFF'+struct.pack('<I',len(body)+4)+b'ACON'+body

def tiny_house(n):
    # Distinct grid-fit drawings for 16 and 24px, never merely downscaled.
    im=Image.new('RGBA',(n,n));d=ImageDraw.Draw(im)
    if n==16:
        d.rounded_rectangle((3,6,12,14),2,fill=C)
        d.polygon([(1,7),(7,1),(14,7)],fill=T)
        d.rectangle((5,8,6,9),fill='#201D1A');d.rectangle((9,8,10,9),fill='#201D1A')
        d.ellipse((11,10,15,14),fill='#D97757');d.polygon([(12,9),(15,10),(13,12)],fill='#D97757')
    else:
        d.rounded_rectangle((4,9,18,21),3,fill=C)
        d.polygon([(1,10),(11,1),(22,10)],fill=T)
        d.ellipse((7,12,9,14),fill='#201D1A');d.ellipse((13,12,15,14),fill='#201D1A')
        d.ellipse((17,15,23,22),fill='#D97757');d.polygon([(19,12),(23,14),(20,18)],fill='#D97757')
    return im

def ico(images,path):
    blobs=[];entries=[];offset=6+16*len(images)
    for im in images:
        n=im.width;b=io.BytesIO();im.save(b,format='PNG');blob=b.getvalue()
        entries.append(struct.pack('<BBBBHHII',n%256,n%256,0,0,1,32,len(blob),offset));blobs.append(blob);offset+=len(blob)
    path.write_bytes(struct.pack('<HHH',0,1,len(images))+b''.join(entries)+b''.join(blobs))

def main():
    for role,file in ROLES.items():
        name=Path(file).stem
        if file.endswith('.ani'):
            frames=[cur(master(name,j),HOT[name]) for j in range(12)]
            (ROOT/'cursors'/file).write_bytes(ani(frames))
        else:(ROOT/'cursors'/file).write_bytes(cur(master(name),HOT[name]))
    (ROOT/'cursors'/'scheme.json').write_text(json.dumps({**ROLES,'SchemeName':'claude-house'},indent=2)+'\n',encoding='utf-8')
    icon=ROOT/'icons'/'house-1024.png'
    if icon.exists():
        base=Image.open(icon).convert('RGBA');sizes=[16,20,24,32,40,48,64,128,256]
        images=[tiny_house(n) if n in [16,24] else base.resize((n,n),Image.Resampling.LANCZOS) for n in sizes]
        for im in images:im.save(ROOT/'icons'/f'house-{im.width}.png')
        ico(images,ROOT/'icons'/'house.ico')
    for name in ['folder-projects','folder-docs']:
        p=ROOT/'icons'/(name+'-1024.png')
        if p.exists():
            base=Image.open(p).convert('RGBA');ico([base.resize((n,n),Image.Resampling.LANCZOS) for n in [16,20,24,32,40,48,64,128,256]],ROOT/'icons'/(name+'.ico'))
    p=ROOT/'icons'/'terminal.png'
    if p.exists():
        base=Image.open(p).convert('RGBA')
        for n in [32,48]:base.resize((n,n),Image.Resampling.LANCZOS).save(ROOT/'icons'/f'terminal-{n}.png')

if __name__=='__main__':main()

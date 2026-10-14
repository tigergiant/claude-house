"""Cursor and icon evidence from actual CUR/ANI payloads. Run with py -3 -B.
Metric: mean absolute RGBA channel difference (0..255), twelve consecutive
32px frame pairs including the loop boundary. Transparent RGB is premultiplied
by alpha so invisible color does not inflate motion measurements.
"""
from pathlib import Path
import io,json,struct,sys
from PIL import Image,ImageChops,ImageStat,ImageDraw,ImageFont,ImageOps
R=Path(__file__).resolve().parents[1]
def chunks(data,start=0):
    while start+8<=len(data):
        tag=data[start:start+4];n=struct.unpack_from('<I',data,start+4)[0]
        yield tag,data[start+8:start+8+n];start+=8+n+n%2
def cur32(data):
    for j in range(struct.unpack_from('<H',data,4)[0]):
        w,h,_,_,hx,hy,n,off=struct.unpack_from('<BBBBHHII',data,6+j*16)
        if w==32:
            dib=data[off:off+n];header=struct.unpack_from('<I',dib)[0]
            im=Image.frombytes('RGBA',(32,32),dib[header:header+32*32*4],'raw','BGRA',0,-1)
            return im,(hx,hy)
    raise ValueError('32px entry missing')
def frames(name):
    data=(R/'cursors'/name).read_bytes();cs=dict(chunks(data,12))
    return [cur32(v)[0] for tag,v in chunks(cs[b'LIST'],4) if tag==b'icon']
def visible(im):
    a=im.getchannel('A');rgb=[ImageChops.multiply(c,a) for c in im.split()[:3]]
    return Image.merge('RGBA',(*rgb,a))
def metric(fs):
    fs=[visible(im) for im in fs]
    vals=[sum(ImageStat.Stat(ImageChops.difference(fs[j],fs[(j+1)%len(fs)])).mean)/4 for j in range(len(fs))]
    return {'mean_absolute_difference':sum(vals)/len(vals),'pair_differences':vals,'definition':'Premultiplied RGBA, 0..255 channel units, 12 consecutive32px pairs including wrap'}
def capture(stage):
    p=R/'tools'/'w13-verification.json'
    result=json.loads(p.read_text()) if p.exists() else {}
    result[stage]={name:metric(frames(name+'.ani')) for name in ['busy','working']}
    im,hot=cur32((R/'cursors'/'link.cur').read_bytes());result[stage]['link_hotspot']=hot
    if stage=='before':im.save(R/'preview'/'w13-link-before.png')
    else:
        result[stage]['ico_sizes']=sorted([list(s) for s in Image.open(R/'icons'/'house.ico').ico.sizes()])
        result[stage]['native_sizes']={r['file']:r['native_size'] for r in json.loads((R/'tools'/'generation-records.json').read_text()) if r['file'] in ['look/avatar.png','look/lockscreen.png','look/wallpaper.png','look/wallpaper-evening.png']}
    p.write_text(json.dumps(result,indent=2)+'\n',encoding='utf8');print(json.dumps(result[stage]))
def proof():
    b=Image.new('RGB',(1600,900),'#FAF9F5');d=ImageDraw.Draw(b);f=lambda n:ImageFont.load_default(size=n)
    d.text((25,15),'W13 / small-size review + old/new claw',font=f(30),fill='#3D3929')
    old=Image.open(R/'preview'/'w13-link-before.png').convert('RGBA');new,hot=cur32((R/'cursors'/'link.cur').read_bytes())
    for j,(title,im) in enumerate([('Old claw / 32px',old),('New claw / 32px',new)]):
        x=30+j*270;d.text((x,70),title,font=f(22),fill='#3D3929');b.paste(im,(x,115),im)
        q=im.resize((160,160),Image.Resampling.NEAREST);b.paste(q,(x+45,115),q)
    for j,n in enumerate([32,48]):
        im=Image.open(R/'look'/'avatar.png').convert('RGBA').resize((n,n),Image.Resampling.LANCZOS)
        mask=Image.new('L',(n,n));ImageDraw.Draw(mask).ellipse((0,0,n-1,n-1),fill=255);im.putalpha(mask)
        x=630+j*270;d.text((x,70),f'Avatar / {n}px',font=f(22),fill='#3D3929');b.paste(im,(x,115),im)
        q=im.resize((192,192),Image.Resampling.NEAREST);b.paste(q,(x+55,115),q)
    for j,n in enumerate([16,24]):
        im=Image.open(R/'icons'/f'house-{n}.png').convert('RGBA');x=1200+j*190
        d.text((x,70),f'House / {n}px',font=f(22),fill='#3D3929');b.paste(im,(x,115),im)
        q=im.resize((128,128),Image.Resampling.NEAREST);b.paste(q,(x+20,160),q)
    d.text((300,295),f'Upper-jaw tip hotspot {hot}',font=f(19),fill='#3D3929')
    for name,y in [('working',360),('busy',560)]:
        d.text((25,y),name+' / frames0..11 / actual32px',font=f(22),fill='#3D3929')
        for j,im in enumerate(frames(name+'.ani')):
            x=270+j*108;b.paste(im,(x,y+40),im);q=im.resize((96,96),Image.Resampling.NEAREST);b.paste(q,(x,y+85),q)
    results=json.loads((R/'tools'/'w13-verification.json').read_text())
    for j,name in enumerate(['busy','working']):
        a=results['before'][name]['mean_absolute_difference'];z=results['after'][name]['mean_absolute_difference']
        d.text((25,780+j*40),f'{name}: mean absolute32px frame difference {a:.4f} -> {z:.4f}',font=f(23),fill='#3D3929')
    b.save(R/'preview'/'w13-checks.png')
if __name__=='__main__':
    if sys.argv[1]=='proof':proof()
    else:capture(sys.argv[1])

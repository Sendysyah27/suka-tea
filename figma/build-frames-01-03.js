const F = 'Plus Jakarta Sans';
for (const s of ['Regular','Medium','SemiBold','Bold','ExtraBold']) {
  await figma.loadFontAsync({family: F, style: s});
}
const rgb = h => { const n = parseInt(h.slice(1), 16); return {r: ((n>>16)&255)/255, g: ((n>>8)&255)/255, b: (n&255)/255}; };
const C = {emerald:'#0A9B6C', dark:'#067A55', bg:'#F2F7F2', card:'#FFFFFF', ink:'#1A2E25', muted:'#6B7F74', border:'#E3EDE7', red:'#D64545', amber:'#E8A13A', mint:'#D9EFE4'};
function box(p,x,y,w,h,fill,r,stroke){ const n=figma.createRectangle(); n.resize(w,h); n.x=x; n.y=y; n.fills=fill?[{type:'SOLID',color:rgb(fill)}]:[]; if(r) n.cornerRadius=r; if(stroke){ n.strokes=[{type:'SOLID',color:rgb(stroke)}]; n.strokeWeight=1; } p.appendChild(n); return n; }
function ell(p,x,y,w,h,fill,stroke){ const n=figma.createEllipse(); n.resize(w,h); n.x=x; n.y=y; n.fills=fill?[{type:'SOLID',color:rgb(fill)}]:[]; if(stroke){ n.strokes=[{type:'SOLID',color:rgb(stroke)}]; n.strokeWeight=1.5; } p.appendChild(n); return n; }
function txt(p,x,y,w,s,size,style,color,align){ const t=figma.createText(); t.fontName={family:F,style}; t.characters=s; t.fontSize=size; t.fills=[{type:'SOLID',color:rgb(color)}]; t.textAlignHorizontal=align||'LEFT'; t.textAutoResize='HEIGHT'; t.resize(w, t.height); t.x=x; t.y=y; p.appendChild(t); return t; }
function line(p,x,y,w){ return box(p,x,y,w,1,C.border,0); }
function screen(name,x){ const f=figma.createFrame(); f.name=name; f.resize(390,844); f.x=x; f.y=0; f.fills=[{type:'SOLID',color:rgb(C.bg)}]; f.clipsContent=true; figma.currentPage.appendChild(f); return f; }
function nav(f,active){ box(f,0,780,390,1,C.border,0); box(f,0,781,390,63,C.card,0); const items=['Kasir','Menu','Stok','Keuangan','Laporan']; items.forEach((it,i)=>{ const x=i*78; ell(f,x+33,792,12,12, it===active?C.emerald:'#B9C9BE'); txt(f,x,810,78,it,11,'Medium', it===active?C.emerald:C.muted,'CENTER'); }); }
function chip(p,x,y,w,s,active){ box(p,x,y,w,36, active?C.emerald:C.card,18, active?null:C.border); txt(p,x,y+9,w,s,13,active?'SemiBold':'Medium', active?'#FFFFFF':C.ink,'CENTER'); }

// ---------- 01 Kasir ----------
const f1 = screen('01 Kasir', 0);
txt(f1,16,24,200,'Kasir',22,'Bold',C.ink);
box(f1,300,22,74,32,C.emerald,16); txt(f1,300,29,74,'Owner',13,'SemiBold','#FFFFFF','CENTER');
box(f1,16,72,358,44,C.card,12,C.border); ell(f1,30,86,16,16,null,C.muted); txt(f1,54,84,300,'Cari menu…',14,'Regular',C.muted);
chip(f1,16,132,72,'Semua',true); chip(f1,96,132,92,'Teh Klasik',false); chip(f1,196,132,84,'Teh Buah',false); chip(f1,288,132,84,'Teh Susu',false);
const products=[['Es Teh Manis','Teh Klasik','Rp3.000 – Rp5.000'],['Es Teh Tawar','Teh Klasik','Rp3.000 – Rp5.000'],['Es Teh Melati','Teh Klasik','Rp4.000 – Rp6.000'],['Es Teh Lemon','Teh Buah','Rp5.000 – Rp7.000'],['Es Teh Hijau','Teh Buah','Rp6.000 – Rp8.000'],['Es Teh Susu','Teh Susu','Rp8.000 – Rp10.000']];
products.forEach((p,i)=>{ const col=i%2, row=Math.floor(i/2); const x=16+col*187, y=184+row*188; box(f1,x,y,171,176,C.card,20,C.border); box(f1,x+10,y+10,151,80,C.mint,12); ell(f1,x+66,y+30,40,40,'#FFFFFF'); txt(f1,x+12,y+100,147,p[0],15,'SemiBold',C.ink); txt(f1,x+12,y+122,147,p[1],12,'Regular',C.muted); txt(f1,x+12,y+144,110,p[2],14,'Bold',C.ink); ell(f1,x+125,y+134,36,36,C.emerald); txt(f1,x+125,y+140,36,'+',20,'Bold','#FFFFFF','CENTER'); });
box(f1,16,704,358,56,C.card,16,C.border);
txt(f1,32,722,190,'Keranjang (3) • Rp16.000',14,'SemiBold',C.ink);
box(f1,232,712,126,40,C.emerald,12); txt(f1,232,721,126,'Bayar',15,'SemiBold','#FFFFFF','CENTER');
nav(f1,'Kasir');
txt(figma.currentPage, 0, 860, 390, 'Note: tombol Bayar terkunci + spinner saat memproses (anti double-tap).', 11, 'Medium', C.muted);

// ---------- 02 Keranjang ----------
const f2 = screen('02 Keranjang', 440);
box(f2,180,12,30,4,'#C9D6CE',2);
txt(f2,16,24,200,'Keranjang',22,'Bold',C.ink);
const items=[['Es Teh Manis Reguler','(Normal, Es Normal)','Rp3.000','1'],['Es Teh Lemon Reguler','(Normal, Es Normal)','Rp5.000','1'],['Es Teh Melati Reguler','(Normal, Es Normal)','Rp4.000','2']];
items.forEach((it,i)=>{ const y=76+i*100; box(f2,16,y,358,88,C.card,20,C.border); txt(f2,32,y+12,200,it[0],15,'SemiBold',C.ink); txt(f2,32,y+34,200,it[1],12,'Regular',C.muted); txt(f2,32,y+58,120,it[2],14,'Bold',C.ink); ell(f2,276,y+30,28,28,null,C.border); txt(f2,276,y+35,28,'-',16,'Bold',C.ink,'CENTER'); txt(f2,308,y+35,24,it[3],15,'SemiBold',C.ink,'CENTER'); ell(f2,336,y+30,28,28,C.emerald); txt(f2,336,y+35,28,'+',16,'Bold','#FFFFFF','CENTER'); });
txt(f2,16,392,200,'Cara bayar',15,'SemiBold',C.ink);
chip(f2,16,420,88,'Tunai',true); chip(f2,112,420,100,'Transfer',false); chip(f2,220,420,76,'QRIS',false);
chip(f2,16,464,120,'QRIS manual',false); chip(f2,144,464,104,'E-Wallet',false);
txt(f2,16,528,100,'Total',16,'SemiBold',C.ink); txt(f2,200,524,174,'Rp16.000',22,'ExtraBold',C.ink,'RIGHT');
box(f2,16,568,358,56,C.emerald,16); txt(f2,16,585,358,'Bayar',17,'SemiBold','#FFFFFF','CENTER');
txt(f2,16,634,358,'Tombol terkunci saat memproses • anti double-tap',12,'Medium',C.muted,'CENTER');
nav(f2,'Kasir');

// ---------- 03 Struk Digital ----------
const f3 = screen('03 Struk Digital', 880);
box(f3,24,24,342,744,C.card,20,C.border);
let y = 48;
txt(f3,48,y,294,'SUKA TEA',18,'ExtraBold',C.ink,'CENTER'); y+=30;
txt(f3,48,y,294,'Stand Es Teh',13,'Regular',C.muted,'CENTER'); y+=28;
line(f3,48,y,294); y+=16;
function rrow(yy,l,r,sz,w,cl,cr){ txt(f3,48,yy,180,l,sz,w,cl||C.ink); txt(f3,194,yy,148,r,sz,w,cr||C.ink,'RIGHT'); }
rrow(y,'Kasir','Kasir',14,'Regular'); y+=24;
rrow(y,'Waktu','2026-11-22 17:05',14,'Regular'); y+=24;
line(f3,48,y,294); y+=16;
const sitems=[['1x Es Teh Manis Reguler','Rp3.000'],['1x Es Teh Lemon Reguler','Rp5.000'],['2x Es Teh Melati Reguler','Rp8.000']];
sitems.forEach(it=>{ rrow(y,it[0],it[1],14,'SemiBold'); y+=24; txt(f3,48,y,294,'(Normal, Es Normal)',12,'Regular',C.muted); y+=22; });
line(f3,48,y,294); y+=16;
rrow(y,'TOTAL','Rp16.000',17,'Bold'); y+=30;
rrow(y,'Bayar (Transfer)','Rp16.000',14,'Regular'); y+=24;
rrow(y,'Kembali','Rp0',14,'Regular'); y+=24;
line(f3,48,y,294); y+=16;
txt(f3,48,y,294,'Terima kasih sudah mampir!',14,'Medium',C.ink,'CENTER'); y+=40;
box(f3,48,y,141,44,C.card,12,C.border); txt(f3,48,y+12,141,'Bagikan',14,'SemiBold',C.emerald,'CENTER');
box(f3,201,y,141,44,C.card,12,C.border); txt(f3,201,y+12,141,'Simpan PDF',14,'SemiBold',C.emerald,'CENTER'); y+=56;
box(f3,48,y,294,48,C.emerald,12); txt(f3,48,y+13,294,'Selesai',15,'SemiBold','#FFFFFF','CENTER'); y+=60;
txt(f3,48,y,294,'Struk tersimpan — bisa dibuka lagi dari Riwayat',12,'Regular',C.muted,'CENTER');
nav(f3,'Kasir');

return {frames: [{name: f1.name, id: f1.id}, {name: f2.name, id: f2.id}, {name: f3.name, id: f3.id}]};

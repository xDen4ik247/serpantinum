//! Lazy cover thumbnails + a dominant colour per album (port of thumbs.py, which uses Pillow).
//! ~/.cache/glass-music/thumbs/<sha1(album)>.jpg (256 px) and index.json {album: {p, c, mt}}.
//! Decoding goes through libjpeg-turbo like Pillow's, and Pillow's reduce / resample code is
//! ported as is (same fixed-point maths), so the colours come out identical.
use crate::pymath;
use crate::pyjson;
use crate::pystr;
use serde_json::{json, Map, Value};
use std::sync::{Arc, Condvar, Mutex};

const SIZE: usize = 256;

// ---------------------------------------------------------------- libjpeg-turbo (TurboJPEG 3 API)
#[allow(non_camel_case_types)]
type tjhandle = *mut libc::c_void;
#[link(name = "turbojpeg")]
extern "C" {
    fn tj3Init(init_type: libc::c_int) -> tjhandle;
    fn tj3Destroy(h: tjhandle);
    fn tj3Set(h: tjhandle, param: libc::c_int, value: libc::c_int) -> libc::c_int;
    fn tj3Get(h: tjhandle, param: libc::c_int) -> libc::c_int;
    fn tj3DecompressHeader(h: tjhandle, buf: *const u8, size: libc::size_t) -> libc::c_int;
    fn tj3Decompress8(h: tjhandle, buf: *const u8, size: libc::size_t, dst: *mut u8, pitch: libc::c_int, pf: libc::c_int) -> libc::c_int;
    fn tj3Compress8(h: tjhandle, src: *const u8, w: libc::c_int, pitch: libc::c_int, hgt: libc::c_int, pf: libc::c_int, out: *mut *mut u8, size: *mut libc::size_t) -> libc::c_int;
    fn tj3Free(p: *mut libc::c_void);
}
const TJINIT_COMPRESS: i32 = 0;
const TJINIT_DECOMPRESS: i32 = 1;
const TJPARAM_QUALITY: i32 = 3;
const TJPARAM_SUBSAMP: i32 = 4;
const TJPARAM_JPEGWIDTH: i32 = 5;
const TJPARAM_JPEGHEIGHT: i32 = 6;
const TJSAMP_420: i32 = 2;
const TJPF_RGB: i32 = 0;

/// An RGB image, 3 bytes per pixel, rows top to bottom.
#[derive(Clone)]
pub struct Rgb {
    pub w: usize,
    pub h: usize,
    pub px: Vec<u8>,
}

pub fn decode_jpeg(data: &[u8]) -> Option<Rgb> {
    if !data.starts_with(&[0xff, 0xd8]) {
        return None;
    }
    unsafe {
        let h = tj3Init(TJINIT_DECOMPRESS);
        if h.is_null() {
            return None;
        }
        let r = (|| {
            if tj3DecompressHeader(h, data.as_ptr(), data.len()) != 0 {
                return None;
            }
            let (w, hh) = (tj3Get(h, TJPARAM_JPEGWIDTH) as usize, tj3Get(h, TJPARAM_JPEGHEIGHT) as usize);
            let mut px = vec![0u8; w * hh * 3];
            if tj3Decompress8(h, data.as_ptr(), data.len(), px.as_mut_ptr(), 0, TJPF_RGB) != 0 {
                return None;
            }
            Some(Rgb { w, h: hh, px })
        })();
        tj3Destroy(h);
        r
    }
}

pub fn encode_jpeg(im: &Rgb, quality: i32) -> Option<Vec<u8>> {
    unsafe {
        let h = tj3Init(TJINIT_COMPRESS);
        if h.is_null() {
            return None;
        }
        tj3Set(h, TJPARAM_QUALITY, quality);
        tj3Set(h, TJPARAM_SUBSAMP, TJSAMP_420);
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut size: libc::size_t = 0;
        let rc = tj3Compress8(h, im.px.as_ptr(), im.w as i32, 0, im.h as i32, TJPF_RGB, &mut out, &mut size);
        let r = if rc == 0 && !out.is_null() { Some(std::slice::from_raw_parts(out, size).to_vec()) } else { None };
        if !out.is_null() {
            tj3Free(out as *mut libc::c_void);
        }
        tj3Destroy(h);
        r
    }
}

// ---------------------------------------------------------------- Pillow's Resample.c / Reduce.c
const PRECISION_BITS: u32 = 32 - 8 - 2;

#[derive(Clone, Copy)]
pub enum Filter {
    Bicubic,
    Lanczos,
}

impl Filter {
    fn support(self) -> f64 {
        match self {
            Filter::Bicubic => 2.0,
            Filter::Lanczos => 3.0,
        }
    }
    fn f(self, x: f64) -> f64 {
        match self {
            Filter::Bicubic => {
                let a = -0.5;
                let x = x.abs();
                if x < 1.0 {
                    ((a + 2.0) * x - (a + 3.0)) * x * x + 1.0
                } else if x < 2.0 {
                    (((x - 5.0) * x + 8.0) * x - 4.0) * a
                } else {
                    0.0
                }
            }
            Filter::Lanczos => {
                fn sinc(x: f64) -> f64 {
                    if x == 0.0 {
                        return 1.0;
                    }
                    let x = x * std::f64::consts::PI;
                    pymath::sin(x) / x
                }
                if (-3.0..3.0).contains(&x) { sinc(x) * sinc(x / 3.0) } else { 0.0 }
            }
        }
    }
}

/// precompute_coeffs + normalize_coeffs_8bpc -> (ksize, bounds [xmin, xmax], fixed-point kk)
fn coeffs(in_size: usize, in0: f32, in1: f32, out_size: usize, filt: Filter) -> (usize, Vec<(usize, usize)>, Vec<i32>) {
    let scale = (in1 - in0) as f64 / out_size as f64;
    let filterscale = scale.max(1.0);
    let support = filt.support() * filterscale;
    let ksize = support.ceil() as usize * 2 + 1;
    let mut kk = vec![0f64; out_size * ksize];
    let mut bounds = vec![(0, 0); out_size];
    for xx in 0..out_size {
        let center = in0 as f64 + (xx as f64 + 0.5) * scale;
        let mut ww = 0.0;
        let ss = 1.0 / filterscale;
        let xmin = ((center - support + 0.5) as i64).max(0);
        let xmax = ((center + support + 0.5) as i64).min(in_size as i64) - xmin;
        let k = &mut kk[xx * ksize..(xx + 1) * ksize];
        for x in 0..xmax.max(0) as usize {
            let w = filt.f((x as f64 + xmin as f64 - center + 0.5) * ss);
            k[x] = w;
            ww += w;
        }
        for x in 0..xmax.max(0) as usize {
            if ww != 0.0 {
                k[x] /= ww;
            }
        }
        bounds[xx] = (xmin as usize, xmax.max(0) as usize);
    }
    let one = (1u32 << PRECISION_BITS) as f64;
    let fixed = kk.iter().map(|&p| if p < 0.0 { (-0.5 + p * one) as i32 } else { (0.5 + p * one) as i32 }).collect();
    (ksize, bounds, fixed)
}

fn clip8(v: i32) -> u8 {
    if v >= (1 << PRECISION_BITS << 8) {
        255
    } else if v <= 0 {
        0
    } else {
        (v >> PRECISION_BITS) as u8
    }
}

/// Image.resize(size, filter, box) (ImagingResample, 8 bits per channel)
pub fn resample(im: &Rgb, w: usize, h: usize, filt: Filter, bx: [f32; 4]) -> Rgb {
    if im.w == w && im.h == h && bx == [0.0, 0.0, w as f32, h as f32] {
        return im.clone();
    }
    let need_h = w != im.w || bx[0] != 0.0 || bx[2] != w as f32;
    let need_v = h != im.h || bx[1] != 0.0 || bx[3] != h as f32;
    let (kh, bh, kkh) = coeffs(im.w, bx[0], bx[2], w, filt);
    let (kv, mut bv, kkv) = coeffs(im.h, bx[1], bx[3], h, filt);
    let ybox_first = bv[0].0;
    let ybox_last = bv[h - 1].0 + bv[h - 1].1;
    let mut cur = im.clone();
    if need_h {
        for b in bv.iter_mut() {
            b.0 -= ybox_first;
        }
        let rows = ybox_last - ybox_first;
        let mut out = vec![0u8; w * rows * 3];
        for yy in 0..rows {
            let src = &im.px[(yy + ybox_first) * im.w * 3..];
            for xx in 0..w {
                let (xmin, xmax) = bh[xx];
                let k = &kkh[xx * kh..];
                let mut ss = [1i32 << (PRECISION_BITS - 1); 3];
                for x in 0..xmax {
                    for c in 0..3 {
                        ss[c] = ss[c].wrapping_add((src[(x + xmin) * 3 + c] as i32).wrapping_mul(k[x]));
                    }
                }
                for c in 0..3 {
                    out[(yy * w + xx) * 3 + c] = clip8(ss[c]);
                }
            }
        }
        cur = Rgb { w, h: rows, px: out };
    }
    if need_v {
        let mut out = vec![0u8; cur.w * h * 3];
        for yy in 0..h {
            let (ymin, ymax) = bv[yy];
            let k = &kkv[yy * kv..];
            for xx in 0..cur.w {
                let mut ss = [1i32 << (PRECISION_BITS - 1); 3];
                for y in 0..ymax {
                    for c in 0..3 {
                        ss[c] = ss[c].wrapping_add((cur.px[((y + ymin) * cur.w + xx) * 3 + c] as i32).wrapping_mul(k[y]));
                    }
                }
                for c in 0..3 {
                    out[(yy * cur.w + xx) * 3 + c] = clip8(ss[c]);
                }
            }
        }
        cur = Rgb { w: cur.w, h, px: out };
    }
    cur
}

/// division_UINT32(divider, 8): computed in float like Reduce.c
fn multiplier(divider: u32) -> u32 {
    let max_dividend = (1u32 << 8) * divider;
    let max_int: f32 = (1u32 << 30) as f32 * 4.0;
    (max_int / max_dividend as f32) as u32
}

/// Image.reduce((fx, fy), box) (ImagingReduce: box averages; the edge blocks by their own size)
pub fn reduce(im: &Rgb, fx: usize, fy: usize, bx: [usize; 4]) -> Rgb {
    let (x0, y0, bw, bh) = (bx[0], bx[1], bx[2] - bx[0], bx[3] - bx[1]);
    let (ow, oh) = (bw.div_ceil(fx), bh.div_ceil(fy));
    let mut out = vec![0u8; ow * oh * 3];
    let mut block = |ox: usize, oy: usize, xs: std::ops::Range<usize>, ys: std::ops::Range<usize>| {
        let scale = (xs.len() * ys.len()) as u32;
        let (mul, amend) = (multiplier(scale), scale / 2);
        let mut ss = [amend; 3];
        for y in ys {
            for x in xs.clone() {
                for c in 0..3 {
                    ss[c] += im.px[(y * im.w + x) * 3 + c] as u32;
                }
            }
        }
        for c in 0..3 {
            out[(oy * ow + ox) * 3 + c] = (ss[c].wrapping_mul(mul) >> 24) as u8;
        }
    };
    for oy in 0..oh {
        let ys = y0 + oy * fy..(y0 + (oy + 1) * fy).min(y0 + bh);
        for ox in 0..ow {
            let xs = x0 + ox * fx..(x0 + (ox + 1) * fx).min(x0 + bw);
            block(ox, oy, xs, ys.clone());
        }
    }
    Rgb { w: ow, h: oh, px: out }
}

/// Image.thumbnail((SIZE, SIZE), LANCZOS) on an in-memory (non-draft) RGB image
pub fn thumbnail(im: &Rgb) -> Rgb {
    let (x, y) = (SIZE, SIZE);
    if x >= im.w && y >= im.h {
        return im.clone();
    }
    let aspect = im.w as f64 / im.h as f64;
    let round_aspect = |n: f64, key: &dyn Fn(f64) -> f64| -> usize {
        let (fl, ce) = (n.floor(), n.ceil());
        let pick = if key(ce) < key(fl) { ce } else { fl }; // min() keeps the first on ties
        (pick as i64).max(1) as usize
    };
    let (tw, th) = if x as f64 / y as f64 >= aspect {
        (round_aspect(y as f64 * aspect, &|n| (aspect - n / y as f64).abs()), y)
    } else {
        (x, round_aspect(x as f64 / aspect, &|n| if n == 0.0 { 0.0 } else { (aspect - x as f64 / n).abs() }))
    };
    if (tw, th) == (im.w, im.h) {
        return im.clone();
    }
    // resize(final, LANCZOS, reducing_gap=2.0)
    let reducing_gap = 2.0;
    let bx = [0.0f64, 0.0, im.w as f64, im.h as f64];
    let factor_x = (((bx[2] - bx[0]) / tw as f64 / reducing_gap) as usize).max(1);
    let factor_y = (((bx[3] - bx[1]) / th as f64 / reducing_gap) as usize).max(1);
    let (src, fbox) = if factor_x > 1 || factor_y > 1 {
        // _get_safe_box
        let support = Filter::Lanczos.support() - 0.5;
        let sx = support * ((bx[2] - bx[0]) / tw as f64);
        let sy = support * ((bx[3] - bx[1]) / th as f64);
        let rb = [
            ((bx[0] - sx) as i64).max(0) as usize,
            ((bx[1] - sy) as i64).max(0) as usize,
            (im.w as f64).min((bx[2] + sx).ceil()) as usize,
            (im.h as f64).min((bx[3] + sy).ceil()) as usize,
        ];
        let r = if (factor_x, factor_y) == (1, 1) && rb == [0, 0, im.w, im.h] { im.clone() } else { reduce(im, factor_x, factor_y, rb) };
        let nb = [
            ((bx[0] - rb[0] as f64) / factor_x as f64) as f32,
            ((bx[1] - rb[1] as f64) / factor_y as f64) as f32,
            ((bx[2] - rb[0] as f64) / factor_x as f64) as f32,
            ((bx[3] - rb[1] as f64) / factor_y as f64) as f32,
        ];
        (r, nb)
    } else {
        (im.clone(), [0.0, 0.0, im.w as f32, im.h as f32])
    };
    resample(&src, tw, th, Filter::Lanczos, fbox)
}

// ---------------------------------------------------------------- colours (Python's colorsys)
fn pymod1(x: f64) -> f64 {
    // x % 1.0
    let m = x % 1.0;
    if m != 0.0 {
        if m < 0.0 { m + 1.0 } else { m }
    } else {
        0.0f64.copysign(1.0)
    }
}

fn rgb_to_hsv(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let rangec = maxc - minc;
    let v = maxc;
    if minc == maxc {
        return (0.0, 0.0, v);
    }
    let s = rangec / maxc;
    let rc = (maxc - r) / rangec;
    let gc = (maxc - g) / rangec;
    let bc = (maxc - b) / rangec;
    let h = if r == maxc { bc - gc } else if g == maxc { 2.0 + rc - bc } else { 4.0 + gc - rc };
    (pymod1(h / 6.0), s, v)
}

fn rgb_to_hls(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let sumc = maxc + minc;
    let rangec = maxc - minc;
    let l = sumc / 2.0;
    if minc == maxc {
        return (0.0, l, 0.0);
    }
    let s = if l <= 0.5 { rangec / sumc } else { rangec / (2.0 - maxc - minc) };
    let rc = (maxc - r) / rangec;
    let gc = (maxc - g) / rangec;
    let bc = (maxc - b) / rangec;
    let h = if r == maxc { bc - gc } else if g == maxc { 2.0 + rc - bc } else { 4.0 + gc - rc };
    (pymod1(h / 6.0), l, s)
}

fn hls_to_rgb(h: f64, l: f64, s: f64) -> (f64, f64, f64) {
    if s == 0.0 {
        return (l, l, l);
    }
    let m2 = if l <= 0.5 { l * (1.0 + s) } else { l + s - (l * s) };
    let m1 = 2.0 * l - m2;
    let v = |hue: f64| {
        let hue = pymod1(hue);
        if hue < 1.0 / 6.0 {
            m1 + (m2 - m1) * hue * 6.0
        } else if hue < 0.5 {
            m2
        } else if hue < 2.0 / 3.0 {
            m1 + (m2 - m1) * (2.0 / 3.0 - hue) * 6.0
        } else {
            m1
        }
    };
    (v(h + 1.0 / 3.0), v(h), v(h - 1.0 / 3.0))
}

fn hex(r: f64, g: f64, b: f64) -> String {
    let c = |x: f64| pyjson::round_i(x * 255.0);
    format!("#{:02x}{:02x}{:02x}", c(r), c(g), c(b))
}

/// A pleasant accent colour: saturation/brightness-weighted average of a tiny copy.
pub fn dominant(im: &Rgb) -> String {
    let small = resample(im, 24, 24, Filter::Bicubic, [0.0, 0.0, im.w as f32, im.h as f32]);
    let mut tot = [0.0f64; 3];
    let mut wsum = 0.0;
    for p in small.px.chunks_exact(3) {
        let (r, g, b) = (p[0] as f64, p[1] as f64, p[2] as f64);
        let (_, s, v) = rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0);
        let w = pymath::pow(s, 1.5) * pymath::pow(v, 0.8) + 0.02;
        tot[0] += r * w;
        tot[1] += g * w;
        tot[2] += b * w;
        wsum += w;
    }
    let (r, g, b) = (tot[0] / wsum / 255.0, tot[1] / wsum / 255.0, tot[2] / wsum / 255.0);
    let (h, l, s) = rgb_to_hls(r, g, b);
    let l = 0.62f64.min(0.38f64.max(l));
    let s = 0.85f64.min(s * 1.25);
    let (r, g, b) = hls_to_rgb(h, l, s);
    hex(r, g, b)
}

pub fn hash_colour(key: &str) -> String {
    let d = format!("{:x}", md5::compute(key.as_bytes()));
    let h = i64::from_str_radix(&d[..6], 16).unwrap() as f64 / 0xFFFFFF as f64;
    let (r, g, b) = hls_to_rgb(h, 0.5, 0.5);
    hex(r, g, b)
}

// ---------------------------------------------------------------- the worker
struct State {
    index: Map<String, Value>,
    todo: Vec<(String, String)>,
    pending: std::collections::HashSet<String>,
}

pub struct Thumbs {
    dir: String,
    index_path: String,
    st: Mutex<State>,
    cv: Condvar,
    emit: Box<dyn Fn(Value) + Send + Sync>,
}

impl Thumbs {
    pub fn new(cache_dir: &str, emit: Box<dyn Fn(Value) + Send + Sync>) -> Arc<Thumbs> {
        let dir = format!("{cache_dir}/thumbs");
        let _ = std::fs::create_dir_all(&dir);
        let index_path = format!("{dir}/index.json");
        let index = std::fs::read_to_string(&index_path)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default();
        let t = Arc::new(Thumbs { dir, index_path, st: Mutex::new(State { index, todo: vec![], pending: Default::default() }), cv: Condvar::new(), emit });
        let me = t.clone();
        std::thread::Builder::new().name("thumbs".into()).spawn(move || me.run()).ok();
        t
    }

    /// Cached entries that are still valid, for the initial library message.
    pub fn known(&self, albums: &[Value]) -> Value {
        let st = self.st.lock().unwrap();
        let mut out = Map::new();
        for a in albums {
            let k = a["k"].as_str().unwrap_or("");
            let c = a["c"].as_str().unwrap_or("");
            if let Some(e) = st.index.get(k) {
                let p = e["p"].as_str().unwrap_or("");
                if !c.is_empty() && pystr::exists(p) {
                    if let Some(mt) = pystr::mtime(c) {
                        if (mt - e["mt"].as_f64().unwrap_or(f64::NAN)).abs() < 1.0 {
                            out.insert(k.to_string(), json!({"p": e["p"], "c": e["c"]}));
                        }
                    }
                }
            }
        }
        Value::Object(out)
    }

    /// items: [(album key, cover path)]
    pub fn request(&self, items: Vec<(String, String)>) {
        let mut st = self.st.lock().unwrap();
        for (k, src) in items {
            if st.pending.contains(&k) || src.is_empty() {
                continue;
            }
            st.pending.insert(k.clone());
            st.todo.push((k, src));
        }
        self.cv.notify_one();
    }

    fn run(self: Arc<Self>) {
        unsafe {
            *libc::__errno_location() = 0;
            libc::nice(5);
        }
        loop {
            let batch: Vec<(String, String)> = {
                let mut st = self.st.lock().unwrap();
                while st.todo.is_empty() {
                    st = self.cv.wait(st).unwrap();
                }
                let n = st.todo.len().min(24);
                st.todo.drain(..n).collect()
            };
            let mut out = Map::new();
            for (k, src) in &batch {
                let r = self.make(k, src).unwrap_or_else(|| json!({"p": src, "c": hash_colour(k)}));
                out.insert(k.clone(), r);
            }
            {
                let mut st = self.st.lock().unwrap();
                for (k, _) in &batch {
                    st.pending.remove(k);
                }
                let tmp = format!("{}.tmp", self.index_path);
                if std::fs::write(&tmp, pyjson::dumps(&Value::Object(st.index.clone()), false)).is_ok() {
                    let _ = std::fs::rename(&tmp, &self.index_path);
                }
            }
            (self.emit)(json!({"type": "thumbs", "items": out}));
        }
    }

    fn make(&self, key: &str, src: &str) -> Option<Value> {
        let mt = pystr::mtime(src)?;
        {
            let st = self.st.lock().unwrap();
            if let Some(e) = st.index.get(key) {
                let p = e["p"].as_str().unwrap_or("");
                if (e["mt"].as_f64().unwrap_or(f64::NAN) - mt).abs() < 1.0 && pystr::exists(p) {
                    return Some(json!({"p": e["p"], "c": e["c"]}));
                }
            }
        }
        let data = std::fs::read(src).ok()?;
        let im = decode_jpeg(&data)?;
        let col = dominant(&im);
        let th = thumbnail(&im);
        let dst = format!("{}/{}.jpg", self.dir, sha1_smol::Sha1::from(key.as_bytes()).digest());
        let jpg = encode_jpeg(&th, 88)?;
        std::fs::write(format!("{dst}.tmp"), jpg).ok()?;
        std::fs::rename(format!("{dst}.tmp"), &dst).ok()?;
        let res = json!({"p": dst, "c": col});
        let mut e = res.as_object().unwrap().clone();
        e.insert("mt".into(), pyjson::f(mt));
        self.st.lock().unwrap().index.insert(key.to_string(), Value::Object(e));
        Some(res)
    }
}

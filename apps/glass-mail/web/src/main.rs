//! glass-mail-web: renders HTML mails for Glass Mail's reader.
//!
//! quickshell can't host a WebEngineView (Chromium refuses its empty argv), so the reader shows
//! a picture of the mail instead: this helper lays the page out in an offscreen WebKitGTK view
//! and writes a PNG plus the boxes of its links. The backend (`web` op) keeps one of these
//! running and talks JSON lines over stdin/stdout:
//!
//!   in : {"id": 1, "html": "<html>…", "width": 720, "zoom": 1.5, "out": "/path/x.png"}
//!   out: {"id": 1, "ok": true, "w": 720, "h": 1830, "paper": true, "links": [[x, y, w, h, "https://…"], …]}
//!
//! Sizes are CSS px; the PNG is zoom× larger so it stays sharp on a scaled output. Safety: page
//! scripts are off (only this helper's own measuring script runs), every navigation except the
//! initial load is refused, storage is ephemeral, and what may load is set by the page's CSP
//! (the backend allows remote images only when the user asked for them).

use std::cell::RefCell;
use std::collections::VecDeque;
use std::io::{BufRead, Write};
use std::rc::Rc;
use std::time::Duration;

use gtk::glib;
use gtk::prelude::*;
use serde_json::{json, Value};
use javascriptcore::ValueExt;
use webkit2gtk::{
    LoadEvent, PolicyDecisionExt, PolicyDecisionType, SettingsExt, SnapshotOptions, SnapshotRegion, WebContext, WebContextExt,
    WebView, WebViewExt, WebsiteDataManager,
};

/// Largest PNG side cairo can write; longer mails are cut (the reader offers "Open in browser").
const MAX_PX: f64 = 32000.0;

/// Measures the page, decides whether it brings its own backgrounds (a designed newsletter:
/// shown on white paper) or is plain prose (blends into the glass), and lists link boxes.
const MEASURE_JS: &str = r#"
(function () {
  const d = document, de = d.documentElement;
  let paper = !!d.querySelector('[bgcolor],[background]');
  if (!paper) {
    const all = d.body ? d.body.getElementsByTagName('*') : [];
    const n = Math.min(all.length, 4000);
    for (let i = 0; i < n && !paper; i++) {
      const cs = getComputedStyle(all[i]);
      const bg = cs.backgroundColor;
      if ((bg && bg !== 'transparent' && !/rgba\(.*,\s*0\)$/.test(bg)) || cs.backgroundImage !== 'none') {
        const r = all[i].getBoundingClientRect();
        if (r.width * r.height > 2500) paper = true;
      }
    }
    if (d.body) {
      const bb = getComputedStyle(d.body).backgroundColor;
      if (bb && bb !== 'transparent' && !/rgba\(.*,\s*0\)$/.test(bb)) paper = true;
    }
  }
  if (paper) de.classList.add('gm-paper');
  const links = [];
  for (const a of d.querySelectorAll('a[href]')) {
    const href = a.href;
    if (!/^(https?:|mailto:)/i.test(href)) continue;
    for (const r of a.getClientRects()) {
      if (r.width > 0 && r.height > 0)
        links.push([r.left + scrollX, r.top + scrollY, r.width, r.height, href]);
    }
  }
  return JSON.stringify({ paper: paper, links: links,
    h: Math.max(de.scrollHeight, d.body ? d.body.scrollHeight : 0),
    w: Math.max(de.scrollWidth, d.body ? d.body.scrollWidth : 0), vw: innerWidth });
})()
"#;

struct Job {
    id: Value,
    html: String,
    width: f64,
    zoom: f64,
    out: String,
}

struct State {
    view: WebView,
    queue: VecDeque<Job>,
    busy: Option<Job>,
    /// set while our own load_html() is starting, so that one navigation is let through
    allow_nav: bool,
    generation: u64,
    /// snapshot px per (CSS px × zoom level)
    ratio: f64,
    ratio_known: bool,
}

fn reply(v: Value) {
    let mut o = std::io::stdout().lock();
    let _ = writeln!(o, "{v}");
    let _ = o.flush();
}

fn fail(job: &Job, why: &str) {
    reply(json!({"id": job.id, "ok": false, "error": why}));
}

fn start_next(st: &Rc<RefCell<State>>) {
    let (view, html, width, zoom, generation) = {
        let mut s = st.borrow_mut();
        if s.busy.is_some() {
            return;
        }
        // only the newest request matters: the reader moved on from the older ones
        while s.queue.len() > 1 {
            let old = s.queue.pop_front().unwrap();
            fail(&old, "superseded");
        }
        let Some(job) = s.queue.pop_front() else { return };
        s.generation += 1;
        let r = (s.view.clone(), job.html.clone(), job.width, job.zoom, s.generation);
        s.busy = Some(job);
        s.allow_nav = true;
        r
    };
    // snapshots come out at the display's integer scale (2 on a 1.5× output) whatever the
    // offscreen widget says: zoom so that one CSS px ends up as `zoom` px (`ratio` is learnt
    // from the first snapshot, see snapshot())
    let ratio = st.borrow().ratio;
    view.set_zoom_level(zoom / ratio);
    view.set_size_request((width * zoom / ratio).round() as i32, 200);
    view.load_html(&html, Some("about:blank"));
    // a mail that never finishes loading (slow remote images) still gets drawn
    let st2 = st.clone();
    glib::timeout_add_local_once(Duration::from_secs(12), move || {
        if st2.borrow().generation == generation && st2.borrow().busy.is_some() {
            st2.borrow().view.stop_loading();
            measure(&st2, generation);
        }
    });
}

fn measure(st: &Rc<RefCell<State>>, generation: u64) {
    let view = st.borrow().view.clone();
    let st2 = st.clone();
    view.evaluate_javascript(MEASURE_JS, None, None, None::<&gtk::gio::Cancellable>, move |res| {
        if st2.borrow().generation != generation {
            return;
        }
        let info: Value = match res {
            Ok(v) => serde_json::from_str(&v.to_str()).unwrap_or(Value::Null),
            Err(e) => {
                finish_err(&st2, &format!("measure: {e}"));
                return;
            }
        };
        // let the gm-paper class restyle the page before taking the picture
        let st3 = st2.clone();
        glib::timeout_add_local_once(Duration::from_millis(60), move || snapshot(&st3, generation, info));
    });
}

fn snapshot(st: &Rc<RefCell<State>>, generation: u64, info: Value) {
    let view = st.borrow().view.clone();
    let st2 = st.clone();
    view.snapshot(SnapshotRegion::FullDocument, SnapshotOptions::TRANSPARENT_BACKGROUND, None::<&gtk::gio::Cancellable>, move |res| {
        if st2.borrow().generation != generation {
            return;
        }
        let job = st2.borrow_mut().busy.take();
        let Some(job) = job else { return };
        match res {
            Ok(surface) => {
                let img = match cairo::ImageSurface::try_from(surface) {
                    Ok(i) => i,
                    Err(_) => {
                        fail(&job, "snapshot is not an image");
                        start_next(&st2);
                        return;
                    }
                };
                let (pw, ph) = (img.width() as f64, img.height() as f64);
                let css_w = info["vw"].as_f64().unwrap_or(job.width).max(1.0);
                let factor = pw / css_w;
                if !st2.borrow().ratio_known {
                    // first picture: learn the display scale, redo this one at the right size
                    let zl = st2.borrow().view.zoom_level();
                    let mut s = st2.borrow_mut();
                    s.ratio = (factor / zl).max(0.25);
                    s.ratio_known = true;
                    if (factor - job.zoom).abs() > 0.05 {
                        s.queue.push_front(job);
                        drop(s);
                        start_next(&st2);
                        return;
                    }
                }
                let written = write_png(&img, &job.out, ph);
                match written {
                    Ok(cut) => reply(json!({
                        "id": job.id, "ok": true, "png": job.out,
                        "w": pw / factor, "h": ph.min(MAX_PX) / factor, "scale": factor, "cut": cut,
                        "paper": info["paper"].as_bool().unwrap_or(false),
                        "links": info["links"].clone(),
                    })),
                    Err(e) => fail(&job, &e),
                }
            }
            Err(e) => fail(&job, &format!("snapshot: {e}")),
        }
        start_next(&st2);
    });
}

/// Writes the PNG (cut at MAX_PX tall); returns whether it was cut.
fn write_png(img: &cairo::ImageSurface, path: &str, ph: f64) -> Result<bool, String> {
    let tmp = format!("{path}.part");
    let mut f = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let cut = ph > MAX_PX;
    if cut {
        let part = cairo::ImageSurface::create(cairo::Format::ARgb32, img.width(), MAX_PX as i32).map_err(|e| e.to_string())?;
        let cr = cairo::Context::new(&part).map_err(|e| e.to_string())?;
        cr.set_source_surface(img, 0.0, 0.0).map_err(|e| e.to_string())?;
        cr.paint().map_err(|e| e.to_string())?;
        drop(cr);
        part.write_to_png(&mut f).map_err(|e| e.to_string())?;
    } else {
        img.write_to_png(&mut f).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    Ok(cut)
}

fn finish_err(st: &Rc<RefCell<State>>, why: &str) {
    let job = st.borrow_mut().busy.take();
    if let Some(job) = job {
        fail(&job, why);
    }
    start_next(st);
}

fn main() {
    // no GPU process games in a helper that only takes pictures
    std::env::set_var("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
    std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
    if gtk::init().is_err() {
        reply(json!({"ready": false, "error": "no display"}));
        std::process::exit(1);
    }

    let data = WebsiteDataManager::new_ephemeral();
    let ctx = WebContext::with_website_data_manager(&data);
    ctx.set_cache_model(webkit2gtk::CacheModel::DocumentViewer);
    let view = WebView::with_context(&ctx);
    if let Some(s) = WebViewExt::settings(&view) {
        s.set_enable_javascript(true); // our measuring script only:
        s.set_enable_javascript_markup(false); // <script>, on*= and javascript: in the mail never run
        s.set_auto_load_images(true); // what may load is decided by the page's CSP
        s.set_enable_html5_local_storage(false);
        s.set_enable_html5_database(false);
        s.set_enable_page_cache(false);
        s.set_enable_webaudio(false);
        s.set_enable_webgl(false);
        s.set_enable_media(false);
        s.set_media_playback_requires_user_gesture(true);
        s.set_javascript_can_open_windows_automatically(false);
        s.set_enable_developer_extras(false);
    }
    view.set_background_color(&gtk::gdk::RGBA::new(0.0, 0.0, 0.0, 0.0));

    let win = gtk::OffscreenWindow::new();
    win.add(&view);
    win.show_all();

    let st = Rc::new(RefCell::new(State { view: view.clone(), queue: VecDeque::new(), busy: None, allow_nav: false, generation: 0, ratio: 1.0, ratio_known: false }));

    // refuse every navigation but our own load (links are handled by the reader, not here)
    {
        let st = st.clone();
        view.connect_decide_policy(move |_, decision, kind| {
            match kind {
                PolicyDecisionType::NavigationAction => {
                    let mut s = st.borrow_mut();
                    if s.allow_nav {
                        s.allow_nav = false;
                        decision.use_();
                    } else {
                        decision.ignore();
                    }
                }
                PolicyDecisionType::NewWindowAction => decision.ignore(),
                _ => decision.use_(),
            }
            true
        });
    }
    {
        let st = st.clone();
        view.connect_load_changed(move |_, ev| {
            if ev == LoadEvent::Finished {
                let generation = st.borrow().generation;
                if st.borrow().busy.is_some() {
                    measure(&st, generation);
                }
            }
        });
    }
    {
        let st = st.clone();
        view.connect_load_failed(move |_, _, uri, err| {
            // a refused sub-navigation also lands here; only a failed main load matters
            if uri == "about:blank" {
                finish_err(&st, &format!("load: {err}"));
            }
            true
        });
    }

    // stdin -> main loop; EOF (the backend went away) ends the helper
    let (tx, rx) = std::sync::mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(l) => {
                    if tx.send(Some(l)).is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(None);
    });
    {
        let st = st.clone();
        glib::timeout_add_local(Duration::from_millis(15), move || {
            while let Ok(msg) = rx.try_recv() {
                let Some(line) = msg else {
                    gtk::main_quit();
                    return glib::ControlFlow::Break;
                };
                let v: Value = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let job = Job {
                    id: v["id"].clone(),
                    html: v["html"].as_str().unwrap_or("").to_string(),
                    width: v["width"].as_f64().unwrap_or(720.0).clamp(200.0, 2400.0),
                    zoom: v["zoom"].as_f64().unwrap_or(1.0).clamp(0.5, 4.0),
                    out: v["out"].as_str().unwrap_or("").to_string(),
                };
                if job.out.is_empty() {
                    fail(&job, "no output path");
                    continue;
                }
                st.borrow_mut().queue.push_back(job);
            }
            start_next(&st);
            glib::ControlFlow::Continue
        });
    }

    reply(json!({"ready": true}));
    gtk::main();
}

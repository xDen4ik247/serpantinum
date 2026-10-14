//! Removing songs from disk (port of removal.py). Library songs go to the desktop Trash
//! (`gio trash`, restorable) together with their .lrc / .txt; temp-cache songs are deleted. An album
//! folder left without audio loses its cover and goes too, and so does an artist folder left empty.
use crate::pystr;

const AUDIO: [&str; 6] = [".m4a", ".flac", ".mp3", ".ogg", ".opus", ".wav"];
const SIDECARS: [&str; 2] = [".lrc", ".txt"];
const COVERS: [&str; 4] = ["cover.jpg", "cover.png", "folder.jpg", "folder.png"];

/// True if path (resolved) lies strictly inside one of roots.
pub fn inside(path: &str, roots: &[&str]) -> bool {
    let p = pystr::realpath(path);
    roots.iter().any(|r| !r.is_empty() && p.starts_with(&format!("{}/", pystr::realpath(r).trim_end_matches('/'))))
}

fn which(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| {
        std::env::split_paths(&p).any(|d| {
            use std::os::unix::fs::PermissionsExt;
            std::fs::metadata(d.join(name)).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
    })
}

fn discard(path: &str, trash: bool) -> bool {
    if !pystr::lexists(path) {
        return true;
    }
    if trash && which("gio") {
        let ok = std::process::Command::new("gio")
            .args(["trash", "--", path])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if ok {
            return true;
        }
    }
    if pystr::isdir(path) && !pystr::islink(path) {
        std::fs::remove_dir_all(path).is_ok()
    } else {
        std::fs::remove_file(path).is_ok()
    }
}

fn is_audio(n: &str) -> bool {
    let l = pystr::lower(n);
    AUDIO.iter().any(|e| l.ends_with(e))
}

/// Remove the audio files `paths` (absolute) that lie inside `roots`; files inside `trash_roots`
/// go to the Trash. -> (removed, failed, folders to rescan)
pub fn remove(paths: &[String], roots: &[&str], trash_roots: &[&str]) -> (Vec<String>, Vec<String>, Vec<String>) {
    let (mut removed, mut failed) = (vec![], vec![]);
    let mut rescan = std::collections::BTreeSet::new();
    for p in paths {
        if !is_audio(p) || !inside(p, roots) || !pystr::isfile(p) {
            failed.push(p.clone());
            continue;
        }
        let trash = inside(p, trash_roots);
        let stem = pystr::splitext(p).0.to_string();
        if !discard(p, trash) {
            failed.push(p.clone());
            continue;
        }
        removed.push(p.clone());
        for ext in SIDECARS {
            discard(&format!("{stem}{ext}"), trash);
        }
        let mut d = pystr::dirname(p).to_string();
        let mut top = d.clone();
        let root = roots.iter().find(|r| inside(p, &[r])).map(|r| pystr::realpath(r)).unwrap_or_default();
        // album folder without audio: covers + folder go; then an empty artist folder
        while pystr::realpath(&d) != root && pystr::isdir(&d) {
            let names: Vec<String> = match std::fs::read_dir(&d) {
                Ok(rd) => rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect(),
                Err(_) => break,
            };
            if names.iter().any(|n| is_audio(n) || pystr::isdir(&pystr::join(&d, n))) {
                break;
            }
            if names.iter().any(|n| !COVERS.contains(&pystr::lower(n).as_str()) && !n.starts_with(".yandex-music-downloader.")) {
                break;
            }
            for n in &names {
                discard(&pystr::join(&d, n), trash);
            }
            if std::fs::remove_dir(&d).is_err() {
                break;
            }
            top = d.clone();
            d = pystr::dirname(&d).to_string();
        }
        rescan.insert(top);
    }
    (removed, failed, rescan.into_iter().collect())
}

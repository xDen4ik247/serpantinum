//! Where Glass Mail keeps things (port of paths.py). Every path can be moved with an environment
//! variable (tests).
use std::path::PathBuf;

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

fn env_or(var: &str, default: PathBuf) -> PathBuf {
    match std::env::var_os(var) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => default,
    }
}

pub fn config() -> PathBuf {
    env_or("GLASS_MAIL_CONFIG", home().join(".config/glass-mail"))
}
pub fn cache() -> PathBuf {
    env_or("GLASS_MAIL_CACHE", home().join(".cache/glass-mail"))
}
pub fn state() -> PathBuf {
    env_or("GLASS_MAIL_STATE", home().join(".local/state/glass-mail"))
}
pub fn downloads() -> PathBuf {
    env_or("GLASS_MAIL_DOWNLOADS", home().join("Downloads"))
}
pub fn accounts() -> PathBuf {
    config().join("accounts.json")
}
pub fn settings() -> PathBuf {
    config().join("settings.json")
}
pub fn db() -> PathBuf {
    cache().join("mail.db")
}
pub fn bodies() -> PathBuf {
    cache().join("bodies")
}
pub fn images() -> PathBuf {
    cache().join("images")
}
pub fn opened() -> PathBuf {
    cache().join("open")
}
pub fn unread() -> PathBuf {
    state().join("unread.json")
}
pub fn drafts() -> PathBuf {
    state().join("drafts")
}

pub fn ensure() {
    for d in [config(), cache(), state(), bodies(), images(), opened(), drafts()] {
        let _ = std::fs::create_dir_all(d);
    }
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(config(), std::fs::Permissions::from_mode(0o700));
}

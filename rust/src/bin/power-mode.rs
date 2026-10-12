//! power-mode — one battery-aware switch for the desktop (Rust port of the bash power-mode).
//!
//!   power-mode                 show the current state
//!   power-mode auto            follow the charger: "save" on battery, "perf" on AC (default)
//!   power-mode save | perf     force one policy regardless of the charger
//!   power-mode apply           re-apply the policy now (the daemon does this on every AC change)
//!   power-mode daemon          (power-mode.service) apply, then re-apply whenever UPower's OnBattery flips
//!
//! What a policy flips (all values in ~/.config/power-mode.conf, KEY=VALUE lines):
//!   - eDP-1 refresh rate: PERF_REFRESH / SAVE_REFRESH (both 120 Hz by default). Applied transiently
//!     through niri's socket; niri config files are never edited.
//!   - power-profiles-daemon profile: balanced (perf) / power-saver (save)
//!   - gcal-sync timer every minute (perf) / every 5 min (save); anki-queue-flush every 5 min / hourly
//!     (runtime drop-ins in $XDG_RUNTIME_DIR/systemd/user/*.timer.d/power-mode.conf, gone after reboot)
//!   - local LLM idle stop: 30 min (perf) / 10 min (save)  -> ~/.local/state/power-mode/llm.env
//!   - Serpantinum reads ~/.local/state/power-mode/mode + UPower itself (PowerSaver singleton).
//! It never touches fcitx5.service.
//!
//! The daemon listens to UPower's PropertiesChanged on the system bus itself (the bash version ran
//! `gdbus monitor` piped into a bash loop: three processes).
use dbus::blocking::Connection;
use dbus::channel::Channel;
use glass::niri;
use glass::util;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

struct Conf(HashMap<String, String>);

impl Conf {
    fn load(path: &Path) -> Conf {
        let mut m: HashMap<String, String> = [
            ("OUTPUT", "eDP-1"),
            ("PERF_REFRESH", "120.000"),
            ("SAVE_REFRESH", "120.000"),
            ("PERF_PROFILE", "balanced"),
            ("SAVE_PROFILE", "power-saver"),
            ("SAVE_GCAL_ONCALENDAR", "*:0/5:05"),
            ("SAVE_ANKI_INTERVAL", "60min"),
            ("ANKI_ON_BOOT", "2min"), // the drop-in's empty OnUnitActiveSec= clears every monotonic trigger
            ("PERF_LLM_IDLE", "30min"),
            ("SAVE_LLM_IDLE", "10min"),
            ("SWITCH_REFRESH", "1"),
            ("SWITCH_PROFILE", "1"),
            ("SWITCH_TIMERS", "1"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        for line in fs::read_to_string(path).unwrap_or_default().lines() {
            if let Some((k, v)) = parse_assignment(line) {
                m.insert(k, v);
            }
        }
        Conf(m)
    }
    fn get(&self, k: &str) -> &str {
        self.0.get(k).map(String::as_str).unwrap_or("")
    }
    fn on(&self, k: &str) -> bool {
        self.get(k) == "1"
    }
}

/// `KEY=value`, `KEY='value'`, `KEY="value"`, with an optional trailing `# comment` (shell rules, no expansion).
fn parse_assignment(line: &str) -> Option<(String, String)> {
    let line = line.trim_start();
    if line.starts_with('#') {
        return None;
    }
    let (k, rest) = line.split_once('=')?;
    if k.is_empty() || !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    let mut v = String::new();
    let mut chars = rest.chars().peekable();
    while let Some(&c) = chars.peek() {
        match c {
            '\'' => {
                chars.next();
                for c in chars.by_ref() {
                    if c == '\'' {
                        break;
                    }
                    v.push(c);
                }
            }
            '"' => {
                chars.next();
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => v.extend(chars.next()),
                        _ => v.push(c),
                    }
                }
            }
            c if c.is_whitespace() => break,
            '\\' => {
                chars.next();
                v.extend(chars.next());
            }
            _ => {
                v.push(c);
                chars.next();
            }
        }
    }
    Some((k.to_string(), v))
}

struct Pm {
    conf: Conf,
    state_dir: PathBuf,
    runtime_units: PathBuf,
    quiet: bool,
}

fn read_strip(p: &Path) -> Option<String> {
    // like "$(cat file)": trailing newlines removed
    fs::read_to_string(p).ok().map(|s| s.trim_end_matches('\n').to_string())
}

fn sh_ok(cmd: &[&str]) -> bool {
    Command::new(cmd[0]).args(&cmd[1..]).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status().is_ok_and(|s| s.success())
}

fn sh_out(cmd: &[&str]) -> String {
    Command::new(cmd[0])
        .args(&cmd[1..])
        .stderr(std::process::Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim_end_matches('\n').to_string())
        .unwrap_or_default()
}

fn on_path(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(name).is_file()))
}

fn system_bus() -> Option<Connection> {
    Channel::get_private(dbus::channel::BusType::System).ok().map(|mut ch| {
        ch.set_watch_enabled(true);
        Connection::from(ch)
    })
}

/// UPower's OnBattery; without UPower: battery unless a mains supply is online.
fn on_battery() -> bool {
    if let Some(c) = system_bus() {
        use dbus::blocking::stdintf::org_freedesktop_dbus::Properties;
        let p = c.with_proxy("org.freedesktop.UPower", "/org/freedesktop/UPower", Duration::from_secs(5));
        if let Ok(v) = p.get::<bool>("org.freedesktop.UPower", "OnBattery") {
            return v;
        }
    }
    let Ok(rd) = fs::read_dir("/sys/class/power_supply") else { return true };
    for e in rd.flatten() {
        if util::read_trim(e.path().join("type")).as_deref() == Some("Mains") && util::read_trim(e.path().join("online")).as_deref() == Some("1") {
            return false;
        }
    }
    true
}

fn fmt_mode(m: &Value) -> String {
    format!("{}x{}@{:.3}", m["width"], m["height"], m["refresh_rate"].as_f64().unwrap_or(0.0) / 1000.0)
}

impl Pm {
    fn log(&self, s: &str) {
        if !self.quiet {
            println!("{s}");
        }
    }

    fn mode(&self) -> &'static str {
        let m: String = fs::read_to_string(self.state_dir.join("mode")).unwrap_or_default().chars().filter(|c| !c.is_whitespace()).collect();
        match m.as_str() {
            "perf" => "perf",
            "save" => "save",
            _ => "auto",
        }
    }

    fn effective(&self) -> &'static str {
        match self.mode() {
            "perf" => "perf",
            "save" => "save",
            _ => {
                if on_battery() {
                    "save"
                } else {
                    "perf"
                }
            }
        }
    }

    /// Transient refresh change through niri's socket; no config edits.
    fn set_refresh(&self, want_hz: &str) {
        if !self.conf.on("SWITCH_REFRESH") {
            return;
        }
        let out = self.conf.get("OUTPUT");
        let o = niri::query("Outputs").ok().and_then(|v| v.get(out).cloned());
        let (cur, best) = match o.as_ref().and_then(|o| {
            let modes = o["modes"].as_array()?;
            let c = modes.get(o["current_mode"].as_u64()? as usize)?;
            let target: f64 = want_hz.parse().unwrap_or(f64::NAN);
            let dist = |m: &Value| (m["refresh_rate"].as_f64().unwrap_or(0.0) / 1000.0 - target).abs();
            let best = modes
                .iter()
                .filter(|m| m["width"] == c["width"] && m["height"] == c["height"] && dist(m) < 0.5)
                .min_by(|a, b| dist(a).total_cmp(&dist(b)))
                .cloned();
            Some((c.clone(), best))
        }) {
            Some(x) => x,
            None => return self.log(&format!("refresh: {out} not found, skipped")),
        };
        let cur_s = fmt_mode(&cur);
        let Some(best) = best else {
            return self.log(&format!("refresh: {want_hz} Hz is not offered by {out}, kept {cur_s}"));
        };
        let want_s = fmt_mode(&best);
        if cur_s == want_s {
            return self.log(&format!("refresh: {want_s} (unchanged)"));
        }
        // `niri msg output OUT mode WxH@R` sends the refresh as parsed from that text
        let refresh: f64 = want_s.rsplit('@').next().and_then(|r| r.parse().ok()).unwrap_or(0.0);
        let req = json!({"Output": {"output": out, "action": {"Mode": {"mode": {"Specific": {
            "width": best["width"], "height": best["height"], "refresh": refresh}}}}}});
        match niri::request(&req) {
            Ok(_) => self.log(&format!("refresh: {cur_s} -> {want_s} (transient)")),
            Err(_) => self.log(&format!("refresh: could not set {want_s}, kept {cur_s}")),
        }
    }

    fn set_profile(&self, want: &str) {
        if !self.conf.on("SWITCH_PROFILE") || !on_path("powerprofilesctl") {
            return;
        }
        let cur = sh_out(&["powerprofilesctl", "get"]);
        if cur == want {
            return self.log(&format!("profile: {want} (unchanged)"));
        }
        if sh_ok(&["powerprofilesctl", "set", want]) {
            self.log(&format!("profile: {cur} -> {want}"));
        } else {
            self.log(&format!("profile: could not set {want}"));
        }
    }

    fn set_timers(&self, policy: &str) {
        if !self.conf.on("SWITCH_TIMERS") {
            return;
        }
        let g = self.runtime_units.join("gcal-sync.timer.d");
        let a = self.runtime_units.join("anki-queue-flush.timer.d");
        let mut changed = false;
        if policy == "save" {
            let _ = fs::create_dir_all(&g);
            let _ = fs::create_dir_all(&a);
            let wants = [
                (g.join("power-mode.conf"), format!("# power-mode (battery): runs less often on battery\n[Timer]\nOnCalendar=\nOnCalendar={}", self.conf.get("SAVE_GCAL_ONCALENDAR"))),
                // the empty OnUnitActiveSec= resets ALL monotonic triggers (OnBootSec too), so re-add OnBootSec
                (
                    a.join("power-mode.conf"),
                    format!(
                        "# power-mode (battery): runs less often on battery\n[Timer]\nOnUnitActiveSec=\nOnBootSec={}\nOnUnitActiveSec={}",
                        self.conf.get("ANKI_ON_BOOT"),
                        self.conf.get("SAVE_ANKI_INTERVAL")
                    ),
                ),
            ];
            for (f, want) in wants {
                if read_strip(&f).as_deref() != Some(want.as_str()) {
                    let _ = fs::write(&f, format!("{want}\n"));
                    changed = true;
                }
            }
        } else {
            for f in [g.join("power-mode.conf"), a.join("power-mode.conf")] {
                if f.is_file() {
                    let _ = fs::remove_file(&f);
                    changed = true;
                }
            }
            let _ = fs::remove_dir(&g);
            let _ = fs::remove_dir(&a);
        }
        if changed {
            sh_ok(&["systemctl", "--user", "daemon-reload"]);
            for t in ["gcal-sync.timer", "anki-queue-flush.timer"] {
                if sh_ok(&["systemctl", "--user", "is-enabled", "-q", t]) {
                    sh_ok(&["systemctl", "--user", "restart", t]);
                }
            }
            self.log(&format!("timers: {policy} schedule"));
        } else {
            self.log(&format!("timers: {policy} schedule (unchanged)"));
        }
    }

    fn set_llm_idle(&self, idle: &str) {
        let f = self.state_dir.join("llm.env");
        let want = format!("NPU_LLM_IDLE={idle}");
        if read_strip(&f).as_deref() != Some(want.as_str()) {
            let _ = fs::write(&f, format!("{want}\n"));
        }
        self.log(&format!("llm: stops after {idle} idle (next start)"));
    }

    fn apply(&self) {
        let eff = self.effective();
        self.log(&format!("mode {} -> {eff}", self.mode()));
        let p = if eff == "save" { "SAVE" } else { "PERF" };
        self.set_refresh(self.conf.get(&format!("{p}_REFRESH")));
        self.set_profile(self.conf.get(&format!("{p}_PROFILE")));
        self.set_timers(eff);
        self.set_llm_idle(self.conf.get(&format!("{p}_LLM_IDLE")));
        let _ = fs::write(self.state_dir.join("applied"), format!("{eff} {}\n", util::now_unix() as i64));
    }

    fn status(&self) {
        let ac = if on_battery() { "battery" } else { "AC" };
        println!("mode       {}  (power-mode auto|perf|save)", self.mode());
        println!("power      {ac} -> policy {}", self.effective());
        let refresh = sh_out(&["niri", "msg", "outputs"]).lines().find_map(|l| l.trim_start().strip_prefix("Current mode: ").map(String::from)).unwrap_or_default();
        println!("refresh    {refresh}");
        println!("profile    {}", sh_out(&["powerprofilesctl", "get"]));
        let last_after = |text: &str, key: &str, stop: &[char]| -> String {
            text.match_indices(key)
                .filter_map(|(i, _)| {
                    let rest = &text[i + key.len()..];
                    let v = &rest[..rest.find(stop).unwrap_or(rest.len())];
                    (!v.is_empty()).then(|| v.trim_end_matches(' ').to_string())
                })
                .last()
                .unwrap_or_default()
        };
        let cal = sh_out(&["systemctl", "--user", "show", "gcal-sync.timer", "-p", "TimersCalendar", "--value"]);
        println!("gcal-sync  {}", last_after(&cal, "OnCalendar=", &[';', '\n']));
        let mono = sh_out(&["systemctl", "--user", "show", "anki-queue-flush.timer", "-p", "TimersMonotonic", "--value"]);
        println!("anki-flush every {}", last_after(&mono, "OnUnitActiveUSec=", &[' ', ';', '\n']));
        println!(
            "llm        {}  server {}",
            read_strip(&self.state_dir.join("llm.env")).unwrap_or_default(),
            sh_out(&["systemctl", "--user", "is-active", "npu-llm-server"])
        );
        println!("daemon     {}", sh_out(&["systemctl", "--user", "is-active", "power-mode"]));
        let mut bats: Vec<PathBuf> = fs::read_dir("/sys/class/power_supply")
            .map(|d| d.flatten().map(|e| e.path()).filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("BAT"))).collect())
            .unwrap_or_default();
        bats.sort();
        for b in bats {
            if let Some(v) = util::read_trim(b.join("power_now")).and_then(|s| s.parse::<f64>().ok()) {
                println!("draw       {:.2} W", v / 1e6);
            }
        }
    }

    /// Apply, then re-apply (after a second, like the bash version) whenever UPower's OnBattery changes.
    fn daemon(&mut self) -> i32 {
        self.quiet = false;
        self.apply();
        let Some(conn) = system_bus() else {
            eprintln!("power-mode: no system bus");
            return 1;
        };
        if conn
            .add_match_no_cb("type='signal',sender='org.freedesktop.UPower',path='/org/freedesktop/UPower',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'")
            .is_err()
        {
            return 1;
        }
        let fd = conn.channel().watch().fd;
        let sig = util::signal_pipe(&[libc::SIGTERM, libc::SIGINT]).expect("signal pipe");
        loop {
            let ready = util::poll_read(&[fd, sig], None).unwrap_or_default();
            if ready.get(1) == Some(&true) && {
                util::drain_signals(sig);
                util::terminated()
            } {
                return 0;
            }
            if conn.channel().read_write(Some(Duration::ZERO)).is_err() {
                eprintln!("power-mode: lost the system bus");
                return 1;
            }
            let mut flipped = false;
            while let Some(msg) = conn.channel().pop_message() {
                if msg.member().as_deref() != Some("PropertiesChanged") {
                    continue;
                }
                let (iface, changed, invalidated): (Option<String>, Option<dbus::arg::PropMap>, Option<Vec<String>>) = msg.get3();
                if iface.as_deref() == Some("org.freedesktop.UPower")
                    && (changed.is_some_and(|c| c.contains_key("OnBattery")) || invalidated.is_some_and(|i| i.iter().any(|x| x == "OnBattery")))
                {
                    flipped = true;
                }
            }
            if flipped {
                std::thread::sleep(Duration::from_secs(1));
                self.apply();
            }
        }
    }
}

fn conf_path() -> PathBuf {
    util::env_or("XDG_CONFIG_HOME", util::home().join(".config")).join("power-mode.conf")
}

const HELP: &str = "power-mode - one battery-aware switch for the desktop

  power-mode                 show the current state
  power-mode auto            follow the charger: \"save\" on battery, \"perf\" on AC (default)
  power-mode save | perf     force one policy regardless of the charger
  power-mode apply           re-apply the policy now (the daemon does this on every AC change)
  power-mode daemon          (power-mode.service) apply, then re-apply whenever UPower's OnBattery flips

Settings: ~/.config/power-mode.conf (OUTPUT, PERF_/SAVE_REFRESH, PERF_/SAVE_PROFILE,
SAVE_GCAL_ONCALENDAR, SAVE_ANKI_INTERVAL, ANKI_ON_BOOT, PERF_/SAVE_LLM_IDLE, SWITCH_REFRESH/PROFILE/TIMERS=0|1).
It never touches fcitx5.service.";

fn main() {
    util::ignore_sigpipe();
    let state_dir = util::env_or("XDG_STATE_HOME", util::home().join(".local/state")).join("power-mode");
    let _ = fs::create_dir_all(&state_dir);
    let mut pm = Pm {
        conf: Conf::load(&conf_path()),
        state_dir,
        runtime_units: util::runtime_dir().join("systemd/user"),
        quiet: std::env::var("QUIET").as_deref() == Ok("1"),
    };
    let arg = std::env::args().nth(1).unwrap_or_else(|| "status".into());
    match arg.as_str() {
        "auto" | "perf" | "save" => {
            let _ = fs::write(pm.state_dir.join("mode"), format!("{arg}\n"));
            pm.apply();
        }
        "apply" => pm.apply(),
        "status" | "" => pm.status(),
        "daemon" => std::process::exit(pm.daemon()),
        "-h" | "--help" | "help" => println!("{HELP}"),
        _ => {
            eprintln!("usage: power-mode [auto|perf|save|apply|status|daemon]");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::parse_assignment;

    #[test]
    fn conf_lines() {
        let p = |s: &str| parse_assignment(s).map(|(k, v)| format!("{k}={v}"));
        assert_eq!(p("SAVE_GCAL_ONCALENDAR='*:0/5:05'     # comment").as_deref(), Some("SAVE_GCAL_ONCALENDAR=*:0/5:05"));
        assert_eq!(p("SAVE_REFRESH=120.000              # user wants 120").as_deref(), Some("SAVE_REFRESH=120.000"));
        assert_eq!(p("X=\"a b\"").as_deref(), Some("X=a b"));
        assert_eq!(p("# OUTPUT=x"), None);
        assert_eq!(p("not an assignment"), None);
        assert_eq!(p("EMPTY=").as_deref(), Some("EMPTY="));
    }
}

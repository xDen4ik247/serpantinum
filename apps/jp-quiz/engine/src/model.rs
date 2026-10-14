//! Skill-based matchmaking model (port of jpquiz/model.py): IRT/Rasch logistic with a Bayesian
//! (Glicko-like) variance per component, updated with one rank-1 Laplace step per answer.
use indexmap::IndexMap;

pub const SCALE: f64 = 173.71779276130073; // 400 / ln(10)
pub const BASE: f64 = 1500.0;

fn prior(fam: &str) -> (f64, f64) {
    match fam {
        "g" => (-0.4, 1.2),
        "cat" => (0.0, 0.25),
        "kind" => (0.0, 0.12),
        "tag" => (0.0, 0.30),
        _ => (0.0, 0.16), // item (mean = seeded difficulty)
    }
}
fn var_floor(fam: &str) -> f64 {
    match fam {
        "g" => 0.012,
        "cat" => 0.02,
        "kind" => 0.015,
        "tag" => 0.04,
        _ => 0.05,
    }
}
fn var_cap(fam: &str) -> f64 {
    match fam {
        "g" => 1.2,
        "cat" => 0.4,
        "kind" => 0.2,
        "tag" => 0.5,
        _ => 0.25,
    }
}
fn q_step(fam: &str) -> f64 {
    match fam {
        "g" => 0.004,
        "cat" => 0.004,
        "kind" => 0.001,
        "tag" => 0.006,
        _ => 0.0,
    }
}
fn q_day(fam: &str) -> f64 {
    match fam {
        "g" => 0.01,
        "cat" => 0.01,
        "kind" => 0.002,
        "tag" => 0.02,
        _ => 0.0,
    }
}

pub fn guess(kind: &str) -> f64 {
    match kind {
        "particle" | "conj" | "gmean" | "voice" | "odd" | "kread" | "kwrite" | "vocab" | "produce" => 0.2,
        "form" | "meaning" => 0.22,
        "order" => 0.02,
        "typed" => 0.0,
        _ => 0.2,
    }
}

pub fn family(key: &str) -> &str {
    if key == "g" {
        "g"
    } else {
        key.split(':').next().unwrap_or(key)
    }
}

pub fn sigmoid(x: f64) -> f64 {
    if x >= 0.0 {
        1.0 / (1.0 + crate::pymath::exp(-x))
    } else {
        let z = crate::pymath::exp(x);
        z / (1.0 + z)
    }
}

pub fn logit(p: f64) -> f64 {
    let p = p.max(1e-6).min(1.0 - 1e-6);
    crate::pymath::log(p / (1.0 - p))
}

pub fn to_rating(theta: f64) -> f64 {
    BASE + SCALE * theta
}

#[derive(Clone, Debug)]
pub struct Comp {
    pub mu: f64,
    pub var: f64,
    pub n: i64,
    pub t: f64,
}

pub type Terms = Vec<(String, f64)>;

#[derive(Default)]
pub struct Model {
    pub comps: IndexMap<String, Comp>,
}

impl Model {
    pub fn get(&mut self, key: &str, seed: Option<f64>) -> &mut Comp {
        if !self.comps.contains_key(key) {
            let fam = family(key);
            let (mut mu, var) = prior(fam);
            if fam == "item" {
                mu = seed.unwrap_or(0.0);
            }
            self.comps.insert(key.to_string(), Comp { mu, var, n: 0, t: 0.0 });
        }
        self.comps.get_mut(key).unwrap()
    }

    pub fn peek(&self, key: &str, seed: Option<f64>) -> (f64, f64) {
        if let Some(c) = self.comps.get(key) {
            return (c.mu, c.var);
        }
        let fam = family(key);
        let (mut mu, var) = prior(fam);
        if fam == "item" {
            mu = seed.unwrap_or(0.0);
        }
        (mu, var)
    }

    pub fn design(cat: &str, kind: &str, tags: &[String], item_key: &str) -> Terms {
        let mut terms = vec![("g".to_string(), 1.0), (format!("cat:{cat}"), 1.0), (format!("kind:{kind}"), 1.0)];
        if !tags.is_empty() {
            let w = 1.0 / tags.len() as f64;
            terms.extend(tags.iter().map(|t| (format!("tag:{t}"), w)));
        }
        terms.push((format!("item:{item_key}"), -1.0));
        terms
    }

    pub fn eta(&self, terms: &Terms, seed: f64) -> (f64, f64) {
        let (mut m, mut v) = (0.0, 0.0);
        for (key, a) in terms {
            let (mu, var) = self.peek(key, Some(seed));
            m += a * mu;
            v += a * a * var;
        }
        (m, v)
    }

    pub fn prob(m: f64, v: f64, guess: f64) -> f64 {
        let p = sigmoid(m / crate::pymath::sqrt(1.0 + std::f64::consts::PI * v / 8.0));
        guess + (1.0 - guess) * p
    }

    pub fn predict(&self, terms: &Terms, seed: f64, guess: f64, mem_shift: f64) -> f64 {
        let (m, v) = self.eta(terms, seed);
        Model::prob(m + mem_shift, v, guess)
    }

    pub fn info(&self, terms: &Terms, seed: f64, guess: f64) -> f64 {
        let (m, _) = self.eta(terms, seed);
        let s = sigmoid(m);
        let p = guess + (1.0 - guess) * s;
        let d = (1.0 - guess) * s * (1.0 - s);
        d * d / (p * (1.0 - p)).max(1e-9)
    }

    /// One Bayesian step after observing y (1 correct / 0 wrong).
    pub fn update(&mut self, terms: &Terms, seed: f64, guess: f64, y: i64, now: f64, mem_shift: f64) {
        let mut keys: Vec<(String, f64, &'static str)> = vec![];
        for (key, a) in terms {
            let fam: &'static str = match family(key) {
                "g" => "g",
                "cat" => "cat",
                "kind" => "kind",
                "tag" => "tag",
                _ => "item",
            };
            let c = self.get(key, Some(seed));
            if fam != "item" {
                let days = if c.t != 0.0 { ((now - c.t) / 86400.0).max(0.0) } else { 0.0 };
                c.var = var_cap(fam).min(c.var + q_step(fam) + q_day(fam) * days.min(60.0));
            }
            keys.push((key.clone(), *a, fam));
        }
        // sum() in Python: compensated, not a plain loop
        let m = crate::pymath::sum(keys.iter().map(|(k, a, _)| a * self.comps[k].mu)) + mem_shift;
        let s_var = crate::pymath::sum(keys.iter().map(|(k, a, _)| a * a * self.comps[k].var));
        let s = sigmoid(m);
        let p = guess + (1.0 - guess) * s;
        let ds = (1.0 - guess) * s * (1.0 - s);
        let grad = if y != 0 { ds / p } else { -ds / (1.0 - p) };
        let info = (ds * ds) / (p * (1.0 - p)).max(1e-9);
        let denom = 1.0 + info * s_var;
        for (k, a, fam) in &keys {
            let c = self.comps.get_mut(k).unwrap();
            let dmu = c.var * a * grad / denom;
            c.mu += dmu;
            c.var = var_floor(fam).max(c.var - crate::pymath::pow(c.var * a, 2.0) * info / denom);
            c.n += 1;
            c.t = now;
        }
    }

    pub fn theta(&self, key: &str) -> f64 {
        self.peek(key, None).0
    }

    pub fn skill_theta(&self, cat: Option<&str>, tag: Option<&str>, kind: Option<&str>) -> f64 {
        let mut th = self.peek("g", None).0;
        if let Some(c) = cat.filter(|c| !c.is_empty()) {
            th += self.peek(&format!("cat:{c}"), None).0;
        }
        if let Some(k) = kind.filter(|k| !k.is_empty()) {
            th += self.peek(&format!("kind:{k}"), None).0;
        }
        if let Some(t) = tag.filter(|t| !t.is_empty()) {
            th += self.peek(&format!("tag:{t}"), None).0;
        }
        th
    }

    pub fn rating(&self, cat: Option<&str>, tag: Option<&str>, kind: Option<&str>) -> f64 {
        to_rating(self.skill_theta(cat, tag, kind))
    }
}

//! FSRS-style memory model for spaced repetition of knowledge components (port of jpquiz/memory.py).

pub const W: [f64; 19] = [
    0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698,
    0.2315, 2.9898, 0.51655, 0.6621,
];
pub const F: f64 = 19.0 / 81.0;
pub const C: f64 = -0.5;
pub const DAY: f64 = 86400.0;
pub const RELEARN: f64 = 4.0 * 60.0;
pub const TARGET_R: f64 = 0.9;

fn s0(grade: i64) -> f64 {
    match grade {
        1 => 3.0 / 1440.0,
        2 => 0.4,
        3 => 2.0,
        _ => 6.0,
    }
}

pub fn retrievability(stability_days: f64, elapsed_days: f64) -> f64 {
    if stability_days <= 0.0 {
        return 0.0;
    }
    crate::pymath::pow(1.0 + F * elapsed_days.max(0.0) / stability_days, C)
}

fn d0(g: i64) -> f64 {
    10.0f64.min(1.0f64.max(W[4] - crate::pymath::exp(W[5] * (g - 1) as f64) + 1.0))
}

#[derive(Clone, Debug)]
pub struct Card {
    pub s: f64,
    pub d: f64,
    pub last: f64,
    pub reps: i64,
    pub lapses: i64,
    pub state: String,
    pub due: f64,
    pub short_due: f64,
    pub last_q: i64,
}

impl Default for Card {
    fn default() -> Card {
        Card { s: 0.0, d: 5.0, last: 0.0, reps: 0, lapses: 0, state: "new".into(), due: 0.0, short_due: 0.0, last_q: -1 }
    }
}

impl Card {
    pub fn r(&self, now: f64) -> f64 {
        if self.state == "new" {
            return 0.0;
        }
        retrievability(self.s, (now - self.last) / DAY)
    }
}

pub fn grade_from(correct: bool, seconds: f64, fast: f64) -> i64 {
    if !correct {
        1
    } else if seconds <= fast {
        4
    } else if seconds <= 3.0 * fast {
        3
    } else {
        2
    }
}

pub fn review(card: &mut Card, grade: i64, now: f64, qn: i64) {
    if card.state == "new" {
        card.s = s0(grade);
        card.d = d0(grade);
    } else {
        let elapsed = ((now - card.last) / DAY).max(0.0);
        let r = retrievability(card.s, elapsed);
        if grade == 1 {
            let new_s = W[11] * crate::pymath::pow(card.d, -W[12]) * (crate::pymath::pow(card.s + 1.0, W[13]) - 1.0) * crate::pymath::exp(W[14] * (1.0 - r));
            card.s = (1.0 / 1440.0f64).max(card.s.min(new_s));
            card.lapses += 1;
        } else {
            let hard = if grade == 2 { W[15] } else { 1.0 };
            let easy = if grade == 4 { W[16] } else { 1.0 };
            let inc = crate::pymath::exp(W[8]) * (11.0 - card.d) * crate::pymath::pow(card.s, -W[9]) * (crate::pymath::exp(W[10] * (1.0 - r)) - 1.0) * hard * easy;
            card.s = card.s * (1.0 + inc.max(0.05));
        }
        let d = card.d - W[6] * (grade - 3) as f64;
        card.d = 10.0f64.min(1.0f64.max(W[7] * d0(4) + (1.0 - W[7]) * d));
    }
    card.reps += 1;
    card.last = now;
    card.last_q = qn;
    if grade == 1 {
        card.state = "relearning".into();
        card.short_due = now + RELEARN;
    } else {
        card.state = "review".into();
        card.short_due = 0.0;
    }
    card.due = now + card.s * DAY;
}

const SPECIFIC: [&str; 4] = ["read:", "write:", "use:", "sent:"];

pub fn memory_shift(card: Option<&Card>, now: f64, kc: &str) -> f64 {
    let weight = 0.35;
    let card = match card {
        Some(c) if c.state != "new" && SPECIFIC.iter().any(|p| kc.starts_with(p)) => c,
        _ => return 0.0,
    };
    let r = card.r(now).max(0.02).min(0.995);
    let shift = weight * (crate::pymath::log(r / (1.0 - r)) - crate::pymath::log(TARGET_R / (1.0 - TARGET_R)));
    (-1.0f64).max(0.6f64.min(shift))
}

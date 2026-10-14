//! Python's `random.Random` (CPython 3.14), bit for bit: MT19937 seeded like `random.seed(int)`, and
//! the exact algorithms of random(), getrandbits(), _randbelow(), choice(), shuffle(), sample(),
//! choices(weights) and gauss(). With the same seed the engine makes the same picks as the Python one.

const N: usize = 624;
const M: usize = 397;

pub struct PyRandom {
    mt: [u32; N],
    idx: usize,
    gauss_next: Option<f64>,
}

impl PyRandom {
    fn init_genrand(s: u32) -> PyRandom {
        let mut mt = [0u32; N];
        mt[0] = s;
        for i in 1..N {
            mt[i] = 1812433253u32.wrapping_mul(mt[i - 1] ^ (mt[i - 1] >> 30)).wrapping_add(i as u32);
        }
        PyRandom { mt, idx: N, gauss_next: None }
    }

    fn init_by_array(key: &[u32]) -> PyRandom {
        let mut r = PyRandom::init_genrand(19650218);
        let mt = &mut r.mt;
        let (mut i, mut j) = (1usize, 0usize);
        let mut k = N.max(key.len());
        while k > 0 {
            mt[i] = (mt[i] ^ (mt[i - 1] ^ (mt[i - 1] >> 30)).wrapping_mul(1664525)).wrapping_add(key[j]).wrapping_add(j as u32);
            i += 1;
            j += 1;
            if i >= N {
                mt[0] = mt[N - 1];
                i = 1;
            }
            if j >= key.len() {
                j = 0;
            }
            k -= 1;
        }
        k = N - 1;
        while k > 0 {
            mt[i] = (mt[i] ^ (mt[i - 1] ^ (mt[i - 1] >> 30)).wrapping_mul(1566083941)).wrapping_sub(i as u32);
            i += 1;
            if i >= N {
                mt[0] = mt[N - 1];
                i = 1;
            }
            k -= 1;
        }
        mt[0] = 0x8000_0000;
        r
    }

    /// `random.Random(seed)` for an integer seed.
    pub fn new(seed: u128) -> PyRandom {
        let mut key = vec![];
        let mut n = seed;
        while n > 0 {
            key.push(n as u32);
            n >>= 32;
        }
        if key.is_empty() {
            key.push(0);
        }
        PyRandom::init_by_array(&key)
    }

    /// `random.Random()`: seeded from the OS.
    pub fn from_os() -> PyRandom {
        let mut b = [0u8; 16];
        if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
            use std::io::Read;
            let _ = f.read_exact(&mut b);
        }
        PyRandom::new(u128::from_le_bytes(b))
    }

    pub fn genrand_u32(&mut self) -> u32 {
        if self.idx >= N {
            for kk in 0..N {
                let y = (self.mt[kk] & 0x8000_0000) | (self.mt[(kk + 1) % N] & 0x7fff_ffff);
                let mag = if y & 1 == 1 { 0x9908_b0df } else { 0 };
                self.mt[kk] = self.mt[(kk + M) % N] ^ (y >> 1) ^ mag;
            }
            self.idx = 0;
        }
        let mut y = self.mt[self.idx];
        self.idx += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c_5680;
        y ^= (y << 15) & 0xefc6_0000;
        y ^ (y >> 18)
    }

    /// random(): 53-bit float in [0, 1).
    pub fn random(&mut self) -> f64 {
        let a = (self.genrand_u32() >> 5) as f64;
        let b = (self.genrand_u32() >> 6) as f64;
        (a * 67108864.0 + b) * (1.0 / 9007199254740992.0)
    }

    pub fn getrandbits(&mut self, k: u32) -> u64 {
        if k <= 32 {
            return (self.genrand_u32() >> (32 - k)) as u64;
        }
        // k <= 64: little-endian 32-bit words, the last one trimmed
        let lo = self.genrand_u32() as u64;
        let hi = (self.genrand_u32() >> (64 - k)) as u64;
        lo | (hi << 32)
    }

    pub fn randbelow(&mut self, n: usize) -> usize {
        if n == 0 {
            return 0;
        }
        let k = usize::BITS - n.leading_zeros();
        loop {
            let r = self.getrandbits(k) as usize;
            if r < n {
                return r;
            }
        }
    }

    pub fn choice_idx(&mut self, n: usize) -> usize {
        self.randbelow(n)
    }

    pub fn shuffle<T>(&mut self, x: &mut [T]) {
        for i in (1..x.len()).rev() {
            let j = self.randbelow(i + 1);
            x.swap(i, j);
        }
    }

    /// Indices picked by `sample(range(n), k)` (Python picks the same positions for any population).
    pub fn sample_idx(&mut self, n: usize, k: usize) -> Vec<usize> {
        let mut result = Vec::with_capacity(k);
        let mut setsize = 21usize;
        if k > 5 {
            let e = crate::pymath::log((k * 3) as f64) / crate::pymath::log(4f64);
            setsize += 4usize.pow(e.ceil() as u32);
        }
        if n <= setsize {
            let mut pool: Vec<usize> = (0..n).collect();
            for i in 0..k {
                let j = self.randbelow(n - i);
                result.push(pool[j]);
                pool[j] = pool[n - i - 1];
            }
        } else {
            let mut selected = std::collections::HashSet::new();
            for _ in 0..k {
                let mut j = self.randbelow(n);
                while selected.contains(&j) {
                    j = self.randbelow(n);
                }
                selected.insert(j);
                result.push(j);
            }
        }
        result
    }

    pub fn sample<T: Clone>(&mut self, pop: &[T], k: usize) -> Vec<T> {
        self.sample_idx(pop.len(), k).into_iter().map(|i| pop[i].clone()).collect()
    }

    /// One `choices(population, weights)[0]`: the picked index.
    pub fn choices_idx(&mut self, weights: &[f64]) -> usize {
        let mut cum = Vec::with_capacity(weights.len());
        let mut acc = 0.0f64;
        for (i, w) in weights.iter().enumerate() {
            acc = if i == 0 { *w } else { acc + w };
            cum.push(acc);
        }
        let total = cum[cum.len() - 1] + 0.0;
        let x = self.random() * total;
        // bisect_right(cum, x, 0, hi=n-1)
        let (mut lo, mut hi) = (0usize, weights.len() - 1);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if x < cum[mid] {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        lo
    }

    pub fn gauss(&mut self, mu: f64, sigma: f64) -> f64 {
        let z = match self.gauss_next.take() {
            Some(z) => z,
            None => {
                let x2pi = self.random() * std::f64::consts::TAU;
                let g2rad = crate::pymath::sqrt(-2.0 * crate::pymath::log(1.0 - self.random()));
                self.gauss_next = Some(crate::pymath::sin(x2pi) * g2rad);
                crate::pymath::cos(x2pi) * g2rad
            }
        };
        mu + z * sigma
    }
}
#[cfg(test)]
mod rng_parity {
    use crate::pyrand::PyRandom;
    #[test]
    fn matches_cpython() {
        let mut r = PyRandom::new(12345);
        assert_eq!(r.random(), 0.41661987254534116);
        assert_eq!(r.random(), 0.010169169457068361);
        assert_eq!(r.random(), 0.8252065092537432);
        assert_eq!(r.sample_idx(1000, 10), vec![305, 875, 377, 954, 198, 276, 579, 446, 165, 382]);
        assert_eq!(r.sample_idx(30, 7), vec![3, 27, 13, 8, 17, 20, 5]);
        let ch: Vec<usize> = (0..20).map(|_| r.choices_idx(&[1.3, 1.2, 1.0])).collect();
        assert_eq!(ch, vec![1, 0, 2, 2, 1, 2, 1, 0, 0, 0, 2, 0, 1, 0, 1, 1, 1, 0, 1, 0]);
        let mut l: Vec<usize> = (0..10).collect(); r.shuffle(&mut l); assert_eq!(l, vec![1, 7, 8, 6, 3, 5, 0, 4, 2, 9]);
        assert_eq!(r.gauss(0.0, 0.3), -0.01838317524764816);
        assert_eq!(r.gauss(0.0, 0.3), -0.21753502495608232);
        assert_eq!(r.gauss(0.0, 0.3), -0.4664576759808914);
        assert_eq!(r.gauss(0.0, 0.3), -0.06967202447420257);
        assert_eq!(r.gauss(0.0, 0.3), 0.2465865028471885);
        let rb: Vec<usize> = (0..5).map(|_| r.randbelow(35591)).collect(); assert_eq!(rb, vec![15224, 7851, 32717, 14180, 12178]);
        assert_eq!(PyRandom::new((1u128 << 70) + 5).random(), 0.46679953776226335);
    }
}

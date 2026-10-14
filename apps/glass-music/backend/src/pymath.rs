//! The C library's math functions, called exactly like CPython's math module and `**` do.
//! LLVM would otherwise rewrite pow(x, 2.0) as x*x or fold constant math at compile time, and those
//! can differ from glibc in the last bit; the calls go through opaque function pointers instead.
use std::hint::black_box;

#[link(name = "m")]
extern "C" {
    #[link_name = "pow"]
    fn c_pow(x: f64, y: f64) -> f64;
    #[link_name = "sin"]
    fn c_sin(x: f64) -> f64;
}

pub fn pow(x: f64, y: f64) -> f64 {
    let f: unsafe extern "C" fn(f64, f64) -> f64 = black_box(c_pow);
    unsafe { f(black_box(x), black_box(y)) }
}

fn call1(f: unsafe extern "C" fn(f64) -> f64, x: f64) -> f64 {
    let f = black_box(f);
    unsafe { f(black_box(x)) }
}

pub fn sin(x: f64) -> f64 {
    call1(c_sin, x)
}

/// Python's built-in sum() over floats (CPython ≥ 3.12): the start value int 0 plus the first item,
/// then Neumaier-compensated additions, the compensation added once at the end.
pub fn sum<I: IntoIterator<Item = f64>>(xs: I) -> f64 {
    let mut it = xs.into_iter();
    let Some(first) = it.next() else { return 0.0 };
    let mut f = 0.0 + first;
    let mut c = 0.0;
    for x in it {
        let t = f + x;
        if f.abs() >= x.abs() {
            c += (f - t) + x;
        } else {
            c += (x - t) + f;
        }
        f = t;
    }
    if c != 0.0 && c.is_finite() {
        f += c;
    }
    f
}

#[cfg(test)]
mod tests {
    #[test]
    fn sum_like_cpython() {
        // values checked against CPython 3.14's sum()
        assert_eq!(super::sum([0.1, 0.2, 0.3]), 0.6);
        assert_eq!(super::sum([1e16, 1.0, -1e16]), 1.0);
        assert_eq!(super::sum([1.3, 1.2, 1.0, 0.5, 0.4, 0.8, 0.4, 1.0, 0.8, 1.0, 0.9, 0.7]), 10.0);
    }
}

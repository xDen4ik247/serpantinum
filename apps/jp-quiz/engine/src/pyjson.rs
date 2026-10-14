//! JSON text exactly as Python's `json.dumps` writes it (default separators ", " and ": ", float repr,
//! optional ensure_ascii), and Python's round() for floats.
use serde_json::Value;

/// repr(float): shortest round-trip digits; exponent form when the decimal point is far away.
pub fn float_repr(x: f64) -> String {
    if x.is_nan() {
        return "NaN".into();
    }
    if x.is_infinite() {
        return if x > 0.0 { "Infinity".into() } else { "-Infinity".into() };
    }
    let s = format!("{:e}", x.abs()); // shortest digits, e.g. "1.2345e-5"
    let (mant, exp) = s.split_once('e').unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let exp: i32 = exp.parse().unwrap();
    let decpt = exp + 1;
    let sign = if x.is_sign_negative() { "-" } else { "" };
    let nd = digits.len() as i32;
    let body = if decpt <= -4 || decpt > 16 {
        let mut m = digits[..1].to_string();
        if nd > 1 {
            m.push('.');
            m.push_str(&digits[1..]);
        }
        let e = decpt - 1;
        format!("{m}e{}{:02}", if e < 0 { '-' } else { '+' }, e.abs())
    } else if decpt <= 0 {
        format!("0.{}{}", "0".repeat((-decpt) as usize), digits)
    } else if decpt >= nd {
        format!("{}{}.0", digits, "0".repeat((decpt - nd) as usize))
    } else {
        format!("{}.{}", &digits[..decpt as usize], &digits[decpt as usize..])
    };
    format!("{sign}{body}")
}

/// Python's round(x, n) for floats: correctly rounded from the exact binary value, ties to even.
pub fn round_n(x: f64, n: usize) -> f64 {
    if !x.is_finite() {
        return x;
    }
    format!("{x:.n$}").parse().unwrap_or(x)
}

/// Python's round(x) (no digits): ties to even, an int.
pub fn round_i(x: f64) -> i64 {
    x.round_ties_even() as i64
}

fn write_str(out: &mut String, s: &str, ensure_ascii: bool) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c if ensure_ascii && (c as u32) > 0x7e => {
                let mut buf = [0u16; 2];
                for u in c.encode_utf16(&mut buf) {
                    out.push_str(&format!("\\u{:04x}", u));
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write(out: &mut String, v: &Value, ensure_ascii: bool) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                out.push_str(&i.to_string());
            } else if let Some(u) = n.as_u64() {
                out.push_str(&u.to_string());
            } else {
                out.push_str(&float_repr(n.as_f64().unwrap()));
            }
        }
        Value::String(s) => write_str(out, s, ensure_ascii),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write(out, x, ensure_ascii);
            }
            out.push(']');
        }
        Value::Object(m) => {
            out.push('{');
            for (i, (k, x)) in m.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_str(out, k, ensure_ascii);
                out.push_str(": ");
                write(out, x, ensure_ascii);
            }
            out.push('}');
        }
    }
}

/// json.dumps(v, ensure_ascii=...)
pub fn dumps(v: &Value, ensure_ascii: bool) -> String {
    let mut s = String::new();
    write(&mut s, v, ensure_ascii);
    s
}

/// A float JSON value that stays a float even when integral (Python's 1.0, not 1).
pub fn f(x: f64) -> Value {
    serde_json::Number::from_f64(x).map(Value::Number).unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reprs() {
        for (x, s) in [(1.0, "1.0"), (0.1, "0.1"), (1e-5, "1e-05"), (0.0001, "0.0001"), (1e16, "1e+16"), (1e15, "1000000000000000.0"),
                       (-0.0, "-0.0"), (123.456, "123.456"), (1.5e300, "1.5e+300"), (0.8479252323297531, "0.8479252323297531")] {
            assert_eq!(float_repr(x), s);
        }
        assert_eq!(round_n(0.125, 2), 0.12);
        assert_eq!(round_i(2.5), 2);
        assert_eq!(round_i(3.5), 4);
        let v: Value = serde_json::from_str(r#"{"a": [1, 2.0, "é\n"], "b": null}"#).unwrap();
        assert_eq!(dumps(&v, true), r#"{"a": [1, 2.0, "\u00e9\n"], "b": null}"#);
        assert_eq!(dumps(&v, false), "{\"a\": [1, 2.0, \"é\\n\"], \"b\": null}");
    }
}

/// The features this copy of the library was compiled with.
pub fn compiled_features() -> &'static str {
    if cfg!(all(feature = "alpha", feature = "beta")) {
        "alpha+beta"
    } else if cfg!(feature = "alpha") {
        "alpha"
    } else if cfg!(feature = "beta") {
        "beta"
    } else {
        "none"
    }
}

#[cfg(feature = "alpha")]
pub fn alpha_marker() -> u32 { 1 }

#[cfg(feature = "beta")]
pub fn beta_marker() -> u32 { 2 }

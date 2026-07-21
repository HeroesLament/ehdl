fn main() {
    // On macOS, enif symbols are resolved at runtime by the BEAM.
    // Tell the linker to allow undefined symbols so it doesn't fail.
    #[cfg(target_os = "macos")]
    println!("cargo:rustc-cdylib-link-arg=-undefined");
    #[cfg(target_os = "macos")]
    println!("cargo:rustc-cdylib-link-arg=dynamic_lookup");
}
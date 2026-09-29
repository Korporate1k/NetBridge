// Embeds app.manifest (requireAdministrator: creating the wintun adapter and adding routes need an elevated process)
// into NetBridge.exe. Only runs when targeting Windows.
//
// The .res file is written here directly instead of via rc.exe/llvm-rc, so the exe cross-compiles from a Mac with
// nothing but cargo-xwin: both link.exe and lld-link accept a .res file as a linker input.
use std::io::Write;

fn main() {
    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let manifest = std::fs::read("app.manifest").expect("app.manifest");
    let out = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("netbridge.res");
    let mut res = Vec::new();
    // A .res file starts with an empty entry, then one entry per resource.
    write_entry(&mut res, 0, 0, 0, 0, &[]);
    const RT_MANIFEST: u16 = 24;
    const CREATEPROCESS_MANIFEST_RESOURCE_ID: u16 = 1;
    const MOVEABLE_PURE_DISCARDABLE: u16 = 0x1030;
    const LANG_NEUTRAL: u16 = 0;
    write_entry(&mut res, RT_MANIFEST, CREATEPROCESS_MANIFEST_RESOURCE_ID, MOVEABLE_PURE_DISCARDABLE, LANG_NEUTRAL, &manifest);
    std::fs::File::create(&out).and_then(|mut f| f.write_all(&res)).expect("write netbridge.res");
    println!("cargo:rustc-link-arg-bins={}", out.display());
}

/// One RESOURCEHEADER + data, with ordinal type and name (32-byte header), data padded to a DWORD boundary.
fn write_entry(buf: &mut Vec<u8>, type_id: u16, name_id: u16, flags: u16, lang: u16, data: &[u8]) {
    buf.extend_from_slice(&(data.len() as u32).to_le_bytes()); // DataSize
    buf.extend_from_slice(&32u32.to_le_bytes()); // HeaderSize
    buf.extend_from_slice(&0xFFFFu16.to_le_bytes());
    buf.extend_from_slice(&type_id.to_le_bytes()); // TYPE (ordinal)
    buf.extend_from_slice(&0xFFFFu16.to_le_bytes());
    buf.extend_from_slice(&name_id.to_le_bytes()); // NAME (ordinal)
    buf.extend_from_slice(&0u32.to_le_bytes()); // DataVersion
    buf.extend_from_slice(&flags.to_le_bytes()); // MemoryFlags
    buf.extend_from_slice(&lang.to_le_bytes()); // LanguageId
    buf.extend_from_slice(&0u32.to_le_bytes()); // Version
    buf.extend_from_slice(&0u32.to_le_bytes()); // Characteristics
    buf.extend_from_slice(data);
    while buf.len() % 4 != 0 {
        buf.push(0);
    }
}

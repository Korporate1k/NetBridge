//! The platform-independent pieces of `routing.rs`: registry string encodings and route-prefix parsing. Kept apart
//! from the Windows-only module so they are unit-tested on a Mac too.

use std::net::IpAddr;

/// A NUL-terminated UTF-16 string, as the `W` Win32 APIs and REG_SZ values expect.
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// A REG_MULTI_SZ: every item NUL-terminated, then one more NUL ending the list. An empty list is two NULs,
/// which is what RegSetValueEx documents for an empty multi-string.
pub fn multi_sz(items: &[&str]) -> Vec<u16> {
    let mut out: Vec<u16> = items.iter().flat_map(|s| wide(s)).collect();
    if items.is_empty() {
        out.push(0);
    }
    out.push(0);
    out
}

/// UTF-16 units as the byte buffer RegSetValueExW takes (native order; every Windows target is little-endian).
pub fn wide_bytes(units: &[u16]) -> Vec<u8> {
    units.iter().flat_map(|u| u.to_ne_bytes()).collect()
}

/// A UTF-16 buffer read back from Windows, up to its first NUL.
pub fn from_wide(buf: &[u16]) -> String {
    let end = buf.iter().position(|&u| u == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}

/// "1.2.3.4/32" or "2001:db8::1/128" -> (address, prefix length). Rejects lengths longer than the family allows.
pub fn parse_prefix(s: &str) -> Option<(IpAddr, u8)> {
    let (addr, len) = s.split_once('/')?;
    let addr: IpAddr = addr.parse().ok()?;
    let len: u8 = len.parse().ok()?;
    let max = if addr.is_ipv4() { 32 } else { 128 };
    (len <= max).then_some((addr, len))
}

/// A config.json `pending_bypass` record ("prefix if_index", see `routing::bypass_record`) -> (address, length, index).
pub fn parse_bypass_record(record: &str) -> Option<(IpAddr, u8, u32)> {
    let mut parts = record.split_whitespace();
    let (addr, len) = parse_prefix(parts.next()?)?;
    let index = parts.next()?.parse().ok()?;
    parts.next().is_none().then_some((addr, len, index))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn wide_strings_are_nul_terminated() {
        assert_eq!(wide("8.8"), vec![b'8' as u16, b'.' as u16, b'8' as u16, 0]);
        assert_eq!(wide(""), vec![0]);
    }

    #[test]
    fn multi_sz_has_a_terminator_per_item_plus_one() {
        // "." as Add-DnsClientNrptRule -Namespace '.' stores it in the rule's Name value.
        assert_eq!(multi_sz(&["."]), vec![b'.' as u16, 0, 0]);
        assert_eq!(multi_sz(&["a", "bc"]), vec![b'a' as u16, 0, b'b' as u16, b'c' as u16, 0, 0]);
        assert_eq!(multi_sz(&[]), vec![0, 0]);
    }

    #[test]
    fn registry_bytes_are_little_endian_utf16() {
        assert_eq!(wide_bytes(&multi_sz(&["."])), vec![0x2e, 0, 0, 0, 0, 0]);
        assert_eq!(wide_bytes(&wide("é")), vec![0xe9, 0, 0, 0]);
    }

    #[test]
    fn from_wide_stops_at_the_first_nul() {
        assert_eq!(from_wide(&wide("NetBridge")), "NetBridge");
        assert_eq!(from_wide(&[b'a' as u16, 0, b'b' as u16]), "a");
        assert_eq!(from_wide(&[b'a' as u16, b'b' as u16]), "ab");
        assert_eq!(from_wide(&[]), "");
    }

    #[test]
    fn prefixes_parse_and_lengths_are_checked_per_family() {
        assert_eq!(parse_prefix("1.2.3.4/32"), Some((IpAddr::V4(Ipv4Addr::new(1, 2, 3, 4)), 32)));
        assert_eq!(parse_prefix("0.0.0.0/1"), Some((IpAddr::V4(Ipv4Addr::UNSPECIFIED), 1)));
        assert_eq!(parse_prefix("8000::/1"), Some((IpAddr::V6(Ipv6Addr::new(0x8000, 0, 0, 0, 0, 0, 0, 0)), 1)));
        assert_eq!(parse_prefix("2001:db8::1/128").map(|p| p.1), Some(128));
        assert_eq!(parse_prefix("1.2.3.4/33"), None);
        assert_eq!(parse_prefix("2001:db8::1/129"), None);
        assert_eq!(parse_prefix("1.2.3.4"), None);
        assert_eq!(parse_prefix("host/32"), None);
    }

    #[test]
    fn bypass_records_round_trip_the_stored_format() {
        assert_eq!(
            parse_bypass_record("192.168.1.9/32 12"),
            Some((IpAddr::V4(Ipv4Addr::new(192, 168, 1, 9)), 32, 12))
        );
        assert_eq!(parse_bypass_record("fe80::1/128 7").map(|r| (r.1, r.2)), Some((128, 7)));
        assert_eq!(parse_bypass_record("192.168.1.9/32"), None);
        assert_eq!(parse_bypass_record("192.168.1.9/32 x"), None);
        assert_eq!(parse_bypass_record("192.168.1.9/32 1 2"), None);
        assert_eq!(parse_bypass_record(""), None);
    }
}

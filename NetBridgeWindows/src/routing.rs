//! Windows routing and DNS for the tunnel. We do this ourselves instead of tun2proxy's `--setup`
//! (tproxy-config 7.0.7), because that one:
//! - deletes EVERY 0.0.0.0/0 route on teardown and re-adds a hand-made one, clobbering the DHCP route;
//! - routes IPv4 only, so IPv6 traffic would leak around the tunnel;
//! - leaves the PC with no default route if the process dies while connected.
//!
//! Here, everything that captures traffic is bound to the wintun adapter's interface index:
//! - 0.0.0.0/1 + 128.0.0.0/1 and ::/1 + 8000::/1 (more specific than any default route, so nothing is deleted);
//! - if the process dies, Windows drops the adapter and every route on it goes with it.
//!
//! What can outlive a crash is only:
//! - the /32 (/128) bypass route to the server, which is harmless and removed on next launch (`cleanup_stale`);
//! - the NRPT rule, which sends DNS to 8.8.8.8 and still resolves without the tunnel; also removed on next launch.
//!
//! Everything goes through IP Helper and the registry directly. The first version spawned netsh (~10 times) and
//! PowerShell (NRPT; several seconds per start on a slow PC), which made a connect take ~30 s. The external tools
//! are only left as a fallback for the NRPT rule.
//!
//! Routes and addresses added through IP Helper live in the active store only (like netsh `store=active`): they go
//! away with the adapter or a reboot.

use crate::netspec::{self, wide};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::os::windows::process::CommandExt;
use std::process::Command;
use windows_sys::Win32::Foundation::{
    ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA, ERROR_NO_MORE_ITEMS, ERROR_NOT_FOUND, ERROR_OBJECT_ALREADY_EXISTS,
    FreeLibrary, NO_ERROR, WIN32_ERROR,
};
use windows_sys::Win32::NetworkManagement::IpHelper::{
    CreateIpForwardEntry2, CreateUnicastIpAddressEntry, DeleteIpForwardEntry2, FreeMibTable, GetBestRoute2,
    GetIpForwardTable2, GetIpInterfaceEntry, InitializeIpForwardEntry, InitializeIpInterfaceEntry,
    InitializeUnicastIpAddressEntry, MIB_IPFORWARD_ROW2, MIB_IPFORWARD_TABLE2, MIB_IPINTERFACE_ROW,
    MIB_UNICASTIPADDRESS_ROW, SetIpInterfaceEntry,
};
use windows_sys::Win32::Networking::WinSock::{
    ADDRESS_FAMILY, AF_INET, AF_INET6, IpDadStatePreferred, IpPrefixOriginManual, IpSuffixOriginManual,
    MIB_IPPROTO_NETMGMT, SOCKADDR_INET,
};
use windows_sys::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_LOCAL_MACHINE, KEY_READ, KEY_WRITE, REG_DWORD, REG_MULTI_SZ, REG_OPTION_NON_VOLATILE, REG_SZ,
    REG_VALUE_TYPE, RRF_RT_REG_SZ, RegCloseKey, RegCreateKeyExW, RegDeleteTreeW, RegEnumKeyExW, RegGetValueW,
    RegOpenKeyExW, RegSetValueExW,
};
use windows_sys::Win32::System::Services::{
    CloseServiceHandle, ControlService, OpenSCManagerW, OpenServiceW, SC_MANAGER_CONNECT, SERVICE_CONTROL_PARAMCHANGE,
    SERVICE_PAUSE_CONTINUE, SERVICE_STATUS,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// DNS server the tunnel adapter and the NRPT rule point at. Any UDP/53 into the tunnel is answered by tun2proxy's
/// virtual DNS whatever the destination, so this is only an address that is routed into the tunnel.
pub const TUNNEL_DNS: Ipv4Addr = Ipv4Addr::new(8, 8, 8, 8);
/// fd00:7470::2/64, the same ULA as the Apple clients (TunnelEngine.tunnelLocalAddressV6).
const TUNNEL_V6: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x7470, 0, 0, 0, 0, 0, 2);
const TUNNEL_V6_PREFIX: u8 = 64;
/// Route metric offset for everything we add (netsh `metric=1`); the interface metric is set to 1 as well.
const METRIC: u32 = 1;
const CAPTURE_V4: [(Ipv4Addr, u8); 2] = [(Ipv4Addr::UNSPECIFIED, 1), (Ipv4Addr::new(128, 0, 0, 0), 1)];
const CAPTURE_V6: [(Ipv6Addr, u8); 2] = [(Ipv6Addr::UNSPECIFIED, 1), (Ipv6Addr::new(0x8000, 0, 0, 0, 0, 0, 0, 0), 1)];

/// Local (non-GPO) NRPT rules: one subkey per rule. This is where Add-DnsClientNrptRule without -GpoName writes, so
/// Get-DnsClientNrptRule still lists ours. (If a Group Policy NRPT exists, Windows ignores all local rules; that was
/// already true of the PowerShell rule.)
const NRPT_KEY: &str = r"SYSTEM\CurrentControlSet\Services\Dnscache\Parameters\DnsPolicyConfig";
/// Our rule's subkey. PowerShell names rules by a random {GUID}; ours is fixed so it can be found and replaced.
const NRPT_RULE: &str = "NetBridge-{6e657462-7269-4467-a000-00004e420002}";
/// Comment on our rule. Also how rules made by the PowerShell path (fallback, and older versions) are recognised.
const NRPT_TAG: &str = "NetBridge";

/// Where the physical network sends a destination: interface index + next hop (unspecified = on-link).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RouteVia {
    pub if_index: u32,
    pub next_hop: IpAddr,
}

fn to_sockaddr(ip: IpAddr) -> SOCKADDR_INET {
    let mut sa = SOCKADDR_INET::default();
    match ip {
        IpAddr::V4(v4) => {
            sa.Ipv4.sin_family = AF_INET;
            sa.Ipv4.sin_addr.S_un.S_addr = u32::from_ne_bytes(v4.octets());
        }
        IpAddr::V6(v6) => {
            sa.Ipv6.sin6_family = AF_INET6;
            sa.Ipv6.sin6_addr.u.Byte = v6.octets();
        }
    }
    sa
}

fn from_sockaddr(sa: &SOCKADDR_INET) -> Option<IpAddr> {
    // SAFETY: si_family is the common prefix of every variant; the variant read below matches it.
    unsafe {
        match sa.si_family {
            f if f == AF_INET => Some(IpAddr::V4(Ipv4Addr::from(sa.Ipv4.sin_addr.S_un.S_addr.to_ne_bytes()))),
            f if f == AF_INET6 => Some(IpAddr::V6(Ipv6Addr::from(sa.Ipv6.sin6_addr.u.Byte))),
            _ => None,
        }
    }
}

fn unspecified_like(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
    }
}

fn address_family(ip: IpAddr) -> ADDRESS_FAMILY {
    if ip.is_ipv4() { AF_INET } else { AF_INET6 }
}

/// A Win32 error code as io::Error, with what we were doing in front ("add route 0.0.0.0/1 on 12: Access denied").
fn win_err(rc: WIN32_ERROR, what: impl std::fmt::Display) -> io::Error {
    let e = io::Error::from_raw_os_error(rc as i32);
    io::Error::new(e.kind(), format!("{what}: {e}"))
}

fn check(rc: WIN32_ERROR, what: impl std::fmt::Display) -> io::Result<()> {
    if rc == NO_ERROR { Ok(()) } else { Err(win_err(rc, what)) }
}

/// The route Windows would use for `dest` right now. `on_interface` restricts the lookup to one interface.
pub fn best_route(dest: IpAddr, on_interface: Option<u32>) -> io::Result<RouteVia> {
    let dst = to_sockaddr(dest);
    let mut row = MIB_IPFORWARD_ROW2::default();
    let mut src = SOCKADDR_INET::default();
    // SAFETY: all pointers are to live, properly initialised locals; a null LUID means "use interface index".
    let rc = unsafe {
        GetBestRoute2(std::ptr::null(), on_interface.unwrap_or(0), std::ptr::null(), &dst, 0, &mut row, &mut src)
    };
    if rc != 0 {
        return Err(io::Error::from_raw_os_error(rc as i32));
    }
    let next_hop = from_sockaddr(&row.NextHop).unwrap_or(unspecified_like(dest));
    Ok(RouteVia { if_index: row.InterfaceIndex, next_hop })
}

/// What the physical network looks like from `via.if_index`: its default gateway (or None if it has no default
/// route). Compared before/after to notice "joined a different network on the same adapter".
pub fn path_fingerprint(via: RouteVia) -> Option<RouteVia> {
    best_route(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)), Some(via.if_index)).ok()
}

// ---- routes and interface settings (IP Helper) -------------------------------------------------------------------

/// netsh `add route prefix=<prefix>/<len> interface=<if_index> [nexthop=<next_hop>] metric=1 store=active`.
/// A route that is already there counts as added. `next_hop` = the family's unspecified address for on-link.
pub(crate) fn add_route(prefix: IpAddr, len: u8, if_index: u32, next_hop: IpAddr) -> io::Result<()> {
    let mut row = MIB_IPFORWARD_ROW2::default();
    // SAFETY: row is a live local; Initialize only writes defaults (infinite lifetimes etc.) into it.
    unsafe { InitializeIpForwardEntry(&mut row) };
    row.InterfaceIndex = if_index;
    row.DestinationPrefix.Prefix = to_sockaddr(prefix);
    row.DestinationPrefix.PrefixLength = len;
    row.NextHop = to_sockaddr(next_hop); // the unspecified address of the family = on-link
    row.Metric = METRIC;
    row.Protocol = MIB_IPPROTO_NETMGMT; // "static", as netsh adds them
    // SAFETY: row is fully initialised above.
    match unsafe { CreateIpForwardEntry2(&row) } {
        NO_ERROR | ERROR_OBJECT_ALREADY_EXISTS => Ok(()),
        rc => Err(win_err(rc, format_args!("add route {prefix}/{len} via {next_hop} on interface {if_index}"))),
    }
}

/// netsh `delete route prefix=<prefix>/<len> interface=<if_index>`: removes every route for that prefix on that
/// interface, whatever its next hop (the stored bypass record has no next hop). Nothing to delete is success.
pub(crate) fn delete_routes(prefix: IpAddr, len: u8, if_index: u32) -> io::Result<()> {
    let mut table: *mut MIB_IPFORWARD_TABLE2 = std::ptr::null_mut();
    // SAFETY: on success Windows allocates the table and we free it with FreeMibTable below.
    check(unsafe { GetIpForwardTable2(address_family(prefix), &mut table) }, "read route table")?;
    // SAFETY: the table holds NumEntries rows laid out contiguously from Table[0]; it stays alive until freed.
    let rows = unsafe { std::slice::from_raw_parts((*table).Table.as_ptr(), (*table).NumEntries as usize) };
    let mut result = Ok(());
    for row in rows.iter().filter(|r| {
        r.InterfaceIndex == if_index
            && r.DestinationPrefix.PrefixLength == len
            && from_sockaddr(&r.DestinationPrefix.Prefix) == Some(prefix)
    }) {
        // SAFETY: row points into the live table.
        match unsafe { DeleteIpForwardEntry2(row) } {
            NO_ERROR | ERROR_NOT_FOUND => {}
            rc => result = Err(win_err(rc, format_args!("delete route {prefix}/{len} on interface {if_index}"))),
        }
    }
    // SAFETY: table came from GetIpForwardTable2 and is not used after this.
    unsafe { FreeMibTable(table as *const _) };
    result
}

/// netsh `set interface interface=<if_index> metric=<metric>` for one address family (AF_INET / AF_INET6): a fixed,
/// not automatic, interface metric.
pub(crate) fn set_interface_metric(if_index: u32, family: ADDRESS_FAMILY, metric: u32) -> io::Result<()> {
    let what = format_args!("set {} metric on interface {if_index}", if family == AF_INET { "IPv4" } else { "IPv6" });
    let mut row = MIB_IPINTERFACE_ROW::default();
    // SAFETY: row is a live local; the Get/Set pair is the documented read-modify-write.
    unsafe { InitializeIpInterfaceEntry(&mut row) };
    row.Family = family;
    row.InterfaceIndex = if_index;
    check(unsafe { GetIpInterfaceEntry(&mut row) }, &what)?;
    row.UseAutomaticMetric = false;
    row.Metric = metric;
    if family == AF_INET {
        row.SitePrefixLength = 0; // required for IPv4 (SetIpInterfaceEntry docs)
    }
    check(unsafe { SetIpInterfaceEntry(&mut row) }, &what)
}

/// netsh `add address interface=<if_index> address=<addr>/<prefix_len> store=active` (IPv4 or IPv6). An address that
/// is already there counts as added.
pub(crate) fn add_address(if_index: u32, addr: IpAddr, prefix_len: u8) -> io::Result<()> {
    let mut row = MIB_UNICASTIPADDRESS_ROW::default();
    // SAFETY: row is a live local; Initialize only writes defaults (infinite lifetimes etc.) into it.
    unsafe { InitializeUnicastIpAddressEntry(&mut row) };
    row.InterfaceIndex = if_index;
    row.Address = to_sockaddr(addr);
    row.OnLinkPrefixLength = prefix_len;
    row.PrefixOrigin = IpPrefixOriginManual;
    row.SuffixOrigin = IpSuffixOriginManual;
    // Windows 10+: start "preferred" (optimistic DAD) instead of waiting 1-3 s in "tentative". Nothing else can own
    // an address on a point-to-point tunnel.
    row.DadState = IpDadStatePreferred;
    // SAFETY: row is fully initialised above.
    match unsafe { CreateUnicastIpAddressEntry(&row) } {
        NO_ERROR | ERROR_OBJECT_ALREADY_EXISTS => Ok(()),
        rc => Err(win_err(rc, format_args!("add address {addr}/{prefix_len} on interface {if_index}"))),
    }
}

fn host_prefix(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(_) => format!("{ip}/32"),
        IpAddr::V6(_) => format!("{ip}/128"),
    }
}

/// "prefix if_index", as stored in config.json `pending_bypass`.
pub fn bypass_record(server: IpAddr, via: RouteVia) -> String {
    format!("{} {}", host_prefix(server), via.if_index)
}

fn delete_bypass_record(record: &str) {
    let Some((addr, len, index)) = netspec::parse_bypass_record(record) else {
        log::warn!("ignoring malformed bypass record {record:?}");
        return;
    };
    if let Err(e) = delete_routes(addr, len, index) {
        log::warn!("bypass route removal: {e}");
    }
}

// ---- external tools (fallback only) ------------------------------------------------------------------------------

fn run(program: &str, args: &[&str]) -> io::Result<()> {
    let out = Command::new(program).args(args).creation_flags(CREATE_NO_WINDOW).output()?;
    if out.status.success() {
        log::debug!("{program} {}: ok", args.join(" "));
        Ok(())
    } else {
        let text = String::from_utf8_lossy(&out.stdout).trim().to_string() + String::from_utf8_lossy(&out.stderr).trim();
        Err(io::Error::other(format!("{program} {} failed: {text}", args.join(" "))))
    }
}

fn powershell(script: &str) -> io::Result<()> {
    run("powershell", &["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
}

// ---- DNS: NRPT rule (registry) + DNS client refresh --------------------------------------------------------------

struct RegKey(HKEY);

impl Drop for RegKey {
    fn drop(&mut self) {
        // SAFETY: the handle came from RegOpenKeyExW/RegCreateKeyExW and is closed exactly once.
        unsafe { RegCloseKey(self.0) };
    }
}

fn open_nrpt_key(access: u32) -> Result<RegKey, WIN32_ERROR> {
    let mut key: HKEY = std::ptr::null_mut();
    // SAFETY: path is a NUL-terminated UTF-16 string; key receives the handle.
    let rc = unsafe { RegOpenKeyExW(HKEY_LOCAL_MACHINE, wide(NRPT_KEY).as_ptr(), 0, access, &mut key) };
    if rc == NO_ERROR { Ok(RegKey(key)) } else { Err(rc) }
}

fn set_value(key: &RegKey, name: &str, kind: REG_VALUE_TYPE, data: &[u8]) -> io::Result<()> {
    // SAFETY: name is NUL-terminated; data is a live buffer of data.len() bytes.
    let rc = unsafe { RegSetValueExW(key.0, wide(name).as_ptr(), 0, kind, data.as_ptr(), data.len() as u32) };
    check(rc, format_args!("set NRPT value {name}"))
}

/// Writes our rule the way `Add-DnsClientNrptRule -Namespace '.' -NameServers <TUNNEL_DNS> -Comment NetBridge`
/// stores it (the same value set OpenVPN's interactive service writes for its NRPT rules):
///   Version            REG_DWORD     2      (NRPT rule format version)
///   ConfigOptions      REG_DWORD     8      (0x8 = "GenericDNSServers is set"; no DNSSEC/DirectAccess/proxy)
///   Name               REG_MULTI_SZ  "."    (namespaces; "." = every name)
///   GenericDNSServers  REG_SZ        "8.8.8.8" (';'-separated if several)
///   IPSECCARestriction REG_SZ        ""
///   Comment            REG_SZ        "NetBridge"
fn write_nrpt_rule() -> io::Result<()> {
    let path = wide(&format!(r"{NRPT_KEY}\{NRPT_RULE}"));
    let mut key: HKEY = std::ptr::null_mut();
    // SAFETY: path is NUL-terminated; the optional pointers are null; key receives the handle.
    let rc = unsafe {
        RegCreateKeyExW(
            HKEY_LOCAL_MACHINE,
            path.as_ptr(),
            0,
            std::ptr::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            std::ptr::null(),
            &mut key,
            std::ptr::null_mut(),
        )
    };
    check(rc, "create NRPT rule key")?;
    let key = RegKey(key);
    let written = set_value(&key, "Version", REG_DWORD, &2u32.to_ne_bytes())
        .and_then(|_| set_value(&key, "ConfigOptions", REG_DWORD, &8u32.to_ne_bytes()))
        .and_then(|_| set_value(&key, "Name", REG_MULTI_SZ, &netspec::wide_bytes(&netspec::multi_sz(&["."]))))
        .and_then(|_| set_value(&key, "GenericDNSServers", REG_SZ, &netspec::wide_bytes(&wide(&TUNNEL_DNS.to_string()))))
        .and_then(|_| set_value(&key, "IPSECCARestriction", REG_SZ, &netspec::wide_bytes(&wide(""))))
        .and_then(|_| set_value(&key, "Comment", REG_SZ, &netspec::wide_bytes(&wide(NRPT_TAG))));
    drop(key);
    if written.is_err() {
        // A half-written rule could misroute DNS; don't leave one behind.
        // SAFETY: path is NUL-terminated.
        unsafe { RegDeleteTreeW(HKEY_LOCAL_MACHINE, path.as_ptr()) };
    }
    written
}

/// Subkeys of the NRPT key that are ours: our fixed name, or any rule with Comment "NetBridge" (made by the
/// PowerShell fallback or by older versions, under a random {GUID} name). Registry reads only; no PowerShell.
fn our_nrpt_rules(nrpt: &RegKey) -> Vec<Vec<u16>> {
    let mut ours = Vec::new();
    for index in 0.. {
        let mut name = [0u16; 256]; // registry key names are at most 255 characters
        let mut len = name.len() as u32;
        // SAFETY: name/len describe a live buffer; the other out-parameters are optional and null.
        let rc = unsafe {
            RegEnumKeyExW(
                nrpt.0,
                index,
                name.as_mut_ptr(),
                &mut len,
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if rc == ERROR_NO_MORE_ITEMS {
            break;
        }
        if rc != NO_ERROR {
            log::warn!("NRPT: listing rules stopped: {}", win_err(rc, "enumerate"));
            break;
        }
        let subkey: Vec<u16> = name[..len as usize].iter().copied().chain(std::iter::once(0)).collect();
        let mut comment = [0u16; 64];
        let mut size = std::mem::size_of_val(&comment) as u32;
        // SAFETY: subkey and "Comment" are NUL-terminated; comment/size describe a live buffer.
        let rc = unsafe {
            RegGetValueW(
                nrpt.0,
                subkey.as_ptr(),
                wide("Comment").as_ptr(),
                RRF_RT_REG_SZ,
                std::ptr::null_mut(),
                comment.as_mut_ptr().cast(),
                &mut size,
            )
        };
        // ERROR_MORE_DATA: a comment longer than 63 characters is not "NetBridge".
        let tagged = rc == NO_ERROR && netspec::from_wide(&comment) == NRPT_TAG;
        if tagged || netspec::from_wide(&subkey) == NRPT_RULE {
            ours.push(subkey);
        } else if rc != NO_ERROR && rc != ERROR_FILE_NOT_FOUND && rc != ERROR_MORE_DATA {
            log::debug!("NRPT: rule {}: {}", netspec::from_wide(&subkey), win_err(rc, "read Comment"));
        }
    }
    ours
}

/// Deletes every NetBridge NRPT rule. Ok(n) = how many were there. Err only if the NRPT key itself can't be read
/// (a missing key just means there are no rules).
fn delete_nrpt_rules() -> io::Result<usize> {
    let nrpt = match open_nrpt_key(KEY_READ | KEY_WRITE) {
        Ok(key) => key,
        Err(ERROR_FILE_NOT_FOUND) => return Ok(0),
        Err(rc) => return Err(win_err(rc, "open NRPT key")),
    };
    let rules = our_nrpt_rules(&nrpt);
    for subkey in &rules {
        // SAFETY: subkey is NUL-terminated and names a direct child of the open key.
        let rc = unsafe { RegDeleteTreeW(nrpt.0, subkey.as_ptr()) };
        if rc != NO_ERROR && rc != ERROR_FILE_NOT_FOUND {
            log::warn!("NRPT: {}", win_err(rc, format_args!("delete rule {}", netspec::from_wide(subkey))));
        }
    }
    Ok(rules.len())
}

/// Makes the DNS Client service re-read its configuration, NRPT included. It caches the policy in memory and does not
/// watch our registry key; a PARAMCHANGE control is what `sc control dnscache paramchange` sends and what OpenVPN's
/// interactive service sends after writing its NRPT rules.
fn reload_dns_client() -> io::Result<()> {
    // SAFETY: plain SCM calls on NUL-terminated names; every handle opened here is closed here.
    unsafe {
        let scm = OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_CONNECT);
        if scm.is_null() {
            return Err(io::Error::new(io::ErrorKind::Other, format!("open service manager: {}", io::Error::last_os_error())));
        }
        let svc = OpenServiceW(scm, wide("Dnscache").as_ptr(), SERVICE_PAUSE_CONTINUE);
        let result = if svc.is_null() {
            Err(io::Error::last_os_error())
        } else {
            let mut status = SERVICE_STATUS::default();
            let ok = ControlService(svc, SERVICE_CONTROL_PARAMCHANGE, &mut status) != 0;
            let result = if ok { Ok(()) } else { Err(io::Error::last_os_error()) };
            CloseServiceHandle(svc);
            result
        };
        CloseServiceHandle(scm);
        result.map_err(|e| io::Error::new(e.kind(), format!("DNS client PARAMCHANGE: {e}")))
    }
}

/// `ipconfig /flushdns` without the process: dnsapi.dll's DnsFlushResolverCache (exported, used by ipconfig, not in
/// the SDK headers, hence looked up at run time). Falls back to ipconfig if it can't be found.
fn flush_dns_cache() {
    type Flush = unsafe extern "system" fn() -> i32;
    // SAFETY: dnsapi.dll is loaded from System32 only; the export has the signature `BOOL WINAPI (void)`; the module
    // is released after the call.
    let flushed = unsafe {
        let module = LoadLibraryExW(wide("dnsapi.dll").as_ptr(), std::ptr::null_mut(), LOAD_LIBRARY_SEARCH_SYSTEM32);
        if module.is_null() {
            false
        } else {
            let ok = match GetProcAddress(module, c"DnsFlushResolverCache".as_ptr().cast()) {
                Some(f) => std::mem::transmute::<unsafe extern "system" fn() -> isize, Flush>(f)() != 0,
                None => false,
            };
            FreeLibrary(module);
            ok
        }
    };
    if !flushed {
        let _ = run("ipconfig", &["/flushdns"]);
    }
}

fn add_nrpt() -> io::Result<()> {
    let direct = write_nrpt_rule().and_then(|_| {
        reload_dns_client().inspect_err(|_| {
            let _ = delete_nrpt_rules(); // unapplied; let the fallback add it the supported way instead
        })
    });
    match direct {
        Ok(()) => Ok(()),
        Err(e) => {
            log::warn!("NRPT via registry failed ({e}); falling back to PowerShell");
            powershell(&format!(
                "Add-DnsClientNrptRule -Namespace '.' -NameServers '{TUNNEL_DNS}' -Comment '{NRPT_TAG}' | Out-Null"
            ))
        }
    }
}

/// Removes our NRPT rule(s) and tells the DNS client if anything was removed. Ok(true) = something was removed.
fn remove_nrpt() -> io::Result<bool> {
    match delete_nrpt_rules() {
        Ok(0) => Ok(false),
        Ok(n) => {
            log::debug!("removed {n} NRPT rule(s)");
            if let Err(e) = reload_dns_client() {
                log::warn!("NRPT removal not applied yet: {e}");
            }
            Ok(true)
        }
        Err(e) => {
            log::warn!("NRPT via registry: {e}; falling back to PowerShell");
            powershell(&format!(
                "Get-DnsClientNrptRule | Where-Object {{ $_.Comment -eq '{NRPT_TAG}' }} | Remove-DnsClientNrptRule -Force"
            ))
            .map(|_| true)
        }
    }
}

/// Undo whatever a previous run left behind (killed while connected, power loss, ...). A clean previous exit leaves
/// nothing, and then this is one registry lookup.
pub fn cleanup_stale(pending_bypass: Option<&str>) {
    if let Some(record) = pending_bypass {
        log::info!("removing bypass route left by a previous session: {record}");
        delete_bypass_record(record);
    }
    match remove_nrpt() {
        Ok(true) => {
            log::info!("removed an NRPT rule left by a previous session");
            flush_dns_cache();
        }
        Ok(false) => {}
        Err(e) => log::warn!("NRPT cleanup: {e}"),
    }
}

/// Routes and DNS installed for one session. `remove()` (or drop) takes them down again.
pub struct Routes {
    tun_index: u32,
    bypass: String,
    removed: bool,
    pub ipv6_tunnelled: bool,
}

impl Routes {
    /// `server`/`via` come from `best_route(server)` taken BEFORE the tunnel existed.
    pub fn install(tun_index: u32, server: IpAddr, via: RouteVia) -> io::Result<Routes> {
        let started = std::time::Instant::now();
        let mut routes = Routes { tun_index, bypass: bypass_record(server, via), removed: false, ipv6_tunnelled: false };

        // 1. Keep the engine's own connection to the server on the physical network. A leftover from a crashed run
        //    with a different next hop would otherwise stay in the way.
        let server_len = if server.is_ipv4() { 32 } else { 128 };
        let _ = delete_routes(server, server_len, via.if_index);
        add_route(server, server_len, via.if_index, via.next_hop)?;

        // 2. Capture all IPv4 without touching the existing default route.
        for (prefix, len) in CAPTURE_V4 {
            add_route(IpAddr::V4(prefix), len, tun_index, IpAddr::V4(Ipv4Addr::UNSPECIFIED))?;
        }
        set_interface_metric(tun_index, AF_INET, METRIC)?;

        // 3. IPv6: give the adapter an address and capture it too. If IPv6 is disabled on this PC these fail, and
        //    then there is also no IPv6 to leak; we report it rather than failing the connection.
        let v6 = add_address(tun_index, IpAddr::V6(TUNNEL_V6), TUNNEL_V6_PREFIX)
            .and_then(|_| {
                CAPTURE_V6.iter().try_for_each(|&(prefix, len)| {
                    add_route(IpAddr::V6(prefix), len, tun_index, IpAddr::V6(Ipv6Addr::UNSPECIFIED))
                })
            })
            .and_then(|_| set_interface_metric(tun_index, AF_INET6, METRIC));
        match v6 {
            Ok(()) => routes.ipv6_tunnelled = true,
            Err(e) => log::warn!("IPv6 is not tunnelled: {e}"),
        }

        // 4. DNS. The adapter already has TUNNEL_DNS (set when it was created), but Windows also queries other
        //    adapters' servers, which sit on-link and would bypass the tunnel. An NRPT rule for "." makes every
        //    lookup go to TUNNEL_DNS, i.e. into the tunnel, where the virtual DNS answers it.
        let _ = delete_nrpt_rules(); // no separate reload: add_nrpt's reload covers both
        if let Err(e) = add_nrpt() {
            log::warn!("DNS may leak outside the tunnel (NRPT rule not added): {e}");
        }
        flush_dns_cache();
        log::info!("routes and DNS installed in {} ms", started.elapsed().as_millis());
        Ok(routes)
    }

    pub fn bypass_record(&self) -> &str {
        &self.bypass
    }

    pub fn remove(&mut self) {
        if self.removed {
            return;
        }
        self.removed = true;
        for (prefix, len) in CAPTURE_V4 {
            if let Err(e) = delete_routes(IpAddr::V4(prefix), len, self.tun_index) {
                log::warn!("{e}");
            }
        }
        if self.ipv6_tunnelled {
            for (prefix, len) in CAPTURE_V6 {
                if let Err(e) = delete_routes(IpAddr::V6(prefix), len, self.tun_index) {
                    log::warn!("{e}");
                }
            }
        }
        delete_bypass_record(&self.bypass);
        if let Err(e) = remove_nrpt() {
            log::warn!("NRPT removal: {e}");
        }
        flush_dns_cache();
    }
}

impl Drop for Routes {
    fn drop(&mut self) {
        self.remove();
    }
}

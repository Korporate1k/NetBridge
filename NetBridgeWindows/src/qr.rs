//! Pairing from a QR code image (a screenshot or photo of the phone's NetBridge QR). Windows has no camera
//! scanner here; this is the equivalent of the Mac's "import QR image" path in `QRSupport.swift`.

use crate::config::ClientConfig;
use std::path::Path;

pub fn decode_file(path: &Path) -> Result<ClientConfig, String> {
    let img = image::open(path).map_err(|e| format!("could not open image: {e}"))?;
    decode_image(&img.to_luma8())
}

pub fn decode_image(luma: &image::GrayImage) -> Result<ClientConfig, String> {
    let mut prepared = rqrr::PreparedImage::prepare(luma.clone());
    let grids = prepared.detect_grids();
    if grids.is_empty() {
        return Err("no QR code found in the image".into());
    }
    let mut last_err = String::from("QR code could not be read");
    for grid in grids {
        match grid.decode() {
            Ok((_, text)) => match ClientConfig::from_uri(&text) {
                Some(config) => return Ok(config),
                None => last_err = format!("QR code is not a NetBridge server address: {text}"),
            },
            Err(e) => last_err = format!("QR code could not be read: {e}"),
        }
    }
    Err(last_err)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(text: &str) -> image::GrayImage {
        qrcode::QrCode::new(text.as_bytes()).unwrap().render::<image::Luma<u8>>().module_dimensions(6, 6).build()
    }

    #[test]
    fn decodes_a_netbridge_qr_code() {
        let c = decode_image(&render("socks5://alice:pw@172.20.10.1:1080")).unwrap();
        assert_eq!((c.host.as_str(), c.port, c.username.as_str(), c.password.as_str()), ("172.20.10.1", 1080, "alice", "pw"));
    }

    #[test]
    fn decodes_the_bare_host_port_form() {
        let c = decode_image(&render("192.168.1.20:8080")).unwrap();
        assert_eq!((c.host.as_str(), c.port), ("192.168.1.20", 8080));
    }

    #[test]
    fn other_qr_codes_are_rejected() {
        assert!(decode_image(&render("https://example.com")).unwrap_err().contains("not a NetBridge"));
    }

    #[test]
    fn blank_image_has_no_code() {
        let img = image::GrayImage::from_pixel(200, 200, image::Luma([255]));
        assert!(decode_image(&img).unwrap_err().contains("no QR code"));
    }
}

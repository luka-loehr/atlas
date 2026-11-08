//! What both processes need to know to read a video's frames the way they
//! look: the server makes posters from them, atlas-ml analyzes and embeds
//! them.

/// HLG ("arib-std-b67") or PQ ("smpte2084"): frames need tone mapping
/// before they look right in SDR.
pub fn is_hdr(transfer: &str) -> bool {
    matches!(transfer, "arib-std-b67" | "smpte2084")
}

/// HDR to SDR for stills: linear light with HLG/PQ reference white (203
/// nits, BT.2408) as SDR white, BT.709 primaries, Hable's curve for what is
/// brighter. Without it an iPhone clip's frame comes out pale and grey.
pub const TONE_MAP: &str = "zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,\
                            tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=pc,format=rgb24";

#[cfg(test)]
mod tests {
    use super::is_hdr;

    #[test]
    fn hlg_and_pq_are_hdr() {
        assert!(is_hdr("arib-std-b67"));
        assert!(is_hdr("smpte2084"));
        assert!(!is_hdr("bt709"));
        assert!(!is_hdr(""));
    }
}

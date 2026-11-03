// LiteFW built-in upstream DNS resolver profiles (verified against providers' official docs).
// These are standard plaintext UDP/TCP port 53 DNS addresses, NOT DoH/DoT.
// Do not mix filtered profiles with unfiltered fallbacks.
const DNS_RESOLVER_PRESETS = Object.freeze([
  {
    "id": "cloudflare-standard",
    "provider": "Cloudflare",
    "name": "Standard",
    "level": "No content filtering",
    "filters": false,
    "ips": [
      "1.1.1.1",
      "1.0.0.1"
    ],
    "details": "Privacy-oriented public DNS, without content filtering.",
    "docs": "https://developers.cloudflare.com/1.1.1.1/ip-addresses/"
  },
  {
    "id": "cloudflare-malware",
    "provider": "Cloudflare",
    "name": "Families — Malware",
    "level": "Malware and phishing",
    "filters": true,
    "ips": [
      "1.1.1.2",
      "1.0.0.2"
    ],
    "details": "Blocks known malware and phishing domains. Does not block adult content.",
    "docs": "https://developers.cloudflare.com/1.1.1.1/ip-addresses/"
  },
  {
    "id": "cloudflare-family",
    "provider": "Cloudflare",
    "name": "Families — Adult + Malware",
    "level": "Family filtering",
    "filters": true,
    "ips": [
      "1.1.1.3",
      "1.0.0.3"
    ],
    "details": "Blocks known malware, phishing and adult-content domains.",
    "docs": "https://developers.cloudflare.com/1.1.1.1/ip-addresses/"
  },
  {
    "id": "opendns-standard",
    "provider": "OpenDNS",
    "name": "Home / Standard",
    "level": "Account-configurable filtering",
    "filters": false,
    "ips": [
      "208.67.222.222",
      "208.67.220.220"
    ],
    "details": "Standard OpenDNS resolvers. Optional category filtering requires setting up and registering a network in an OpenDNS Home account; selecting these addresses alone does not configure a filter.",
    "docs": "https://www.opendns.com/setupguide/"
  },
  {
    "id": "opendns-family",
    "provider": "OpenDNS",
    "name": "FamilyShield",
    "level": "Adult-content filtering",
    "filters": true,
    "ips": [
      "208.67.222.123",
      "208.67.220.123"
    ],
    "details": "Preconfigured adult-content filtering without managing an OpenDNS account.",
    "docs": "https://www.cisco.com/c/en/us/support/docs/security/umbrella/225803-understand-opendns-familyshield.html"
  },
  {
    "id": "opendns-sandbox",
    "provider": "OpenDNS",
    "name": "Sandbox",
    "level": "No filtering",
    "filters": false,
    "ips": [
      "208.67.222.2",
      "208.67.220.2"
    ],
    "details": "OpenDNS non-filtering resolver endpoints. This is not the standard OpenDNS Home service.",
    "docs": "https://github.com/AdguardTeam/KnowledgeBaseDNS/blob/master/docs/general/dns-providers.md"
  },
  {
    "id": "google-standard",
    "provider": "Google",
    "name": "Google Public DNS",
    "level": "No content filtering",
    "filters": false,
    "ips": [
      "8.8.8.8",
      "8.8.4.4"
    ],
    "details": "General public DNS resolution; no family or adult-content filtering preset.",
    "docs": "https://developers.google.com/speed/public-dns/docs/using"
  },
  {
    "id": "quad9-secure",
    "provider": "Quad9",
    "name": "Secure",
    "level": "Malware and phishing",
    "filters": true,
    "ips": [
      "9.9.9.9",
      "149.112.112.112"
    ],
    "details": "Threat-intelligence blocking for malicious domains; not an adult-content filter.",
    "docs": "https://docs.quad9.net/services/"
  },
  {
    "id": "quad9-unfiltered",
    "provider": "Quad9",
    "name": "Unfiltered",
    "level": "No threat blocking",
    "filters": false,
    "ips": [
      "9.9.9.10",
      "149.112.112.10"
    ],
    "details": "Quad9 privacy-oriented resolution without malware blocking.",
    "docs": "https://docs.quad9.net/services/"
  },
  {
    "id": "cleanbrowsing-security",
    "provider": "CleanBrowsing",
    "name": "Security",
    "level": "Malware and phishing",
    "filters": true,
    "ips": [
      "185.228.168.9",
      "185.228.169.9"
    ],
    "details": "Blocks known malicious, phishing and spam domains, without adult-content filtering.",
    "docs": "https://cleanbrowsing.org/filters"
  },
  {
    "id": "cleanbrowsing-adult",
    "provider": "CleanBrowsing",
    "name": "Adult",
    "level": "Adult content + security",
    "filters": true,
    "ips": [
      "185.228.168.10",
      "185.228.169.11"
    ],
    "details": "Blocks adult-content and malicious domains, with SafeSearch where supported; less restrictive than the Family filter.",
    "docs": "https://cleanbrowsing.org/filters"
  },
  {
    "id": "cleanbrowsing-family",
    "provider": "CleanBrowsing",
    "name": "Family",
    "level": "Family + SafeSearch",
    "filters": true,
    "ips": [
      "185.228.168.168",
      "185.228.169.168"
    ],
    "details": "Blocks adult and malicious domains, attempts SafeSearch enforcement, and blocks some proxy/VPN and mixed-content sites.",
    "docs": "https://cleanbrowsing.org/filters"
  },
  {
    "id": "adguard-ads",
    "provider": "AdGuard",
    "name": "Default",
    "level": "Ads and trackers",
    "filters": true,
    "ips": [
      "94.140.14.14",
      "94.140.15.15"
    ],
    "details": "Blocks ads and trackers at the DNS layer. Does not provide a full family content filter.",
    "docs": "https://adguard-dns.io/en/public-dns.html"
  },
  {
    "id": "adguard-family",
    "provider": "AdGuard",
    "name": "Family protection",
    "level": "Ads, trackers + adult content",
    "filters": true,
    "ips": [
      "94.140.14.15",
      "94.140.15.16"
    ],
    "details": "Blocks ads, trackers and adult content; attempts to enforce SafeSearch and Safe Mode where supported.",
    "docs": "https://adguard-dns.io/en/public-dns.html"
  },
  {
    "id": "adguard-unfiltered",
    "provider": "AdGuard",
    "name": "Non-filtering",
    "level": "No filtering",
    "filters": false,
    "ips": [
      "94.140.14.140",
      "94.140.14.141"
    ],
    "details": "AdGuard DNS resolution without its ad/tracker or family content blocking.",
    "docs": "https://adguard-dns.io/en/public-dns.html"
  }
]);

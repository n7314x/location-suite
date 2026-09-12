use std::error::Error;
use std::io;
use std::sync::OnceLock;

use isideload::SideloadError;
use regex::Regex;
use rootcause::Report;

pub(crate) const MAX_CHAIN_DEPTH: usize = 8;
pub(crate) const MAX_CHAIN_CHARS: usize = 1_200;
const MAX_LINE_CHARS: usize = 240;
const REDACTED: &str = "<redacted>";
const REDACTED_ACCOUNT: &str = "<redacted-account>";
const REDACTED_URL: &str = "<redacted-url>";

struct Redactors {
    sensitive_headers: Regex,
    sensitive_values: Regex,
    email: Regex,
    six_digit_code: Regex,
    url: Regex,
    opaque_value: Regex,
}

fn redactors() -> &'static Redactors {
    static REDACTORS: OnceLock<Redactors> = OnceLock::new();
    REDACTORS.get_or_init(|| Redactors {
        sensitive_headers: Regex::new(
            r"(?i)\b(authorization|proxy-authorization|cookie|set-cookie|x-apple-i-md(?:-[a-z0-9-]+)?|x-mme-client-info|x-mme-device-id|x-apple-identity-token)\b\s*[:=].*$",
        )
        .expect("the sensitive-header regex is valid"),
        sensitive_values: Regex::new(
            r#"(?i)\b(password|passwd|security[-_ ]?code|two[-_ ]?factor[-_ ]?code|2fa[-_ ]?code|access[-_ ]?token|refresh[-_ ]?token|token|secret|private[-_ ]?key|client[-_ ]?secret|adi_pb|machine[-_ ]?id|local[-_ ]?user[-_ ]?(?:uuid|id)|device[-_ ]?(?:unique[-_ ]?)?(?:identifier|id)|udid|serial[-_ ]?(?:number)?|routing[-_ ]?info|dsid|adsid|gsidmstoken|spd|p12)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|(?:bearer\s+)?[^\s,;]+)"#,
        )
        .expect("the sensitive-value regex is valid"),
        email: Regex::new(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b")
            .expect("the email regex is valid"),
        six_digit_code: Regex::new(r"\b[0-9]{6}\b")
            .expect("the verification-code regex is valid"),
        url: Regex::new(r"(?i)\bhttps?://[^\s]+")
            .expect("the URL regex is valid"),
        opaque_value: Regex::new(
            r"\b(?:[A-Fa-f0-9]{24,}|[A-Za-z0-9_+/=-]{24,}|[A-Za-z0-9_-]{12,}(?:\.[A-Za-z0-9_-]{12,}){2})\b",
        )
        .expect("the opaque-value regex is valid"),
    })
}

fn first_nonempty_line(raw: &str) -> Option<&str> {
    raw.lines().map(str::trim).find(|line| !line.is_empty())
}

fn sensitive_content_boundary(line: &str) -> Option<usize> {
    let lower = line.to_ascii_lowercase();
    [
        "response body",
        "response-body",
        "raw response",
        "response payload",
        "body:",
        "body=",
        ": {",
        ": [",
        "<?xml",
        "<plist",
        "bplist",
        "pairing content",
        "pairing-content",
        "pairing data",
        "pairing-data",
        "pair record:",
        "pair record=",
        "pairing record:",
        "pairing record=",
    ]
    .iter()
    .filter_map(|marker| lower.find(marker))
    .min()
}

fn truncate_chars(value: &str, maximum: usize) -> String {
    if value.chars().count() <= maximum {
        return value.to_string();
    }
    if maximum <= 3 {
        return ".".repeat(maximum);
    }
    let mut result: String = value.chars().take(maximum - 3).collect();
    result.push_str("...");
    result
}

pub(crate) fn sanitize_line(raw: &str, apple_id: &str, password: &str) -> Option<String> {
    let raw_line = first_nonempty_line(raw)?;
    // Normalize controls before matching so an embedded control cannot split a
    // sensitive label and bypass the redactors. Newlines are already excluded
    // by `first_nonempty_line`.
    let normalized: String = raw_line
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect();
    let line = normalized.trim();
    let lower = line.to_ascii_lowercase();
    if lower.starts_with('{')
        || lower.starts_with('[')
        || lower.starts_with("<?xml")
        || lower.starts_with("<plist")
        || lower.starts_with("bplist")
        || lower.contains("-----begin")
        || lower.contains("private key material")
        || lower.contains("certificate key material")
    {
        return None;
    }

    let safe_prefix = sensitive_content_boundary(line)
        .map(|boundary| &line[..boundary])
        .unwrap_or(line)
        .trim()
        .trim_end_matches([':', '-', '=', ' ']);
    if safe_prefix.is_empty() {
        return None;
    }

    let mut sanitized = safe_prefix.to_string();
    if !apple_id.is_empty() {
        sanitized = sanitized.replace(apple_id, REDACTED_ACCOUNT);
    }
    if !password.is_empty() {
        sanitized = sanitized.replace(password, REDACTED);
    }

    let patterns = redactors();
    sanitized = patterns
        .sensitive_headers
        .replace_all(&sanitized, "$1=<redacted>")
        .into_owned();
    sanitized = patterns
        .sensitive_values
        .replace_all(&sanitized, "$1=<redacted>")
        .into_owned();
    sanitized = patterns
        .email
        .replace_all(&sanitized, REDACTED_ACCOUNT)
        .into_owned();
    sanitized = patterns
        .six_digit_code
        .replace_all(&sanitized, REDACTED)
        .into_owned();
    sanitized = patterns
        .url
        .replace_all(&sanitized, REDACTED_URL)
        .into_owned();
    sanitized = patterns
        .opaque_value
        .replace_all(&sanitized, REDACTED)
        .into_owned();

    let sanitized: String = sanitized
        .chars()
        .filter(|character| !character.is_control())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!sanitized.is_empty()).then(|| truncate_chars(&sanitized, MAX_LINE_CHARS))
}

fn reqwest_summary(error: &reqwest::Error) -> Option<String> {
    if let Some(status) = error.status() {
        Some(format!(
            "HTTP request failed with status {}.",
            status.as_u16()
        ))
    } else if error.is_timeout() {
        Some("HTTP request timed out.".to_string())
    } else if error.is_dns() {
        Some("HTTP request failed during DNS resolution.".to_string())
    } else if error.is_connect() {
        Some("HTTP connection failed.".to_string())
    } else if error.is_decode() {
        Some("HTTP response could not be decoded.".to_string())
    } else if error.is_body() {
        Some("HTTP body transfer failed.".to_string())
    } else if error.is_builder() {
        Some("HTTP request could not be constructed.".to_string())
    } else if error.is_redirect() {
        Some("HTTP redirect failed.".to_string())
    } else if error.is_request() {
        Some("HTTP request failed.".to_string())
    } else {
        None
    }
}

fn sideload_summary(error: &SideloadError) -> String {
    match error {
        SideloadError::AuthWithMessage(code, message) => {
            format!("Auth error {code}: {message}")
        }
        SideloadError::PlistParseError(message) => format!("Plist parse error: {message}"),
        SideloadError::AnisetteNotProvisioned => {
            "Failed to get anisette data, anisette not provisioned".to_string()
        }
        SideloadError::DeveloperError(code, message) => {
            format!("Developer error {code}: {message}")
        }
        SideloadError::InvalidBundle(message) => format!("Invalid bundle: {message}"),
        SideloadError::IdeviceError(error) => error.to_string(),
    }
}

fn report_context_line(
    report: rootcause::ReportRef<'_, rootcause::markers::Dynamic, rootcause::markers::Uncloneable>,
    apple_id: &str,
    password: &str,
) -> Option<String> {
    let raw = if let Some(error) = report.downcast_current_context::<SideloadError>() {
        sideload_summary(error)
    } else if let Some(error) = report.downcast_current_context::<reqwest::Error>() {
        reqwest_summary(error)
            .unwrap_or_else(|| report.format_current_context_unhooked().to_string())
    } else if let Some(error) = report.downcast_current_context::<io::Error>() {
        format!("I/O error ({:?}): {error}", error.kind())
    } else {
        report.format_current_context_unhooked().to_string()
    };
    sanitize_line(&raw, apple_id, password)
}

fn source_line(error: &(dyn Error + 'static), apple_id: &str, password: &str) -> Option<String> {
    let raw = if let Some(error) = error.downcast_ref::<reqwest::Error>() {
        reqwest_summary(error).unwrap_or_else(|| error.to_string())
    } else if let Some(error) = error.downcast_ref::<io::Error>() {
        format!("I/O error ({:?}): {error}", error.kind())
    } else {
        error.to_string()
    };
    sanitize_line(&raw, apple_id, password)
}

#[derive(Default)]
struct ChainBuilder {
    lines: Vec<String>,
}

impl ChainBuilder {
    fn is_full(&self) -> bool {
        self.lines.len() >= MAX_CHAIN_DEPTH
    }

    fn push(&mut self, line: Option<String>) {
        let Some(line) = line else { return };
        if self.is_full() || self.lines.iter().any(|existing| existing == &line) {
            return;
        }
        self.lines.push(line);
    }

    fn finish(self) -> Option<String> {
        let mut rendered = String::new();
        for (index, line) in self.lines.into_iter().enumerate() {
            let prefix = if index == 0 { "" } else { "Cause: " };
            let separator = if index == 0 { "" } else { "\n" };
            let used = rendered.chars().count() + separator.len() + prefix.len();
            if used >= MAX_CHAIN_CHARS {
                break;
            }
            let remaining = MAX_CHAIN_CHARS - used;
            let line = truncate_chars(&line, remaining);
            rendered.push_str(separator);
            rendered.push_str(prefix);
            rendered.push_str(&line);
            if line.chars().count() == remaining {
                break;
            }
        }
        (!rendered.is_empty()).then_some(rendered)
    }
}

/// Extracts only report contexts and ordinary `Error::source` messages.
/// Attachments and Debug formatting are intentionally excluded because
/// isideload attaches response bodies and decrypted plist material to reports.
pub(crate) fn report_chain(report: &Report, apple_id: &str, password: &str) -> Option<String> {
    let mut chain = ChainBuilder::default();
    for context in report.iter_reports() {
        chain.push(report_context_line(context, apple_id, password));
        if chain.is_full() {
            break;
        }

        let mut source = context.current_context_error_source();
        while let Some(error) = source {
            chain.push(source_line(error, apple_id, password));
            if chain.is_full() {
                break;
            }
            source = error.source();
        }
        if chain.is_full() {
            break;
        }
    }
    chain.finish()
}

pub(crate) fn apple_login_category(chain: &str) -> &'static str {
    let lower = chain.to_ascii_lowercase();
    let mentions_anisette = lower.contains("anisette") || lower.contains("provisioning socket");

    if mentions_anisette
        && (lower.contains("status 503")
            || lower.contains("http 503")
            || lower.contains("service unavailable"))
    {
        "anisetteUnavailable"
    } else if lower.contains("status 503")
        || lower.contains("http 503")
        || lower.contains("service unavailable")
        || lower.contains("temporarily unavailable")
    {
        "grandSlamUnavailable"
    } else if lower.contains("account locked")
        || lower.contains("apple id is locked")
        || lower.contains("apple account is locked")
        || lower.contains("disabled for security")
    {
        "appleAccountLocked"
    } else if lower.contains("terms")
        || lower.contains("agreement required")
        || lower.contains("agree to the")
    {
        "termsRequired"
    } else if (lower.contains("client info")
        || lower.contains("client_info")
        || lower.contains("client metadata")
        || lower.contains("x-mme-client-info"))
        && (lower.contains("invalid")
            || lower.contains("rejected")
            || lower.contains("missing")
            || lower.contains("failed"))
    {
        "invalidClientMetadata"
    } else if mentions_anisette
        && (lower.contains("rejected")
            || lower.contains("invalid")
            || lower.contains("not provisioned")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("status 401")
            || lower.contains("status 403"))
    {
        "anisetteRejected"
    } else if lower.contains("timed out")
        || lower.contains("dns resolution")
        || lower.contains("connection failed")
        || lower.contains("connection reset")
        || lower.contains("connect failed")
        || lower.contains("error sending request")
        || lower.contains("network error")
        || lower.contains("tls")
        || lower.contains("ssl")
        || lower.contains("handshake")
        || lower.contains("certificate verify")
        || lower.contains("network is unreachable")
    {
        if mentions_anisette {
            "anisetteUnavailable"
        } else {
            "appleNetworkUnavailable"
        }
    } else if (lower.contains("2fa")
        || lower.contains("two-factor")
        || lower.contains("trusted device")
        || lower.contains("secondaryauth"))
        && (lower.contains("no code") || lower.contains("cancel") || lower.contains("abort"))
    {
        "twoFactorCancelled"
    } else if (lower.contains("2fa")
        || lower.contains("two-factor")
        || lower.contains("trusted device")
        || lower.contains("secondaryauth"))
        && (lower.contains("failed")
            || lower.contains("rejected")
            || lower.contains("invalid")
            || lower.contains("callback")
            || lower.contains("protocol")
            || lower.contains("cannot"))
    {
        "twoFactorFailed"
    } else if lower.contains("2fa")
        || lower.contains("two-factor")
        || lower.contains("trusted device")
        || lower.contains("secondaryauth")
    {
        "twoFactorRequired"
    } else if lower.contains("failed to parse")
        || lower.contains("malformed")
        || lower.contains("missing 'response'")
        || lower.contains("missing data for key")
        || lower.contains("missing string for key")
        || lower.contains("server proof mismatch")
        || lower.contains("unsupported srp protocol")
        || lower.contains("could not be decoded")
    {
        "malformedAppleResponse"
    } else if lower.contains("unknown apple login response")
        || lower.contains("unknown login response")
        || lower.contains("additional authentication required")
        || lower.contains("unknown error")
    {
        "unknownAppleLoginResponse"
    } else if lower.contains("invalid credentials")
        || lower.contains("incorrect password")
        || lower.contains("invalid password")
        || lower.contains("authentication rejected")
        || lower.contains("authentication failed")
        || lower.contains("auth error")
        || lower.contains("authentication error")
        || lower.contains("unauthorized")
        || lower.contains("status 401")
        || lower.contains("status 403")
    {
        "appleAuthenticationFailed"
    } else if lower.contains("http request failed with status")
        || lower.contains("received error response from grandslam")
    {
        "unknownAppleLoginResponse"
    } else if mentions_anisette {
        "anisetteUnavailable"
    } else {
        "appleAuthenticationFailed"
    }
}

#[cfg(test)]
mod tests {
    use std::io;

    use isideload::SideloadError;
    use rootcause::prelude::*;

    use super::{
        apple_login_category, report_chain, sanitize_line, MAX_CHAIN_CHARS, MAX_CHAIN_DEPTH,
        REDACTED,
    };

    fn nested_report(inner: &str) -> Report {
        report!(inner.to_string())
            .context("Failed to send initial login request")
            .context("Failed to log in to Apple ID")
            .into_dynamic()
    }

    #[test]
    fn nested_rootcause_report_preserves_each_context() {
        let chain = report_chain(&nested_report("transport failed"), "", "")
            .expect("the report has useful contexts");
        assert_eq!(
            chain,
            "Failed to log in to Apple ID\nCause: Failed to send initial login request\nCause: transport failed"
        );
    }

    #[test]
    fn rootcause_display_contains_causes_but_starts_with_an_empty_line() {
        let rendered = nested_report("transport failed").to_string();
        assert_eq!(rendered.lines().next(), Some(""));
        assert!(rendered.contains("Failed to log in to Apple ID"));
        assert!(rendered.contains("transport failed"));
    }

    #[test]
    fn outer_generic_context_keeps_the_useful_inner_cause() {
        let report = report!("Authentication rejected")
            .context("Could not sign in to the Apple Account.")
            .into_dynamic();
        let chain = report_chain(&report, "", "").expect("the inner cause is useful");
        assert_eq!(
            chain,
            "Could not sign in to the Apple Account.\nCause: Authentication rejected"
        );
    }

    #[test]
    fn http_503_is_preserved_and_classified() {
        let chain = report_chain(&nested_report("GrandSlam returned HTTP 503"), "", "")
            .expect("HTTP status is useful");
        assert!(chain.contains("HTTP 503"));
        assert_eq!(apple_login_category(&chain), "grandSlamUnavailable");
    }

    #[test]
    fn typed_apple_error_preserves_numeric_code_without_attachments() {
        let report: Report = report!(SideloadError::AuthWithMessage(
            -22406,
            "Authentication rejected for person@example.com token=private".to_string(),
        ))
        .into_dynamic()
        .context("GrandSlam error during initial login request")
        .into_dynamic();
        let chain = report_chain(&report, "person@example.com", "")
            .expect("the numeric Apple error is useful");
        assert!(chain.contains("Auth error -22406"));
        assert!(!chain.contains("person@example.com"));
        assert!(!chain.contains("token=private"));
    }

    #[test]
    fn transport_error_kind_is_preserved() {
        let report: Report =
            io::Error::new(io::ErrorKind::ConnectionRefused, "connect failed").into();
        let chain = report_chain(&report, "", "").expect("the I/O kind is useful");
        assert!(chain.contains("ConnectionRefused"));
        assert!(chain.contains("connect failed"));
    }

    #[test]
    fn two_factor_cause_is_classified() {
        assert_eq!(
            apple_login_category("Two-factor authentication is required"),
            "twoFactorRequired"
        );
        assert_eq!(
            apple_login_category("2FA callback protocol failed"),
            "twoFactorFailed"
        );
    }

    #[test]
    fn authentication_rejection_is_classified() {
        assert_eq!(
            apple_login_category("Apple authentication error -1: Authentication rejected"),
            "appleAuthenticationFailed"
        );
    }

    #[test]
    fn remaining_apple_login_failure_classes_are_distinct() {
        let cases = [
            ("This Apple ID is locked", "appleAccountLocked"),
            ("Agreement required before login", "termsRequired"),
            ("Invalid client metadata rejected", "invalidClientMetadata"),
            ("Anisette data was rejected", "anisetteRejected"),
            ("HTTP connection failed", "appleNetworkUnavailable"),
            (
                "Failed to parse proof login response",
                "malformedAppleResponse",
            ),
            ("Unknown Apple login response", "unknownAppleLoginResponse"),
        ];
        for (chain, expected) in cases {
            assert_eq!(apple_login_category(chain), expected, "chain: {chain}");
        }
    }

    #[test]
    fn sensitive_headers_are_redacted() {
        for raw in [
            "authorization: Bearer very-sensitive-value",
            "Cookie=session=very-sensitive-value; routing=secret",
            "x-apple-i-md=private-anisette-value",
            "x-mme-client-info: private-client-value",
        ] {
            let safe = sanitize_line(raw, "", "").expect("the header name remains useful");
            assert!(!safe.contains("very-sensitive-value"));
            assert!(!safe.contains("private-anisette-value"));
            assert!(!safe.contains("private-client-value"));
            assert!(!safe.contains("routing=secret"));
            assert!(safe.contains(REDACTED));
        }
    }

    #[test]
    fn labelled_token_and_password_are_redacted() {
        let safe = sanitize_line("token=opaque-value password=hunter2", "", "")
            .expect("labels remain useful");
        assert_eq!(safe, "token=<redacted> password=<redacted>");
    }

    #[test]
    fn apple_email_and_six_digit_code_are_redacted() {
        let safe = sanitize_line(
            "account person@example.com rejected verification code 123456",
            "",
            "",
        )
        .expect("the failure remains useful");
        assert!(!safe.contains("person@example.com"));
        assert!(!safe.contains("123456"));
        assert!(safe.contains("<redacted-account>"));
    }

    #[test]
    fn response_body_is_suppressed() {
        let safe = sanitize_line(
            "GrandSlam parse failed; response body: {\"token\":\"private\"}",
            "",
            "",
        )
        .expect("the pre-body context remains useful");
        assert_eq!(safe, "GrandSlam parse failed;");
        assert!(!safe.contains("private"));
    }

    #[test]
    fn report_attachments_are_never_extracted() {
        let report = report!("Failed to parse GrandSlam response")
            .attach("raw response body: password=private token=also-private")
            .into_dynamic();
        let chain = report_chain(&report, "", "").expect("the context remains useful");
        assert_eq!(chain, "Failed to parse GrandSlam response");
        assert!(!chain.contains("private"));
        assert!(!chain.contains("raw response"));
    }

    #[test]
    fn pairing_content_is_suppressed() {
        let safe = sanitize_line(
            "Failed to parse pairing data: HostID=0123456789abcdef",
            "",
            "",
        )
        .expect("the pre-content context remains useful");
        assert_eq!(safe, "Failed to parse");
        assert!(!safe.contains("HostID"));
    }

    #[test]
    fn labelled_device_identifiers_are_redacted() {
        let safe = sanitize_line(
            "device_id=short-device-id serial_number=short-serial dsid=1234567890",
            "",
            "",
        )
        .expect("the labels remain useful");
        assert_eq!(
            safe,
            "device_id=<redacted> serial_number=<redacted> dsid=<redacted>"
        );
    }

    #[test]
    fn unlabelled_opaque_value_is_suppressed() {
        let opaque = "AbCDef0123456789_-AbCDef0123456789";
        let safe = sanitize_line(&format!("request identifier {opaque}"), "", "")
            .expect("the request context remains useful");
        assert!(!safe.contains(opaque));
        assert!(safe.contains(REDACTED));
    }

    #[test]
    fn url_with_sensitive_query_is_suppressed() {
        let safe = sanitize_line(
            "request failed at https://example.invalid/login?token=private-value",
            "",
            "",
        )
        .expect("the request context remains useful");
        assert_eq!(safe, "request failed at <redacted-url>");
        assert!(!safe.contains("private-value"));
    }

    #[test]
    fn chain_depth_and_total_length_are_bounded() {
        let mut report: Report = report!("x".repeat(600)).into_dynamic();
        for index in 0..20 {
            report = report
                .context(format!("context-{index}-{}", "y".repeat(600)))
                .into_dynamic();
        }
        let chain = report_chain(&report, "", "").expect("contexts are useful");
        assert!(chain.lines().count() <= MAX_CHAIN_DEPTH);
        assert!(chain.chars().count() <= MAX_CHAIN_CHARS);
        assert!(chain.lines().all(|line| line.chars().count() <= 247));
    }

    #[test]
    fn empty_or_body_only_input_has_no_safe_detail() {
        let report = report!(String::from("{\"password\":\"private\"}")).into_dynamic();
        assert_eq!(report_chain(&report, "", ""), None);
        assert_eq!(sanitize_line("", "", ""), None);
    }
}

//! Narrow Apple developer-service FFI for Location Suite's profile-only
//! renewal milestone.
//!
//! This crate intentionally exposes no certificate create/revoke API and no
//! device-install API. Swift supplies credentials for one in-memory sign-in,
//! chooses a team, and asks for a profile. The existing idevice FFI installs
//! and rereads that profile from the phone.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Once,
};
use std::time::Duration;

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::AppIdsApi,
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    util::fs_storage::FsStorage,
};
use serde::Serialize;

static INITIALIZE_ISIDELOAD: Once = Once::new();

pub type LSTwoFactorCallback =
    Option<extern "C" fn(context: *mut c_void, output: *mut c_char, capacity: usize) -> i32>;

#[repr(C)]
pub struct LSByteBuffer {
    pub bytes: *mut u8,
    pub length: usize,
}

pub struct LSAccountSession {
    runtime: tokio::runtime::Runtime,
    developer_session: DeveloperSession,
    teams: Vec<DeveloperTeam>,
    selected_team_id: Option<String>,
}

// A session is used only by Swift's one serial maintenance queue.
unsafe impl Send for LSAccountSession {}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TeamSummary<'a> {
    identifier: &'a str,
    name: Option<&'a str>,
    team_type: Option<&'a str>,
    status: Option<&'a str>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SignInSummary<'a> {
    anisette_endpoint: &'a str,
    teams: Vec<TeamSummary<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ErrorPayload<'a> {
    category: &'a str,
    message: &'a str,
}

#[derive(Clone)]
struct CallbackContext {
    raw: *mut c_void,
    awaiting_user: Arc<AtomicBool>,
}
unsafe impl Send for CallbackContext {}
unsafe impl Sync for CallbackContext {}

impl CallbackContext {
    fn raw(&self) -> *mut c_void {
        self.raw
    }
}

struct AwaitingUserGuard(Arc<AtomicBool>);

impl AwaitingUserGuard {
    fn new(flag: Arc<AtomicBool>) -> Self {
        flag.store(true, Ordering::Release);
        Self(flag)
    }
}

impl Drop for AwaitingUserGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

fn initialize_isideload() {
    INITIALIZE_ISIDELOAD.call_once(|| {
        // Formatting hooks improve internal errors. No tracing subscriber is
        // installed, so neither credentials nor developer responses are logged.
        let _ = isideload::init();
    });
}

unsafe fn required_string(pointer: *const c_char, field: &str) -> Result<String, String> {
    if pointer.is_null() {
        return Err(format!("{field} is missing"));
    }
    let value = CStr::from_ptr(pointer)
        .to_str()
        .map(str::trim)
        .map_err(|_| format!("{field} is missing or invalid"))?;
    if value.is_empty() {
        Err(format!("{field} is missing or invalid"))
    } else {
        Ok(value.to_owned())
    }
}

unsafe fn optional_string(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer)
        .to_str()
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn make_c_string(value: impl AsRef<str>) -> *mut c_char {
    let sanitized = value.as_ref().replace('\0', "");
    CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("invalid output").expect("static string is valid"))
        .into_raw()
}

unsafe fn set_error(output: *mut *mut c_char, category: &str, message: &str) {
    if output.is_null() {
        return;
    }
    let payload = serde_json::to_string(&ErrorPayload { category, message }).unwrap_or_else(|_| {
        "{\"category\":\"unknown\",\"message\":\"Operation failed.\"}".to_string()
    });
    *output = make_c_string(payload);
}

fn redact(raw: &str, apple_id: &str, password: &str) -> String {
    let mut result = raw.replace(apple_id, "<redacted-account>");
    if !password.is_empty() {
        result = result.replace(password, "<redacted-secret>");
    }
    // Error text is useful for classifying outages, but never return headers or
    // attached developer-response bodies across the FFI boundary.
    result
        .lines()
        .next()
        .unwrap_or("Operation failed.")
        .trim()
        .to_string()
}

fn error_category(message: &str, fallback: &'static str) -> &'static str {
    let lower = message.to_ascii_lowercase();
    if lower.contains("503") || lower.contains("service unavailable") {
        "grandSlamUnavailable"
    } else if lower.contains("2fa") && (lower.contains("no ") || lower.contains("cancel")) {
        "twoFactorCancelled"
    } else if lower.contains("2fa") || lower.contains("two-factor") {
        "twoFactorRequired"
    } else if lower.contains("anisette")
        || lower.contains("provisioning socket")
        || lower.contains("client_info")
    {
        "anisetteUnavailable"
    } else if lower.contains("auth error")
        || lower.contains("password")
        || lower.contains("log in")
        || lower.contains("login")
    {
        "appleAuthenticationFailed"
    } else {
        fallback
    }
}

fn should_try_next_anisette(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("anisette")
        || lower.contains("provisioning socket")
        || lower.contains("client_info")
        || lower.contains("connection")
        || lower.contains("dns")
        || lower.contains("timed out")
}

fn charge_service_time(consumed: Duration, elapsed: Duration, awaiting_user: bool) -> Duration {
    if awaiting_user {
        consumed
    } else {
        consumed.saturating_add(elapsed)
    }
}

/// Applies a network/service budget without charging time spent waiting for the
/// human 2FA prompt. A fixed `tokio::timeout` around login can otherwise expire
/// while Swift is waiting for a code and then hang while the runtime drops a
/// worker blocked in the C callback.
async fn service_timeout(limit: Duration, awaiting_user: Arc<AtomicBool>) {
    let interval = Duration::from_millis(200);
    let mut consumed = Duration::ZERO;
    let mut checkpoint = tokio::time::Instant::now();
    loop {
        tokio::time::sleep(interval).await;
        let now = tokio::time::Instant::now();
        consumed = charge_service_time(
            consumed,
            now.duration_since(checkpoint),
            awaiting_user.load(Ordering::Acquire),
        );
        checkpoint = now;
        if consumed >= limit {
            return;
        }
    }
}

fn two_factor_callback(
    callback: LSTwoFactorCallback,
    context: CallbackContext,
) -> impl Fn(
    TwoFactorCallbackParams,
) -> std::future::Ready<Result<TwoFactorCallbackResponse, rootcause::Report>>
       + Send
       + Sync {
    move |params| {
        let response = if params.unknown {
            params
                .numbers
                .first()
                .map(|number| TwoFactorCallbackResponse::SendSms(number.id))
                .unwrap_or(TwoFactorCallbackResponse::SendToDevices)
        } else if let Some(callback) = callback {
            let mut buffer = vec![0u8; 32];
            let _awaiting_user = AwaitingUserGuard::new(context.awaiting_user.clone());
            let accepted = callback(
                context.raw(),
                buffer.as_mut_ptr().cast::<c_char>(),
                buffer.len(),
            );
            if accepted == 0 {
                TwoFactorCallbackResponse::Abort
            } else {
                let end = buffer
                    .iter()
                    .position(|byte| *byte == 0)
                    .unwrap_or(buffer.len());
                let code = String::from_utf8_lossy(&buffer[..end]).trim().to_string();
                if code.is_empty() {
                    TwoFactorCallbackResponse::Abort
                } else {
                    TwoFactorCallbackResponse::SubmitCode(code)
                }
            }
        } else {
            TwoFactorCallbackResponse::Abort
        };
        std::future::ready(Ok(response))
    }
}

/// Authenticates and opens an in-memory developer session. The endpoint list is
/// a JSON array of HTTPS v3 anisette base URLs, in preference order.
///
/// # Safety
///
/// Every input string must point to a valid NUL-terminated C string. The three
/// output pointers must be valid and writable. `callback_context` must remain
/// valid for every callback made before this function returns.
#[no_mangle]
pub unsafe extern "C" fn ls_apple_sign_in(
    apple_id: *const c_char,
    password: *const c_char,
    anisette_endpoints_json: *const c_char,
    storage_directory: *const c_char,
    timeout_seconds: u32,
    callback: LSTwoFactorCallback,
    callback_context: *mut c_void,
    output_session: *mut *mut LSAccountSession,
    output_summary_json: *mut *mut c_char,
    output_error_json: *mut *mut c_char,
) -> i32 {
    if output_session.is_null() || output_summary_json.is_null() || output_error_json.is_null() {
        return 2;
    }
    *output_session = ptr::null_mut();
    *output_summary_json = ptr::null_mut();
    *output_error_json = ptr::null_mut();

    let result = catch_unwind(AssertUnwindSafe(|| -> Result<_, (&'static str, String)> {
        initialize_isideload();
        let apple_id = required_string(apple_id, "Apple Account")
            .map_err(|message| ("appleAuthenticationFailed", message))?;
        let password = required_string(password, "password")
            .map_err(|message| ("appleAuthenticationFailed", message))?;
        let endpoints_json = required_string(anisette_endpoints_json, "anisette endpoint list")
            .map_err(|message| ("anisetteUnavailable", message))?;
        let storage_directory = required_string(storage_directory, "protected storage directory")
            .map_err(|message| ("unknown", message))?;
        let endpoints: Vec<String> = serde_json::from_str(&endpoints_json).map_err(|_| {
            (
                "anisetteUnavailable",
                "The anisette endpoint list is invalid.".to_string(),
            )
        })?;
        if endpoints.is_empty() {
            return Err((
                "anisetteUnavailable",
                "No anisette endpoint is configured.".to_string(),
            ));
        }

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|_| {
                (
                    "unknown",
                    "Could not start the signing runtime.".to_string(),
                )
            })?;
        let per_endpoint_timeout = Duration::from_secs(u64::from(timeout_seconds.clamp(10, 120)));
        let mut last_failure = (
            "anisetteUnavailable",
            "The anisette service is unavailable.".to_string(),
        );

        for (index, endpoint) in endpoints.iter().enumerate() {
            if !(endpoint.starts_with("https://") || endpoint.starts_with("http://127.0.0.1")) {
                last_failure = (
                    "anisetteUnavailable",
                    "Anisette endpoints must use HTTPS.".to_string(),
                );
                continue;
            }
            let storage_path = PathBuf::from(&storage_directory);
            let awaiting_user = Arc::new(AtomicBool::new(false));
            let callback_context = CallbackContext {
                raw: callback_context,
                awaiting_user: awaiting_user.clone(),
            };
            let attempt = runtime.block_on(async {
                tokio::select! {
                    result = async {
                        let anisette = RemoteV3AnisetteProvider::new(
                            endpoint,
                            Box::new(FsStorage::new(storage_path)),
                            "0".to_string(),
                        )
                        .map_err(|error| error.to_string())?;
                        let mut account = AppleAccount::builder(&apple_id)
                            .anisette_provider(anisette)
                            .login(&password, two_factor_callback(callback, callback_context))
                            .await
                            .map_err(|error| error.to_string())?;
                        let mut developer_session = DeveloperSession::from_account(&mut account)
                            .await
                            .map_err(|error| format!("developer session: {error}"))?;
                        let teams = developer_session
                            .list_teams()
                            .await
                            .map_err(|error| format!("team selection: {error}"))?;
                        Ok::<_, String>((developer_session, teams))
                    } => Some(result),
                    _ = service_timeout(per_endpoint_timeout, awaiting_user) => None,
                }
            });

            match attempt {
                Some(Ok((developer_session, teams))) => {
                    return Ok((
                        runtime,
                        developer_session,
                        teams,
                        endpoint.clone(),
                        apple_id,
                        password,
                    ));
                }
                Some(Err(raw)) => {
                    let clean = redact(&raw, &apple_id, &password);
                    let category = error_category(&clean, "developerSessionFailed");
                    last_failure = (category, clean.clone());
                    if category == "grandSlamUnavailable"
                        || category == "appleAuthenticationFailed"
                        || category == "twoFactorCancelled"
                        || !should_try_next_anisette(&clean)
                        || index + 1 == endpoints.len()
                    {
                        break;
                    }
                }
                None => {
                    last_failure = (
                        "anisetteUnavailable",
                        "The signing service request timed out.".to_string(),
                    );
                    if index + 1 == endpoints.len() {
                        break;
                    }
                }
            }
        }

        Err(last_failure)
    }));

    match result {
        Ok(Ok((runtime, developer_session, teams, endpoint, _apple_id, _password))) => {
            let team_summaries = teams
                .iter()
                .map(|team| TeamSummary {
                    identifier: &team.team_id,
                    name: team.name.as_deref(),
                    team_type: team.r#type.as_deref(),
                    status: team.status.as_deref(),
                })
                .collect();
            let summary = serde_json::to_string(&SignInSummary {
                anisette_endpoint: &endpoint,
                teams: team_summaries,
            })
            .unwrap_or_else(|_| "{\"teams\":[]}".to_string());
            let session = Box::new(LSAccountSession {
                runtime,
                developer_session,
                teams,
                selected_team_id: None,
            });
            *output_session = Box::into_raw(session);
            *output_summary_json = make_c_string(summary);
            0
        }
        Ok(Err((category, message))) => {
            set_error(output_error_json, category, &message);
            1
        }
        Err(_) => {
            set_error(
                output_error_json,
                "unknown",
                "The signing core stopped unexpectedly.",
            );
            2
        }
    }
}

/// Selects one of the teams returned by `ls_apple_sign_in`.
///
/// # Safety
///
/// `session` must be a live pointer returned by `ls_apple_sign_in`, the team ID
/// must be a valid NUL-terminated C string, and the error output must be valid
/// and writable.
#[no_mangle]
pub unsafe extern "C" fn ls_account_select_team(
    session: *mut LSAccountSession,
    team_identifier: *const c_char,
    output_error_json: *mut *mut c_char,
) -> i32 {
    if output_error_json.is_null() {
        return 2;
    }
    *output_error_json = ptr::null_mut();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        let session = session
            .as_mut()
            .ok_or_else(|| "The Apple developer session is unavailable.".to_string())?;
        let identifier = required_string(team_identifier, "team identifier")?;
        if !session.teams.iter().any(|team| team.team_id == identifier) {
            return Err("The selected team is not available for this Apple Account.".to_string());
        }
        session.selected_team_id = Some(identifier);
        Ok(())
    }));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => {
            set_error(output_error_json, "teamSelectionFailed", &message);
            1
        }
        Err(_) => {
            set_error(
                output_error_json,
                "unknown",
                "Team selection stopped unexpectedly.",
            );
            2
        }
    }
}

/// Registers the device if needed, finds the already-existing App ID, and
/// downloads a new team provisioning profile. It never creates an App ID or
/// touches certificates: if the selected team does not own the installed ID,
/// the operation stops rather than consuming free-team capacity.
///
/// # Safety
///
/// `session` must be a live pointer returned by `ls_apple_sign_in`; each string
/// must be a valid NUL-terminated C string; both output pointers must be valid
/// and writable. The caller must free a successful byte buffer exactly once.
#[no_mangle]
pub unsafe extern "C" fn ls_refresh_profile(
    session: *mut LSAccountSession,
    device_udid: *const c_char,
    device_name: *const c_char,
    portal_bundle_identifier: *const c_char,
    output_profile: *mut LSByteBuffer,
    output_error_json: *mut *mut c_char,
) -> i32 {
    if output_profile.is_null() || output_error_json.is_null() {
        return 2;
    }
    (*output_profile).bytes = ptr::null_mut();
    (*output_profile).length = 0;
    *output_error_json = ptr::null_mut();

    let result = catch_unwind(AssertUnwindSafe(
        || -> Result<Vec<u8>, (&'static str, String)> {
            let session = session.as_mut().ok_or((
                "developerSessionFailed",
                "The Apple developer session is unavailable.".to_string(),
            ))?;
            let udid = required_string(device_udid, "device identifier")
                .map_err(|message| ("deviceRegistrationFailed", message))?;
            let name = optional_string(device_name).unwrap_or_else(|| "iPhone".to_string());
            let bundle_id = required_string(portal_bundle_identifier, "installed App ID")
                .map_err(|message| ("profileCreationFailed", message))?;
            let selected = session.selected_team_id.as_ref().ok_or((
                "teamSelectionFailed",
                "Select the personal team that signed this installation.".to_string(),
            ))?;
            let team = session
                .teams
                .iter()
                .find(|team| &team.team_id == selected)
                .cloned()
                .ok_or((
                    "teamSelectionFailed",
                    "The selected team is no longer available.".to_string(),
                ))?;

            session.runtime.block_on(async {
            session
                .developer_session
                .ensure_device_registered(&team, &name, &udid, None)
                .await
                .map_err(|error| ("deviceRegistrationFailed", error.to_string()))?;

            let app_ids = session
                .developer_session
                .list_app_ids(&team, None)
                .await
                .map_err(|error| ("profileCreationFailed", error.to_string()))?;
            let app_id = app_ids
                .app_ids
                .into_iter()
                .find(|app_id| app_id.identifier.eq_ignore_ascii_case(&bundle_id))
                .ok_or((
                    "teamSelectionFailed",
                    format!(
                        "The selected team does not own the installed App ID {bundle_id}. No App ID was created."
                    ),
                ))?;

            let profile = session
                .developer_session
                .download_team_provisioning_profile(&team, &app_id, None)
                .await
                .map_err(|error| ("profileCreationFailed", error.to_string()))?;
            Ok(profile.encoded_profile.into())
        })
        },
    ));

    match result {
        Ok(Ok(profile)) => {
            let mut profile = profile.into_boxed_slice();
            (*output_profile).length = profile.len();
            (*output_profile).bytes = profile.as_mut_ptr();
            std::mem::forget(profile);
            0
        }
        Ok(Err((fallback, raw))) => {
            let clean = raw
                .lines()
                .next()
                .unwrap_or("Profile renewal failed.")
                .trim();
            let category = error_category(clean, fallback);
            set_error(output_error_json, category, clean);
            1
        }
        Err(_) => {
            set_error(
                output_error_json,
                "unknown",
                "Profile renewal stopped unexpectedly.",
            );
            2
        }
    }
}

/// Releases a developer session returned by `ls_apple_sign_in`.
///
/// # Safety
///
/// The pointer must be null or a live, not-yet-freed session pointer returned by
/// this library.
#[no_mangle]
pub unsafe extern "C" fn ls_account_session_free(session: *mut LSAccountSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

/// Releases a profile byte buffer returned by `ls_refresh_profile`.
///
/// # Safety
///
/// The buffer must be empty or the exact, not-yet-freed value returned by this
/// library. Its fields must not be altered.
#[no_mangle]
pub unsafe extern "C" fn ls_byte_buffer_free(buffer: LSByteBuffer) {
    if !buffer.bytes.is_null() && buffer.length > 0 {
        let slice = ptr::slice_from_raw_parts_mut(buffer.bytes, buffer.length);
        drop(Box::from_raw(slice));
    }
}

/// Releases a JSON C string returned through an FFI output pointer.
///
/// # Safety
///
/// The pointer must be null or an exact, not-yet-freed string pointer returned
/// by this library.
#[no_mangle]
pub unsafe extern "C" fn ls_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(CString::from_raw(string));
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{charge_service_time, error_category, redact, should_try_next_anisette};

    #[test]
    fn classifies_service_and_authentication_failures() {
        assert_eq!(
            error_category("GrandSlam returned HTTP 503", "unknown"),
            "grandSlamUnavailable"
        );
        assert_eq!(
            error_category("anisette provisioning socket failed", "unknown"),
            "anisetteUnavailable"
        );
        assert_eq!(
            error_category("login failed: invalid password", "unknown"),
            "appleAuthenticationFailed"
        );
    }

    #[test]
    fn only_transport_like_anisette_errors_use_the_next_endpoint() {
        assert!(should_try_next_anisette("anisette connection timed out"));
        assert!(!should_try_next_anisette("login failed: invalid password"));
        assert!(!should_try_next_anisette("GrandSlam returned 503"));
    }

    #[test]
    fn ffi_error_text_removes_credentials_and_response_lines() {
        let value = redact(
            "login for person@example.com with secret-value failed\nresponse body",
            "person@example.com",
            "secret-value",
        );
        assert_eq!(
            value,
            "login for <redacted-account> with <redacted-secret> failed"
        );
        assert!(!value.contains("response body"));
    }

    #[test]
    fn service_timeout_does_not_charge_human_two_factor_wait() {
        let already_used = Duration::from_secs(10);
        assert_eq!(
            charge_service_time(already_used, Duration::from_secs(90), true),
            already_used
        );
        assert_eq!(
            charge_service_time(already_used, Duration::from_secs(5), false),
            Duration::from_secs(15)
        );
    }
}

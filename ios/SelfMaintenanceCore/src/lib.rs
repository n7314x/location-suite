//! Narrow Apple developer-service FFI for Location Suite's profile-only
//! renewal milestone.
//!
//! This crate intentionally exposes no certificate create/revoke API and no
//! device-install API. Swift supplies credentials for one in-memory sign-in,
//! chooses a team, and asks for a profile. The existing idevice FFI installs
//! and rereads that profile from the phone.

mod safe_error;

use std::any::Any;
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::sync::{
    atomic::{AtomicBool, AtomicU8, Ordering},
    Arc, OnceLock,
};
use std::time::Duration;

use isideload::{
    anisette::{
        remote_v3::RemoteV3AnisetteProvider, AnisetteClientInfo, AnisetteData, AnisetteProvider,
    },
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    auth::grandslam::GrandSlam,
    dev::{
        app_ids::AppIdsApi,
        developer_session::DeveloperSession,
        devices::DevicesApi,
        teams::{DeveloperTeam, TeamsApi},
    },
    util::fs_storage::FsStorage,
};
use serde::Serialize;

use safe_error::{apple_login_category, report_chain, sanitize_line};

static INITIALIZE_ISIDELOAD: OnceLock<()> = OnceLock::new();

const AKD_CLIENT_INFO: &str =
    "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
const AKD_USER_AGENT: &str = "akd/1.0 CFNetwork/808.1.4";

/// Preserves the pinned RemoteV3 provider behavior while applying upstream's
/// GrandSlam client-identity fix from isideload PR #11.
struct AkdRemoteV3AnisetteProvider(RemoteV3AnisetteProvider);

impl AkdRemoteV3AnisetteProvider {
    fn new(provider: RemoteV3AnisetteProvider) -> Self {
        Self(provider)
    }
}

#[async_trait::async_trait]
impl AnisetteProvider for AkdRemoteV3AnisetteProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteData, rootcause::Report> {
        self.0.get_anisette_data().await
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, rootcause::Report> {
        Ok(AnisetteClientInfo {
            client_info: AKD_CLIENT_INFO.to_string(),
            user_agent: AKD_USER_AGENT.to_string(),
        })
    }

    async fn provision(&mut self, grand_slam: Arc<GrandSlam>) -> Result<(), rootcause::Report> {
        self.0.provision(grand_slam).await
    }

    fn needs_provisioning(&self) -> Result<bool, rootcause::Report> {
        self.0.needs_provisioning()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
enum SignInStage {
    InitializingCore,
    InstallingCryptoProvider,
    InitializingErrorHooks,
    ParsingInputs,
    CreatingRuntime,
    PreparingStorage,
    CreatingAnisetteProvider,
    AppleLogin,
    DeveloperSession,
    ListingTeams,
    BuildingResult,
}

impl SignInStage {
    fn label(self) -> &'static str {
        match self {
            Self::InitializingCore => "initializingCore",
            Self::InstallingCryptoProvider => "installingCryptoProvider",
            Self::InitializingErrorHooks => "initializingErrorHooks",
            Self::ParsingInputs => "parsingInputs",
            Self::CreatingRuntime => "creatingRuntime",
            Self::PreparingStorage => "preparingStorage",
            Self::CreatingAnisetteProvider => "creatingAnisetteProvider",
            Self::AppleLogin => "appleLogin",
            Self::DeveloperSession => "developerSession",
            Self::ListingTeams => "listingTeams",
            Self::BuildingResult => "buildingResult",
        }
    }

    fn from_raw(value: u8) -> Self {
        match value {
            1 => Self::InstallingCryptoProvider,
            2 => Self::InitializingErrorHooks,
            3 => Self::ParsingInputs,
            4 => Self::CreatingRuntime,
            5 => Self::PreparingStorage,
            6 => Self::CreatingAnisetteProvider,
            7 => Self::AppleLogin,
            8 => Self::DeveloperSession,
            9 => Self::ListingTeams,
            10 => Self::BuildingResult,
            _ => Self::InitializingCore,
        }
    }
}

struct SignInStageTracker(AtomicU8);

impl SignInStageTracker {
    fn new() -> Self {
        Self(AtomicU8::new(SignInStage::InitializingCore as u8))
    }

    fn set(&self, stage: SignInStage) {
        self.0.store(stage as u8, Ordering::Release);
    }

    fn get(&self) -> SignInStage {
        SignInStage::from_raw(self.0.load(Ordering::Acquire))
    }
}

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
    #[serde(skip_serializing_if = "Option::is_none")]
    stage: Option<&'a str>,
    message: &'a str,
}

#[derive(Debug, Eq, PartialEq)]
struct SignInFailure {
    category: &'static str,
    stage: SignInStage,
    message: String,
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
    INITIALIZE_ISIDELOAD.get_or_init(|| {
        // Formatting hooks improve internal errors. No tracing subscriber is
        // installed, so neither credentials nor developer responses are logged.
        let _ = isideload::init();
    });
}

fn initialize_rustls_crypto_provider() {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        // The pinned isideload revision deliberately enables reqwest's
        // `rustls-no-provider` feature. Its own example installs ring before
        // constructing RemoteV3AnisetteProvider; without this, reqwest panics
        // while building its client, before the first network request.
        let _ = rustls::crypto::ring::default_provider().install_default();
    }
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

fn error_payload_json(category: &str, stage: Option<&str>, message: &str) -> String {
    serde_json::to_string(&ErrorPayload {
        category,
        stage,
        message,
    })
    .unwrap_or_else(|_| "{\"category\":\"unknown\",\"message\":\"Operation failed.\"}".to_string())
}

unsafe fn set_error_with_stage(
    output: *mut *mut c_char,
    category: &str,
    stage: Option<&str>,
    message: &str,
) {
    if output.is_null() {
        return;
    }
    *output = make_c_string(error_payload_json(category, stage, message));
}

unsafe fn set_error(output: *mut *mut c_char, category: &str, message: &str) {
    set_error_with_stage(output, category, None, message);
}

fn sanitize_panic_message(raw: &str, apple_id: &str, password: &str) -> Option<String> {
    sanitize_line(raw, apple_id, password)
}

fn panic_summary(
    stage: SignInStage,
    payload: &(dyn Any + Send),
    apple_id: &str,
    password: &str,
) -> String {
    let raw = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str));
    match raw.and_then(|message| sanitize_panic_message(message, apple_id, password)) {
        Some(message) => format!("Signing core panic during {}: {message}", stage.label()),
        None => format!("Signing core panic during {}.", stage.label()),
    }
}

fn fallback_message(stage: SignInStage) -> &'static str {
    match stage {
        SignInStage::InitializingCore
        | SignInStage::InstallingCryptoProvider
        | SignInStage::InitializingErrorHooks
        | SignInStage::ParsingInputs
        | SignInStage::CreatingRuntime
        | SignInStage::PreparingStorage => "Could not initialize Apple developer sign-in.",
        SignInStage::CreatingAnisetteProvider => "Could not create the anisette provider.",
        SignInStage::AppleLogin => "Could not sign in to the Apple Account.",
        SignInStage::DeveloperSession => "Could not create the Apple developer session.",
        SignInStage::ListingTeams => "Could not list Apple developer teams.",
        SignInStage::BuildingResult => "The developer-session response could not be prepared.",
    }
}

fn fallback_category(stage: SignInStage) -> &'static str {
    match stage {
        SignInStage::CreatingAnisetteProvider | SignInStage::PreparingStorage => {
            "anisetteUnavailable"
        }
        SignInStage::AppleLogin => "appleAuthenticationFailed",
        SignInStage::ListingTeams => "teamSelectionFailed",
        _ => "developerSessionFailed",
    }
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
    } else if lower.contains("team selection") || lower.contains("list teams") {
        "teamSelectionFailed"
    } else {
        fallback
    }
}

fn sign_in_error_category(
    stage: SignInStage,
    message: &str,
    fallback: &'static str,
) -> &'static str {
    let lower = message.to_ascii_lowercase();

    match stage {
        SignInStage::CreatingAnisetteProvider | SignInStage::PreparingStorage => {
            "anisetteUnavailable"
        }
        SignInStage::AppleLogin => {
            let category = apple_login_category(message);
            if category == "appleAuthenticationFailed" {
                fallback
            } else {
                category
            }
        }
        _ if lower.contains("503") || lower.contains("service unavailable") => {
            "grandSlamUnavailable"
        }
        _ => fallback,
    }
}

impl SignInFailure {
    fn input(category: &'static str, message: impl Into<String>) -> Self {
        Self::fixed(SignInStage::ParsingInputs, category, message)
    }

    fn from_report(
        stage: SignInStage,
        fallback_category: &'static str,
        report: &rootcause::Report,
        apple_id: &str,
        password: &str,
    ) -> Self {
        let message = report_chain(report, apple_id, password)
            .unwrap_or_else(|| fallback_message(stage).to_string());
        Self {
            category: sign_in_error_category(stage, &message, fallback_category),
            stage,
            message,
        }
    }

    fn fixed(stage: SignInStage, category: &'static str, message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            category,
            stage,
            message: if message.trim().is_empty() {
                fallback_message(stage).to_string()
            } else {
                message
            },
        }
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

    let stage = SignInStageTracker::new();
    let mut panic_apple_id = String::new();
    let mut panic_password = String::new();
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<_, SignInFailure> {
        stage.set(SignInStage::InstallingCryptoProvider);
        initialize_rustls_crypto_provider();
        stage.set(SignInStage::InitializingErrorHooks);
        initialize_isideload();
        stage.set(SignInStage::ParsingInputs);
        let apple_id = required_string(apple_id, "Apple Account")
            .map_err(|message| SignInFailure::input("appleAuthenticationFailed", message))?;
        let password = required_string(password, "password")
            .map_err(|message| SignInFailure::input("appleAuthenticationFailed", message))?;
        panic_apple_id.clone_from(&apple_id);
        panic_password.clone_from(&password);
        let endpoints_json = required_string(anisette_endpoints_json, "anisette endpoint list")
            .map_err(|message| SignInFailure::input("anisetteUnavailable", message))?;
        let storage_directory =
            required_string(storage_directory, "protected storage directory")
                .map_err(|message| SignInFailure::input("anisetteUnavailable", message))?;
        let endpoints: Vec<String> = serde_json::from_str(&endpoints_json).map_err(|_| {
            SignInFailure::fixed(
                SignInStage::ParsingInputs,
                "anisetteUnavailable",
                "The anisette endpoint list is invalid.".to_string(),
            )
        })?;
        if endpoints.is_empty() {
            return Err(SignInFailure::fixed(
                SignInStage::ParsingInputs,
                "anisetteUnavailable",
                "No anisette endpoint is configured.".to_string(),
            ));
        }

        stage.set(SignInStage::CreatingRuntime);
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|_| {
                SignInFailure::fixed(
                    SignInStage::CreatingRuntime,
                    "developerSessionFailed",
                    "Could not start the signing runtime.".to_string(),
                )
            })?;
        let per_endpoint_timeout = Duration::from_secs(u64::from(timeout_seconds.clamp(10, 120)));
        let mut last_failure = SignInFailure::fixed(
            SignInStage::CreatingAnisetteProvider,
            "anisetteUnavailable",
            "The anisette service is unavailable.".to_string(),
        );

        for (index, endpoint) in endpoints.iter().enumerate() {
            if !(endpoint.starts_with("https://") || endpoint.starts_with("http://127.0.0.1")) {
                last_failure = SignInFailure::fixed(
                    SignInStage::CreatingAnisetteProvider,
                    "anisetteUnavailable",
                    "Anisette endpoints must use HTTPS.".to_string(),
                );
                continue;
            }
            stage.set(SignInStage::PreparingStorage);
            let storage_path = PathBuf::from(&storage_directory);
            let awaiting_user = Arc::new(AtomicBool::new(false));
            let callback_context = CallbackContext {
                raw: callback_context,
                awaiting_user: awaiting_user.clone(),
            };
            let attempt = runtime.block_on(async {
                tokio::select! {
                    result = async {
                        stage.set(SignInStage::CreatingAnisetteProvider);
                        let anisette = RemoteV3AnisetteProvider::new(
                            endpoint,
                            Box::new(FsStorage::new(storage_path)),
                            "0".to_string(),
                        )
                        .map_err(|error| {
                            SignInFailure::from_report(
                                SignInStage::CreatingAnisetteProvider,
                                "anisetteUnavailable",
                                &error,
                                &apple_id,
                                &password,
                            )
                        })?;
                        let anisette = AkdRemoteV3AnisetteProvider::new(anisette);
                        stage.set(SignInStage::AppleLogin);
                        let mut account = AppleAccount::builder(&apple_id)
                            .anisette_provider(anisette)
                            .login(&password, two_factor_callback(callback, callback_context))
                            .await
                            .map_err(|error| {
                                SignInFailure::from_report(
                                    SignInStage::AppleLogin,
                                    "appleAuthenticationFailed",
                                    &error,
                                    &apple_id,
                                    &password,
                                )
                            })?;
                        stage.set(SignInStage::DeveloperSession);
                        let mut developer_session = DeveloperSession::from_account(&mut account)
                            .await
                            .map_err(|error| {
                                SignInFailure::from_report(
                                    SignInStage::DeveloperSession,
                                    "developerSessionFailed",
                                    &error,
                                    &apple_id,
                                    &password,
                                )
                            })?;
                        stage.set(SignInStage::ListingTeams);
                        let teams = developer_session
                            .list_teams()
                            .await
                            .map_err(|error| {
                                SignInFailure::from_report(
                                    SignInStage::ListingTeams,
                                    "teamSelectionFailed",
                                    &error,
                                    &apple_id,
                                    &password,
                                )
                            })?;
                        Ok::<_, SignInFailure>((developer_session, teams))
                    } => Some(result),
                    _ = service_timeout(per_endpoint_timeout, awaiting_user) => None,
                }
            });

            match attempt {
                Some(Ok((developer_session, teams))) => {
                    stage.set(SignInStage::BuildingResult);
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
                        anisette_endpoint: endpoint,
                        teams: team_summaries,
                    })
                    .map_err(|_| {
                        SignInFailure::fixed(
                            SignInStage::BuildingResult,
                            "developerSessionFailed",
                            "The developer-session response could not be prepared.".to_string(),
                        )
                    })?;
                    let session = Box::new(LSAccountSession {
                        runtime,
                        developer_session,
                        teams,
                        selected_team_id: None,
                    });
                    return Ok((session, summary));
                }
                Some(Err(failure)) => {
                    let should_stop = failure.category == "grandSlamUnavailable"
                        || failure.category == "appleAuthenticationFailed"
                        || failure.category == "twoFactorCancelled"
                        || !should_try_next_anisette(&failure.message)
                        || index + 1 == endpoints.len();
                    last_failure = failure;
                    if should_stop {
                        break;
                    }
                }
                None => {
                    let timeout_stage = stage.get();
                    last_failure = SignInFailure::fixed(
                        timeout_stage,
                        fallback_category(timeout_stage),
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
        Ok(Ok((session, summary))) => {
            *output_session = Box::into_raw(session);
            *output_summary_json = make_c_string(summary);
            0
        }
        Ok(Err(failure)) => {
            set_error_with_stage(
                output_error_json,
                failure.category,
                Some(failure.stage.label()),
                &failure.message,
            );
            1
        }
        Err(payload) => {
            let message = panic_summary(
                stage.get(),
                payload.as_ref(),
                &panic_apple_id,
                &panic_password,
            );
            set_error_with_stage(
                output_error_json,
                "signingCorePanic",
                Some(stage.get().label()),
                &message,
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
    use std::panic::{catch_unwind, panic_any};
    use std::time::Duration;

    use isideload::{
        anisette::{remote_v3::RemoteV3AnisetteProvider, AnisetteProvider},
        util::fs_storage::FsStorage,
    };
    use rootcause::prelude::*;

    use super::{
        charge_service_time, error_category, error_payload_json, initialize_rustls_crypto_provider,
        panic_summary, should_try_next_anisette, AkdRemoteV3AnisetteProvider, SignInFailure,
        SignInStage, SignInStageTracker, SignInSummary, TeamSummary,
    };

    fn report_failure(
        stage: SignInStage,
        fallback_category: &'static str,
        raw: &str,
    ) -> SignInFailure {
        let report = report!(raw.to_string()).into_dynamic();
        SignInFailure::from_report(
            stage,
            fallback_category,
            &report,
            "person@example.com",
            "secret-value",
        )
    }

    #[test]
    fn signing_core_installs_the_rustls_provider() {
        initialize_rustls_crypto_provider();
        assert!(rustls::crypto::CryptoProvider::get_default().is_some());
    }

    #[test]
    fn effective_grandslam_client_info_uses_akd_identity() {
        initialize_rustls_crypto_provider();
        let upstream = RemoteV3AnisetteProvider::new(
            "https://anisette.invalid",
            Box::new(FsStorage::new(std::env::temp_dir())),
            "0".to_string(),
        )
        .expect("the provider can be created without a network request");
        let provider = AkdRemoteV3AnisetteProvider::new(upstream);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("test runtime");
        let client_info = runtime
            .block_on(provider.get_client_info())
            .expect("fixed client info");

        assert!(!client_info.client_info.contains("com.apple.dt.Xcode"));
        assert!(client_info.client_info.contains("com.apple.akd/1.0"));
        assert_eq!(client_info.user_agent, "akd/1.0 CFNetwork/808.1.4");
    }

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
        assert_eq!(
            error_category(
                "two-factor authentication is required",
                "developerSessionFailed"
            ),
            "twoFactorRequired"
        );
        assert_eq!(
            error_category("2FA cancelled: no code", "developerSessionFailed"),
            "twoFactorCancelled"
        );
        assert_eq!(
            error_category("team request failed", "developerSessionFailed"),
            "developerSessionFailed"
        );
        assert_eq!(
            error_category("team selection: request failed", "developerSessionFailed"),
            "teamSelectionFailed"
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
        let failure = report_failure(
            SignInStage::AppleLogin,
            "appleAuthenticationFailed",
            "login for person@example.com with secret-value failed\nresponse body",
        );
        assert_eq!(
            failure.message,
            "login for <redacted-account> with <redacted> failed"
        );
        assert!(!failure.message.contains("response body"));
    }

    #[test]
    fn apple_login_error_keeps_its_stage_and_authentication_fallback() {
        let failure = report_failure(
            SignInStage::AppleLogin,
            "appleAuthenticationFailed",
            "Apple login request failed",
        );
        assert_eq!(failure.category, "appleAuthenticationFailed");
        assert_eq!(failure.stage, SignInStage::AppleLogin);
        assert_eq!(failure.message, "Apple login request failed");
    }

    #[test]
    fn developer_session_error_does_not_get_reclassified_from_generic_text() {
        let failure = report_failure(
            SignInStage::DeveloperSession,
            "developerSessionFailed",
            "Failed to get xcode token after login",
        );
        assert_eq!(failure.category, "developerSessionFailed");
        assert_eq!(failure.stage, SignInStage::DeveloperSession);
        assert_eq!(failure.message, "Failed to get xcode token after login");
    }

    #[test]
    fn listing_teams_error_uses_the_operation_fallback() {
        let failure = report_failure(
            SignInStage::ListingTeams,
            "teamSelectionFailed",
            "Developer request failed after login",
        );
        assert_eq!(failure.category, "teamSelectionFailed");
        assert_eq!(failure.stage, SignInStage::ListingTeams);
        assert_eq!(failure.message, "Developer request failed after login");
    }

    #[test]
    fn normal_error_payload_includes_stage() {
        let payload = error_payload_json(
            "developerSessionFailed",
            Some(SignInStage::DeveloperSession.label()),
            "Failed to get xcode token from Apple account",
        );
        let value: serde_json::Value = serde_json::from_str(&payload).expect("valid error JSON");
        assert_eq!(value["category"], "developerSessionFailed");
        assert_eq!(value["stage"], "developerSession");
        assert_eq!(
            value["message"],
            "Failed to get xcode token from Apple account"
        );
    }

    #[test]
    fn normal_error_message_redacts_secrets_and_response_bodies() {
        let failure = report_failure(
            SignInStage::DeveloperSession,
            "developerSessionFailed",
            "account other@example.com token=opaque-value 123456 response body: private data",
        );
        assert!(!failure.message.contains("other@example.com"));
        assert!(!failure.message.contains("opaque-value"));
        assert!(!failure.message.contains("123456"));
        assert!(!failure.message.contains("private data"));
    }

    #[test]
    fn empty_normal_error_uses_a_stage_specific_fallback() {
        let failure = report_failure(SignInStage::DeveloperSession, "developerSessionFailed", "");
        assert_eq!(
            failure.message,
            "Could not create the Apple developer session."
        );
    }

    #[test]
    fn apple_login_distinguishes_anisette_503_from_grandslam_503() {
        let anisette = report_failure(
            SignInStage::AppleLogin,
            "appleAuthenticationFailed",
            "Failed to get anisette data for login: HTTP request failed with status 503",
        );
        assert_eq!(anisette.category, "anisetteUnavailable");

        let grandslam = report_failure(
            SignInStage::AppleLogin,
            "appleAuthenticationFailed",
            "GrandSlam returned HTTP 503",
        );
        assert_eq!(grandslam.category, "grandSlamUnavailable");
    }

    #[test]
    fn sign_in_success_payload_schema_is_unchanged() {
        let payload = serde_json::to_value(SignInSummary {
            anisette_endpoint: "https://anisette.invalid",
            teams: vec![TeamSummary {
                identifier: "TEAM123",
                name: Some("Personal Team"),
                team_type: Some("Individual"),
                status: Some("active"),
            }],
        })
        .expect("valid success JSON");
        assert_eq!(payload["anisetteEndpoint"], "https://anisette.invalid");
        assert_eq!(payload["teams"][0]["identifier"], "TEAM123");
        assert!(payload.get("stage").is_none());
    }

    #[test]
    fn panic_summary_extracts_string_payload() {
        let payload = catch_unwind(|| panic_any(String::from("runtime creation failed")))
            .expect_err("test panic should be caught");
        assert_eq!(
            panic_summary(
                SignInStage::CreatingRuntime,
                payload.as_ref(),
                "person@example.com",
                "secret-value",
            ),
            "Signing core panic during creatingRuntime: runtime creation failed"
        );
    }

    #[test]
    fn panic_summary_extracts_str_payload() {
        let payload = catch_unwind(|| panic_any("anisette client failed"))
            .expect_err("test panic should be caught");
        assert_eq!(
            panic_summary(
                SignInStage::CreatingAnisetteProvider,
                payload.as_ref(),
                "person@example.com",
                "secret-value",
            ),
            "Signing core panic during creatingAnisetteProvider: anisette client failed"
        );
    }

    #[test]
    fn panic_summary_omits_non_string_payload() {
        let payload = catch_unwind(|| panic_any(17_u32)).expect_err("test panic should be caught");
        assert_eq!(
            panic_summary(
                SignInStage::AppleLogin,
                payload.as_ref(),
                "person@example.com",
                "secret-value",
            ),
            "Signing core panic during appleLogin."
        );
    }

    #[test]
    fn panic_summary_preserves_latest_stage() {
        let tracker = SignInStageTracker::new();
        tracker.set(SignInStage::DeveloperSession);
        let payload =
            catch_unwind(|| panic_any("request failed")).expect_err("test panic should be caught");
        assert!(panic_summary(tracker.get(), payload.as_ref(), "", "")
            .starts_with("Signing core panic during developerSession:"));
    }

    #[test]
    fn panic_summary_redacts_known_secrets_and_apple_email() {
        let payload = catch_unwind(|| {
            panic_any(String::from(
                "login person@example.com password=secret-value token=opaque-value 123456",
            ))
        })
        .expect_err("test panic should be caught");
        let summary = panic_summary(
            SignInStage::AppleLogin,
            payload.as_ref(),
            "person@example.com",
            "secret-value",
        );
        assert!(!summary.contains("person@example.com"));
        assert!(!summary.contains("secret-value"));
        assert!(!summary.contains("opaque-value"));
        assert!(!summary.contains("123456"));
        assert!(summary.contains("<redacted-account>"));
    }

    #[test]
    fn panic_summary_redacts_apple_email_without_relying_on_password_redaction() {
        let payload = catch_unwind(|| panic_any("account other@example.com failed"))
            .expect_err("test panic should be caught");
        let summary = panic_summary(
            SignInStage::AppleLogin,
            payload.as_ref(),
            "person@example.com",
            "secret-value",
        );
        assert!(!summary.contains("other@example.com"));
        assert!(summary.contains("<redacted-account>"));
    }

    #[test]
    fn panic_summary_redacts_password() {
        let payload = catch_unwind(|| panic_any("credential secret-value failed"))
            .expect_err("test panic should be caught");
        let summary = panic_summary(
            SignInStage::AppleLogin,
            payload.as_ref(),
            "person@example.com",
            "secret-value",
        );
        assert!(!summary.contains("secret-value"));
        assert!(summary.contains("<redacted"));
    }

    #[test]
    fn panic_summary_removes_developer_response_body() {
        let payload = catch_unwind(|| panic_any("request failed response body: private material"))
            .expect_err("test panic should be caught");
        let summary = panic_summary(SignInStage::DeveloperSession, payload.as_ref(), "", "");
        assert_eq!(
            summary,
            "Signing core panic during developerSession: request failed"
        );
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

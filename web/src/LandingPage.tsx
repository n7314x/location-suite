import { useState, type ReactNode } from "react";
import "./LandingPage.css";

const features = [
  {
    number: "01",
    icon: "point",
    title: "Location simulation",
    body: "Place a pin, search, or enter coordinates. Return to your real location in one tap.",
  },
  {
    number: "02",
    icon: "route",
    title: "Route playback",
    body: "Build a walking route, control its speed, pause, and resume from the map.",
  },
  {
    number: "03",
    icon: "save",
    title: "Saved locations",
    body: "Keep favorite places close at hand and return to them without searching again.",
  },
  {
    number: "04",
    icon: "route",
    title: "Saved routes",
    body: "Keep reusable route geometry and load it again for another playback session.",
  },
  {
    number: "05",
    icon: "prep",
    title: "Session preparation",
    body: "Open and retain an idle developer session before selecting any coordinate.",
  },
  {
    number: "06",
    icon: "link",
    title: "Device connection",
    body: "See the phone-local route, RemotePairing transport, and developer service readiness.",
  },
  {
    number: "07",
    icon: "pulse",
    title: "Connection diagnostics",
    body: "Find the failed bootstrap stage, socket error, and a useful recovery action.",
  },
  {
    number: "08",
    icon: "warm",
    title: "Warm sessions",
    body: "Retain an idle session after Return so a later point or route can reuse it.",
  },
] as const;

const setup = [
  [
    "Import pairing file",
    "Give Location Suite the pairing record for this device.",
  ],
  [
    "Prepare LTE session",
    "With LocalDevVPN connected, open and retain an idle developer session.",
  ],
  [
    "Establish connection",
    "Connect to the phone-local RemotePairing endpoint.",
  ],
  [
    "Prepare developer services",
    "Confirm the DDI and simulation channel are ready.",
  ],
  ["Choose a place or route", "Select a point or create a route on the map."],
  ["Start simulation", "Run the route or set the selected coordinate."],
] as const;

function Mark({ small = false }: { small?: boolean }) {
  return (
    <span
      className={`site-mark ${small ? "site-mark-small" : ""}`}
      aria-hidden="true"
    >
      <span />
    </span>
  );
}

function Glyph({ name }: { name: string }) {
  const paths: Record<string, ReactNode> = {
    point: (
      <>
        <path d="M12 21s6-5.3 6-11a6 6 0 0 0-12 0c0 5.7 6 11 6 11Z" />
        <circle cx="12" cy="10" r="2" />
      </>
    ),
    route: (
      <>
        <circle cx="5" cy="18" r="2" />
        <circle cx="19" cy="6" r="2" />
        <path d="M7 18h4a4 4 0 0 0 0-8h2a4 4 0 0 0 4-4" />
      </>
    ),
    save: (
      <>
        <path d="M6 3h12v18l-6-4-6 4V3Z" />
      </>
    ),
    prep: (
      <>
        <circle cx="12" cy="12" r="8" />
        <path d="M12 7v5l3 2" />
      </>
    ),
    link: (
      <>
        <path d="M9 15l6-6M8 10l-2 2a4 4 0 0 0 6 6l2-2M16 14l2-2a4 4 0 0 0-6-6l-2 2" />
      </>
    ),
    pulse: (
      <>
        <path d="M2 12h5l2-6 4 12 2-6h7" />
      </>
    ),
    warm: (
      <>
        <path d="M12 3v3m0 12v3M4.2 4.2l2.1 2.1m11.4 11.4 2.1 2.1M3 12h3m12 0h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1" />
        <circle cx="12" cy="12" r="3.5" />
      </>
    ),
  };
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  );
}

function RoutePreview({ compact = false }: { compact?: boolean }) {
  return (
    <div
      className={`route-preview ${compact ? "route-preview-compact" : ""}`}
      role="img"
      aria-label="Illustrative route playback preview"
    >
      <div className="preview-map" aria-hidden="true">
        <svg viewBox="0 0 880 590" preserveAspectRatio="xMidYMid slice">
          <rect width="880" height="590" fill="#dbe6e7" />
          <path
            d="M-30 78 886 490M-20 230 810 605M182 -20 814 620M492 -30 905 392M-20 463 715 -25"
            stroke="#f8faf8"
            strokeWidth="35"
            fill="none"
          />
          <path
            d="M-30 78 886 490M-20 230 810 605M182 -20 814 620M492 -30 905 392M-20 463 715 -25"
            stroke="#bccbd1"
            strokeWidth="1"
            fill="none"
          />
          <path
            d="M-40 356C132 303 138 220 216 171S362 148 431 76M350 650C470 490 537 463 946 454"
            stroke="#b4d4cc"
            strokeWidth="76"
            fill="none"
            opacity=".7"
          />
          <path
            d="M-40 356C132 303 138 220 216 171S362 148 431 76M350 650C470 490 537 463 946 454"
            stroke="#eaf4ed"
            strokeWidth="12"
            fill="none"
            opacity=".8"
          />
          <path
            d="M185 380C250 353 303 325 350 297S443 260 495 222 579 188 654 211"
            stroke="#fff"
            strokeWidth="15"
            fill="none"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path
            d="M185 380C250 353 303 325 350 297S443 260 495 222 579 188 654 211"
            stroke="#2877db"
            strokeWidth="9"
            fill="none"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <circle cx="185" cy="380" r="14" fill="#fff" />
          <circle cx="185" cy="380" r="9" fill="#2877db" />
          <circle cx="654" cy="211" r="16" fill="#fff" />
          <circle cx="654" cy="211" r="10" fill="#122a40" />
          <circle cx="395" cy="273" r="24" fill="#2877db" opacity=".2" />
          <circle
            cx="395"
            cy="273"
            r="10"
            fill="#2877db"
            stroke="#fff"
            strokeWidth="4"
          />
        </svg>
        <span className="map-label label-one">WATERFRONT</span>
        <span className="map-label label-two">MARKET ST</span>
        <span className="map-label label-three">CIVIC GARDENS</span>
      </div>
      <div className="preview-toolbar glass-surface">
        <Mark small />
        <span>Location Suite</span>
        <span className="preview-toolbar-right">
          <i /> Session ready
        </span>
      </div>
      <div className="preview-search glass-surface">
        ⌕ <span>Search places or coordinates</span>
        <kbd>⌘ K</kbd>
      </div>
      <div className="preview-playback glass-surface">
        <div className="preview-eyebrow">
          <span className="live-dot" /> ROUTE PLAYBACK <span>ACTIVE</span>
        </div>
        <strong>Waterfront walk</strong>
        <div className="preview-metrics">
          <span>
            <b>1.8</b> km completed
          </span>
          <span>
            <b>1.2×</b> speed
          </span>
          <span>
            <b>04:32</b> elapsed
          </span>
        </div>
        <div className="preview-progress">
          <span />
        </div>
        <div className="preview-controls">
          <span>↶</span>
          <span className="preview-pause">Ⅱ</span>
          <span>↷</span>
          <span className="preview-control-label">Return to real location</span>
        </div>
      </div>
      <div className="preview-route-list glass-surface">
        <span>Saved routes</span>
        <strong>Waterfront walk</strong>
        <small>3.4 km · 6 waypoints</small>
        <div className="preview-route-divider" />
        <strong>City loop</strong>
        <small>2.1 km · 4 waypoints</small>
      </div>
    </div>
  );
}

function DiagnosticsPreview() {
  const rows = [
    ["LocalDevVPN route", "Ready", "good"],
    ["RemotePairing transport", "Connected", "good"],
    ["Developer services / DDI", "Ready", "good"],
    ["Simulation service session", "Open", "good"],
    ["Simulation active", "Route playing", "active"],
    ["Warm session", "Retained on Return", "neutral"],
  ];
  return (
    <div
      className="diagnostics-preview glass-surface"
      role="img"
      aria-label="Illustrative connection diagnostics preview"
    >
      <div className="diag-header">
        <div>
          <span className="eyebrow">CONNECTION HEALTH</span>
          <h3>Every layer, visible.</h3>
        </div>
        <span className="diag-overall">● Operational</span>
      </div>
      <div className="diag-rows">
        {rows.map(([name, value, tone]) => (
          <div className="diag-row" key={name}>
            <span className={`diag-led ${tone}`} />
            <span>{name}</span>
            <strong>{value}</strong>
          </div>
        ))}
      </div>
      <div className="diag-trace">
        <span>LAST COLD BOOTSTRAP</span>
        <code>
          TCP connect <b>→</b> RemotePairing <b>→</b> DDI <b>→</b> Ready
        </code>
      </div>
    </div>
  );
}

function LandingPage() {
  const [menuOpen, setMenuOpen] = useState(false);
  return (
    <div className="site">
      <header className="site-header glass-surface">
        <a className="site-brand" href="#top" aria-label="Location Suite home">
          <Mark />
          <span>Location Suite</span>
        </a>
        <button
          className="mobile-menu"
          type="button"
          aria-label="Toggle navigation"
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen(!menuOpen)}
        >
          ☰
        </button>
        <nav className={menuOpen ? "open" : ""} aria-label="Main navigation">
          <a href="#features" onClick={() => setMenuOpen(false)}>
            Features
          </a>
          <a href="#how-it-works" onClick={() => setMenuOpen(false)}>
            How it works
          </a>
          <a href="#diagnostics" onClick={() => setMenuOpen(false)}>
            Diagnostics
          </a>
          <a href="/app">Browser app</a>
        </nav>
        <a className="nav-download" href="#download" onClick={() => setMenuOpen(false)}>
          <span className="nav-download-long">Get Location Suite</span>
          <span className="nav-download-short">Get app</span>
          <span aria-hidden="true">↗</span>
        </a>
      </header>

      <main id="top">
        <section className="hero section-wrap">
          <div className="hero-copy">
            <span className="eyebrow hero-kicker">
              <span className="kicker-line" /> THE DEVICE LOCATION WORKSPACE
            </span>
            <h1>
              Location simulation,{" "}
              <br />
              <em>refined.</em>
            </h1>
            <p>
              Connect your device, choose a place or route, and stay in control
              of the session. Location Suite brings simulation, route playback,
              saved locations, and clear diagnostics into one focused iPhone
              app.
            </p>
            <div className="hero-actions">
              <a className="button-primary" href="#download">
                Download for iPhone <span>↗</span>
              </a>
              <a className="button-secondary" href="#features">
                Explore features <span>↓</span>
              </a>
            </div>
            <div className="hero-meta">
              <span>
                <i /> iOS 17.4+
              </span>
              <span>Built for the device you use</span>
            </div>
          </div>
          <div className="hero-visual">
            <div className="hero-halo" />
            <RoutePreview />
            <p>Illustrative product preview · route playback</p>
          </div>
        </section>

        <section className="overview section-wrap" id="overview">
          <div className="landing-heading">
            <span className="eyebrow">A CLEARER WAY TO WORK</span>
            <h2>One place for the whole location session.</h2>
          </div>
          <p>
            Location Suite runs on your iPhone. It connects through LocalDevVPN
            and RemotePairing, prepares developer services, then lets you
            simulate a point or play a route. Status and recovery stay visible
            when the connection needs attention.
          </p>
        </section>

        <section className="features section-wrap" id="features">
          <div className="landing-heading">
            <span className="eyebrow">CAPABILITIES</span>
            <h2>Everything in its place.</h2>
            <p>
              Purposeful tools for moving from setup to a precise, repeatable
              session.
            </p>
          </div>
          <div className="feature-grid">
            {features.map((feature) => (
              <article className="feature-item" key={feature.number}>
                <div className="feature-top">
                  <span className="feature-icon">
                    <Glyph name={feature.icon} />
                  </span>
                  <span className="feature-number">{feature.number}</span>
                </div>
                <h3>{feature.title}</h3>
                <p>{feature.body}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="showcase" id="route-playback">
          <div className="section-wrap showcase-grid">
            <div className="showcase-copy">
              <span className="eyebrow">ROUTE PLAYBACK</span>
              <h2>The map stays at the center.</h2>
              <p>
                Build a route from waypoints, save it, and play it back with
                speed and session controls within reach. Point and route actions
                share the same retained connection.
              </p>
              <div className="showcase-detail">
                <span className="detail-line" />
                <span>
                  Playback state, route progress, and the return to real GPS
                  stay easy to find.
                </span>
              </div>
            </div>
            <div className="showcase-visual">
              <RoutePreview compact />
            </div>
          </div>
        </section>

        <section className="setup section-wrap" id="how-it-works">
          <div className="landing-heading">
            <span className="eyebrow">GETTING STARTED</span>
            <h2>From pairing file to first simulation.</h2>
            <p>
              Onboarding follows the actual connection sequence and shows where
              to recover if a step fails.
            </p>
          </div>
          <div className="setup-grid">
            {setup.map(([title, body], index) => (
              <div className="setup-step" key={title}>
                <span className="setup-index">
                  {String(index + 1).padStart(2, "0")}
                </span>
                <div>
                  <h3>{title}</h3>
                  <p>{body}</p>
                </div>
              </div>
            ))}
          </div>
          <div className="setup-note">
            <span className="note-icon">i</span>
            <p>
              <strong>On LTE?</strong> If a fresh RemotePairing connection is
              refused, Prepare LTE Session guides an Airplane Mode bootstrap
              with LocalDevVPN connected. Location Suite does not switch network
              settings for you.
            </p>
          </div>
        </section>

        <section className="diagnostics section-wrap" id="diagnostics">
          <div className="diagnostics-copy">
            <span className="eyebrow">DIAGNOSTICS</span>
            <h2>
              Useful detail.
              <br />
              Calmly presented.
            </h2>
            <p>
              See the local route, transport, DDI, simulation channel, and warm
              session as separate states. When setup fails, the app keeps the
              failing stage and socket detail visible, then suggests the next
              action.
            </p>
            <div className="failure-preview glass-surface">
              <span className="failure-indicator">!</span>
              <div>
                <strong>RemotePairing endpoint refused connection</strong>
                <small>TCP connect · errno 61 · DDI not ready</small>
              </div>
              <span className="failure-action">Prepare LTE Session ↗</span>
            </div>
          </div>
          <DiagnosticsPreview />
        </section>

        <section className="privacy section-wrap" id="architecture">
          <div>
            <span className="eyebrow">ARCHITECTURE</span>
            <h2>A phone-local connection.</h2>
          </div>
          <div>
            <p>
              For on-device simulation, Location Suite uses a pairing file and
              LocalDevVPN’s loopback route to reach the iPhone’s RemotePairing
              service. The app opens developer services and sends location
              commands through that local session. LocalDevVPN does not provide
              a remote VPN server for this path.
            </p>
            <p>
              A retained session can continue across a Wi-Fi to LTE switch while
              the app remains running. A fresh LTE connection can still fail;
              the app reports that stage rather than implying that every network
              path is available.
            </p>
            <p>
              The separate browser interface uses a local FastAPI backend. Its
              place search is proxied to Photon using OpenStreetMap data by
              default.
            </p>
          </div>
        </section>

        <section className="download section-wrap" id="download">
          <div className="download-panel glass-surface">
            <div>
              <span className="eyebrow">LOCATION SUITE FOR IPHONE</span>
              <h2>Start with a clearer connection.</h2>
              <p>
                Version 1.5.0 · Requires iOS 17.4+, Developer Mode, a device
                pairing file, and LocalDevVPN.
              </p>
            </div>
            <div className="download-actions">
              <a
                className="button-primary"
                href="https://github.com/n7314x/location-suite/actions/workflows/build-ios-ipa.yml"
              >
                Get the IPA build artifact <span>↗</span>
              </a>
              <a
                className="button-secondary"
                href="https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md"
              >
                Pairing file guide <span>↗</span>
              </a>
              <small>
                The repository’s workflow artifact may require repository
                access. A public direct-download feed is not configured yet.
              </small>
            </div>
          </div>
        </section>
      </main>
      <footer className="site-footer section-wrap">
        <div className="footer-brand">
          <Mark small />
          <span>Location Suite</span>
          <small>© {new Date().getFullYear()} · AGPL-3.0</small>
        </div>
        <div className="footer-links">
          <a href="#features">Features</a>
          <a href="#how-it-works">Setup</a>
          <a href="#architecture">Architecture</a>
          <a href="/app">Browser app</a>
        </div>
        <span className="footer-version">iOS v1.5.0</span>
      </footer>
    </div>
  );
}

export default LandingPage;

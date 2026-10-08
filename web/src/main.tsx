import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'

const isControlApp = window.location.pathname.replace(/\/$/, '') === '/app'
const page = isControlApp ? import('./App.tsx') : import('./LandingPage.tsx')

void page.then(({ default: Page }) => {
  createRoot(document.getElementById('root')!).render(
    <StrictMode>
      <Page />
    </StrictMode>,
  )
})

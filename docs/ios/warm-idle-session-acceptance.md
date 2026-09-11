# Warm idle LocationSimulation acceptance test

## Scope and limits

After Return, Location Suite retains the phone-local RemotePairing/DVT
LocationSimulation session while real GPS is active. A 12-second idle heartbeat
repeats `stopLocationSimulation` on that existing channel; it never supplies a
coordinate. The app's existing Core Location background mode provides long-lived
execution and does not depend on Background App Refresh.

iOS may still terminate the entire app process under system pressure. An
in-process RemotePairing session cannot survive process termination.

## Physical device plan

### A.

Wi-Fi on  
LocalDevVPN on  
simulate point  
confirm Session Yes / Active Yes / Producer Point

### B.

Turn Wi-Fi off  
LTE only  
change fake point  
must work

### C.

Press Return  
confirm:  
Session Yes  
Active No  
Producer None  
Warm Session Keeper Active

### D.

Lock phone / background Location Suite for at least 30 minutes.  
Do not enable Wi-Fi.

### E.

Unlock phone on LTE.  
Open Location Suite.  
confirm:  
Session Yes  
Active No  
Producer None  
Warm Session Keeper Active  
RemotePairing Transport Yes

### F.

Set a new fake point while still on LTE.  
It must work without a fresh bootstrap.

### G.

Press Return again.  
Lock/background another 30 minutes.  
Still on LTE, start a route.  
It must work without a fresh bootstrap.

### H.

Press Disconnect Session.  
confirm:  
Session No  
Active No  
Producer None  
Warm Session Keeper Inactive

### I.

Still on LTE, try to simulate again.  
If it fails because the endpoint refuses a fresh connection, that is expected.  
This confirms the distinction between:

- a reusable warm session
- a brand-new cold bootstrap

The warm-session fix does not change the phone's cold LTE LocalDevVPN endpoint
availability.

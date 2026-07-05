# EndpointIQ — Intune, Entra ID & WHfB Admin Toolkit

> Stop clicking portals. Start driving your environment.

**By Imran Awan** · [EndpointWeekly.com](https://endpointweekly.com) · [Subscribe to the newsletter](https://endpointweekly.com)

---

## What is EndpointIQ?

EndpointIQ is a professional PowerShell toolkit for enterprise endpoint engineers who manage Microsoft Intune and Entra ID at scale. Built from real-world experience across large Microsoft environments.

The portal is slow. The portal hides things. The Graph API tells you the truth — EndpointIQ makes the Graph accessible to every engineer, not just those who write scripts for a living.

---

## What makes EndpointIQ different

| Feature | EndpointIQ | Generic toolkit |
|---------|-----------|-----------------|
| Device Health Score (0-100) | ✅ Unique | ❌ |
| WHfB + FIDO2 health audit | ✅ Unique | ❌ |
| PRT auto-remediation | ✅ Unique | ❌ |
| Stale devices + Entra sign-in cross-reference | ✅ | Partial |
| Multi-tenant support | ✅ | ❌ |
| Branded HTML reports (dark mode) | ✅ | ❌ |
| Auto-retire stale devices with safety prompt | ✅ | ❌ |
| Organised module structure | ✅ | ❌ |

---

## Quick start

```powershell
# 1. Clone the repo
git clone https://github.com/Imran76Awan/EndpointIQ

# 2. Run the launcher
cd EndpointIQ
.\Start-EndpointIQ.ps1
```

The launcher installs `Microsoft.Graph.Authentication` automatically if not present. Authenticate once — all scripts share the session.

---

## Menu structure

```
📊 INTUNE — Device Management
  [1]  Get-DeviceHealthScore      ← UNIQUE: 0-100 composite score per device
  [2]  Get-StaleDevices           ← Cross-referenced with Entra sign-in + auto-retire
  [3]  Get-PolicyConflicts        ← Deep CSP conflict scanner
  [4]  Get-ComplianceReport       ← Non-compliant devices + failure reasons
  [5]  Get-AppDeploymentStatus    ← App install status + error codes
  [6]  Get-RemediationStatus      ← Proactive remediation results
  [7]  Invoke-BulkSync            ← Trigger MDM sync across a group

🔐 WHFB — Windows Hello for Business
  [8]  Get-WHFBHealthReport       ← UNIQUE: WHfB + FIDO2 adoption audit
  [9]  Invoke-PRTRemediation      ← UNIQUE: Diagnose + auto-fix PRT issues
  [10] Get-WHFBEnrollmentStatus   ← Per-device enrollment and key status

🚀 AUTOPILOT
  [11] Get-AutopilotReport        ← Full device inventory + profiles
  [12] Get-DevicePrepStatus       ← Device Preparation v2 status

🏢 ENTRA ID — Identity
  [13] Get-SignInReport           ← Sign-in history + risky sign-ins
  [14] Get-CAReport               ← Conditional Access audit
  [15] Get-RiskyUsers             ← Identity Protection flagged users
  [16] Get-LicenseReport          ← License allocation + unused
  [17] Get-GuestUserAudit         ← Guest access audit

📋 REPORTS
  [18] Export-TenantHealthReport  ← SIGNATURE: Full tenant dashboard for management
  [19] Export-DeviceInventory     ← 35-column device inventory CSV + HTML
```

---

## Device Health Score

The `Get-DeviceHealthScore` script is EndpointIQ's flagship feature. It calculates a **composite 0-100 score** for every managed device across 5 pillars:

| Pillar | Max Points | What it checks |
|--------|-----------|----------------|
| Compliance | 25 | Is the device compliant in Intune? |
| Defender | 25 | AV enabled, signatures current, no threats |
| Patch level | 20 | Windows build recency (22H2, 23H2 etc) |
| Check-in | 20 | Days since last Intune sync |
| Encryption | 10 | BitLocker enabled |

**Grades:** Healthy (80-100) · Fair (60-79) · At Risk (<60)

Output: dark-mode HTML report + CSV, auto-saved to `Output\YYYY-MM-DD\`

---

## WHfB Module

The Windows Hello for Business module is Imran's speciality — you won't find this depth anywhere else.

- **Get-WHFBHealthReport** — audits every user's authentication methods (WHfB keys, FIDO2, Microsoft Authenticator, password-only). Instantly shows your WHfB adoption % and who is still password-only.
- **Invoke-PRTRemediation** — runs `dsregcmd /status`, identifies PRT/WAM/certificate issues, and offers guided or automatic remediation. Covers re-join, WAM cache clear, PRT refresh, and MDM sync.

---

## Output

All reports are saved to `Output\YYYY-MM-DD\` with timestamps. Every report generates both HTML (dark-mode branded) and CSV.

```
Output\
  2026-07-05\
    DeviceHealthScore-143022.html
    DeviceHealthScore-143022.csv
    TenantHealthReport-144501.html
    WHFBHealth-150312.html
```

---

## Requirements

- PowerShell 5.1 or PowerShell 7+
- `Microsoft.Graph.Authentication` module (auto-installed on first run)
- Entra ID account with appropriate Graph permissions (prompted on first run)

---

## Permissions

On first run you'll be prompted to consent to these scopes:

```
DeviceManagementConfiguration.Read.All
DeviceManagementManagedDevices.Read.All
DeviceManagementManagedDevices.PrivilegedOperations.All
DeviceManagementApps.Read.All
Directory.Read.All
AuditLog.Read.All
IdentityRiskyUser.Read.All
UserAuthenticationMethod.Read.All
BitlockerKey.Read.All
... and more
```

---

## About

**Imran Awan** is an enterprise endpoint engineer and the founder of [EndpointWeekly](https://endpointweekly.com) — a weekly newsletter covering Microsoft Intune, Entra ID, Windows 11 and endpoint security for IT professionals.

If this toolkit helped you, [subscribe to EndpointWeekly](https://endpointweekly.com) for weekly updates, deep-dive blog posts, and community tools.

---

## Contributing

Issues, PRs and feature requests welcome. If you have a script you use daily that belongs here, open a PR.

---

## Licence

MIT — free to use, modify and share. Credit appreciated.
